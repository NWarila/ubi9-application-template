"""Verify BuildKit SLSA v1 resolved image dependencies against policy."""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from urllib.parse import parse_qsl, unquote_to_bytes, urlsplit


PREDICATE_TYPE = "https://slsa.dev/provenance/v1"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
IMAGE_COMPONENT = r"[a-z0-9]+(?:[._-][a-z0-9]+)*"
IMAGE_HOST = r"[a-z0-9]+(?:[.-][a-z0-9]+)*(?::[0-9]+)?"
IMAGE = re.compile(rf"^{IMAGE_HOST}/{IMAGE_COMPONENT}(?:/{IMAGE_COMPONENT})*$")
ROOT_BASE_SHA256 = "7a315213952c6bd4344e7e327452f2172cde55e97af0fa294eb8533845bc51c4"
BUILDERS_SHA256 = "9b84b8d019c62e5f271f9729ded23c8682729838fc48445b4f13afdec1f196e1"


class VerificationFailure(ValueError):
    pass


def fail(message):
    raise VerificationFailure(message)


def trusted_fd(variable):
    try:
        value = os.environ.pop(variable)
        descriptor = int(value, 10)
    except (KeyError, ValueError):
        fail(f"missing trusted descriptor {variable}")
    if descriptor < 3 or str(descriptor) != value:
        fail(f"invalid trusted descriptor {variable}")
    return descriptor


def safe_directory(path, owner):
    try:
        metadata = os.stat(path)
    except OSError as exc:
        fail(f"cannot inspect trusted directory {path}: {exc}")
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != owner:
        fail(f"invalid trusted directory {path}")
    if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH | stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX):
        fail(f"writable or special-mode trusted directory {path}")


def read_trusted_bytes(descriptor, canonical, owner, expected_hash, label):
    try:
        metadata = os.fstat(descriptor)
        physical = Path(f"/proc/self/fd/{descriptor}").resolve(strict=True)
    except OSError as exc:
        fail(f"cannot inspect {label}: {exc}")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_uid != owner:
        fail(f"{label} is not an owner-bound single-link regular file")
    if metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH | stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX):
        fail(f"{label} has a writable or special mode")
    if physical != canonical:
        fail(f"{label} is outside the canonical installed root")
    chunks = []
    offset = 0
    while True:
        try:
            chunk = os.pread(descriptor, 65536, offset)
        except OSError as exc:
            fail(f"cannot read {label}: {exc}")
        if not chunk:
            break
        chunks.append(chunk)
        offset += len(chunk)
    content = b"".join(chunks)
    if hashlib.sha256(content).hexdigest() != expected_hash:
        fail(f"{label} hash mismatch")
    return content


def load_trusted_inputs():
    try:
        installed_root_text = os.environ.pop("TMPL01A_INSTALLED_ROOT")
        source_hash = os.environ.pop("TMPL01A_MATERIALS_SOURCE_SHA256")
        installed_root = Path(installed_root_text).resolve(strict=True)
    except (KeyError, OSError) as exc:
        fail(f"missing trusted launcher context: {exc}")
    if str(installed_root) != installed_root_text or not SHA256.fullmatch(source_hash):
        fail("invalid trusted launcher context")
    try:
        owner = os.stat(installed_root).st_uid
    except OSError as exc:
        fail(f"cannot inspect installed root: {exc}")
    tools = installed_root / "tools"
    contracts = installed_root / "contracts"
    runtime = tools / ".tmpl01a-runtime"
    for directory in (installed_root, tools, contracts, runtime):
        safe_directory(directory, owner)

    source_fd = trusted_fd("TMPL01A_MATERIALS_SOURCE_FD")
    root_base_fd = trusted_fd("TMPL01A_ROOT_BASE_FD")
    builders_fd = trusted_fd("TMPL01A_BUILDERS_FD")
    source_path = tools / "verify-build-materials.py"
    if Path(__file__).absolute() != Path(f"/proc/{os.getpid()}/fd/{source_fd}"):
        fail("materials verifier was not launched from its captured descriptor")
    read_trusted_bytes(source_fd, source_path, owner, source_hash, "materials verifier")
    root_base_bytes = read_trusted_bytes(
        root_base_fd, contracts / "root-base.json", owner, ROOT_BASE_SHA256, "root-base material policy"
    )
    builders_bytes = read_trusted_bytes(
        builders_fd, contracts / "builders.json", owner, BUILDERS_SHA256, "builder material policy"
    )
    try:
        return json.loads(root_base_bytes.decode("utf-8")), json.loads(builders_bytes.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        fail(f"cannot load material policy: {exc}")


def strict_unquote(value, label):
    for match in re.finditer("%", value):
        if not re.match(r"[0-9A-Fa-f]{2}", value[match.start() + 1:match.start() + 3]):
            fail(f"malformed percent escape in {label}")
    try:
        decoded = unquote_to_bytes(value).decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"invalid UTF-8 in {label}: {exc}")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in decoded):
        fail(f"control character in {label}")
    return decoded


def normalize_image(image):
    image = strict_unquote(image, "image URI").lower()
    if "@" in image or "?" in image or "#" in image:
        fail("malformed image name")
    if "/" not in image:
        image = f"docker.io/library/{image}"
    else:
        first = image.split("/", 1)[0]
        if "." not in first and ":" not in first and first != "localhost":
            image = f"docker.io/{image}"
    if not IMAGE.fullmatch(image):
        fail(f"malformed image name {image}")
    return image


def parse_qualifiers(query):
    if not query:
        return {}
    strict_unquote(query, "image purl qualifiers")
    try:
        pairs = parse_qsl(query, keep_blank_values=True, strict_parsing=True)
    except ValueError as exc:
        fail(f"malformed image purl qualifiers: {exc}")
    qualifiers = {}
    for key, value in pairs:
        if not key or not value or key in qualifiers:
            fail("empty or duplicate image purl qualifier")
        qualifiers[key] = value
    return qualifiers


def purl_image(uri, descriptor_digest):
    lowered = uri.lower()
    if lowered.startswith("pkg:docker/"):
        body = uri[len("pkg:docker/"):]
    elif lowered.startswith("pkg:oci/"):
        body = uri[len("pkg:oci/"):]
    else:
        return None
    if "#" in body:
        fail("image purl subpaths are forbidden")
    identity, separator, query = body.partition("?")
    if separator and "?" in query:
        fail("malformed image purl")
    if identity.count("@") > 1:
        fail("malformed image purl version")
    if "@" in identity:
        name, version = identity.split("@", 1)
        version = strict_unquote(version, "image purl version")
        if not version:
            fail("empty image purl version")
        if version.startswith("sha256:") and version != f"sha256:{descriptor_digest}":
            fail("image purl version conflicts with digest.sha256")
    else:
        name = identity
    qualifiers = parse_qualifiers(query)
    qualifier_digest = qualifiers.get("digest")
    if qualifier_digest is not None and qualifier_digest != f"sha256:{descriptor_digest}":
        fail("image purl digest qualifier conflicts with digest.sha256")
    return normalize_image(name)


def oci_image(uri, descriptor_digest):
    if not uri.lower().startswith("oci://"):
        return None
    parsed = urlsplit(uri)
    if parsed.scheme != "oci" or not parsed.netloc or parsed.fragment:
        fail("malformed OCI image URI")
    image = parsed.netloc + parsed.path
    if "@" in image:
        if image.count("@") != 1:
            fail("malformed OCI image digest")
        image, uri_digest = image.split("@", 1)
        if uri_digest != f"sha256:{descriptor_digest}":
            fail("OCI image URI conflicts with digest.sha256")
    else:
        last_slash = image.rfind("/")
        last_colon = image.rfind(":")
        if last_colon > last_slash:
            image = image[:last_colon]
    return normalize_image(image)


def policy_dependency(image, digest):
    if not isinstance(image, str) or not isinstance(digest, str):
        fail("policy image and digest must be strings")
    if not digest.startswith("sha256:") or not SHA256.fullmatch(digest[len("sha256:"):]):
        fail("policy digest is not a lowercase sha256")
    return normalize_image(image), digest[len("sha256:"):]


def approved_dependencies(root_base, builders, mode, base_image, base_digest):
    if mode == "root":
        if base_image is not None or base_digest is not None:
            fail("root mode forbids caller base-image overrides")
        try:
            records = [root_base["base"], root_base["builder"]]
        except (KeyError, TypeError):
            fail("malformed root-base material policy")
    else:
        if base_image is None or base_digest is None:
            fail("normal mode requires --base-image and --base-digest")
        if not isinstance(builders, dict) or set(builders) != {"builders"} or not isinstance(builders["builders"], list):
            fail("malformed builder material policy")
        records = builders["builders"] + [{"image": base_image, "digest": base_digest}]
    approved = set()
    for record in records:
        if not isinstance(record, dict):
            fail("malformed material policy record")
        approved.add(policy_dependency(record.get("image"), record.get("digest")))
    return approved


def observed_dependencies(statement):
    if not isinstance(statement, dict) or statement.get("predicateType") != PREDICATE_TYPE:
        fail("document is not SLSA provenance v1")
    try:
        dependencies = statement["predicate"]["buildDefinition"]["resolvedDependencies"]
    except (KeyError, TypeError):
        fail("provenance has no resolvedDependencies array")
    if not isinstance(dependencies, list):
        fail("resolvedDependencies is not an array")
    observed = set()
    for dependency in dependencies:
        if not isinstance(dependency, dict) or not isinstance(dependency.get("uri"), str):
            fail("resolved dependency is not a resource descriptor")
        uri = dependency["uri"]
        is_image = uri.lower().startswith(("pkg:docker/", "pkg:oci/", "oci://"))
        if not is_image:
            continue
        digest = dependency.get("digest")
        sha256 = digest.get("sha256") if isinstance(digest, dict) else None
        if not isinstance(sha256, str) or not SHA256.fullmatch(sha256):
            fail(f"image dependency {uri} has no lowercase digest.sha256")
        image = purl_image(uri, sha256)
        if image is None:
            image = oci_image(uri, sha256)
        item = (image, sha256)
        if item in observed:
            fail(f"duplicate resolved image dependency {image}@sha256:{sha256}")
        observed.add(item)
    return observed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--provenance", required=True)
    parser.add_argument("--mode", required=True, choices=("root", "normal"))
    parser.add_argument("--base-image")
    parser.add_argument("--base-digest")
    args = parser.parse_args()
    try:
        root_base, builders = load_trusted_inputs()
        with open(args.provenance, encoding="utf-8") as stream:
            statement = json.load(stream)
        approved = approved_dependencies(root_base, builders, args.mode, args.base_image, args.base_digest)
        observed = observed_dependencies(statement)
        if observed != approved:
            missing = sorted(approved - observed)
            extra = sorted(observed - approved)
            fail(f"resolved image dependency set mismatch; missing={missing}; extra={extra}")
    except (OSError, UnicodeError, json.JSONDecodeError, VerificationFailure) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
