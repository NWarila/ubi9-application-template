#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: pkgset.sh MERGED_SPDX ARCH" >&2
  exit 6
fi
merged=$1
arch=$2
[[ "$arch" == amd64 || "$arch" == arm64 ]] || exit 6
[[ -f "$merged" ]] || exit 6
output="pkgset-${arch}.txt"
tmp=$(mktemp "${TMPDIR:-/tmp}/tmpl01a-pkgset.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

if ! python3 - "$merged" "$arch" > "$tmp" <<'PY'
import json
import re
import sys


def fail(message):
    raise ValueError(message)


def validate_locator(locator):
    if not isinstance(locator, str):
        fail("purl locator is not a string")
    raw = locator.encode("utf-8")

    def decode(component, label):
        decoded = bytearray()
        index = 0
        while index < len(component):
            if component[index] != 0x25:
                decoded.append(component[index])
                index += 1
                continue
            if index + 2 >= len(component) or not re.fullmatch(rb"[0-9A-Fa-f]{2}", component[index + 1:index + 3]):
                fail("malformed percent escape in rpm purl")
            decoded.append(int(component[index + 1:index + 3], 16))
            index += 3
        if any(byte < 0x20 or byte == 0x7f for byte in decoded):
            fail("control byte in rpm purl")
        try:
            return decoded.decode("utf-8")
        except UnicodeDecodeError as exc:
            fail(f"invalid UTF-8 in rpm purl {label}: {exc}")

    decode(raw, "locator")
    if not locator.startswith("pkg:rpm/"):
        fail("rpm purl has the wrong type")
    if locator.count("@") != 1:
        fail("rpm purl must contain exactly one @")
    body = locator[len("pkg:rpm/"):]
    package_part, tail = body.split("@", 1)
    if package_part.count("/") != 1:
        fail("rpm purl must contain one namespace and one name")
    namespace_raw, name_raw = (part.encode("utf-8") for part in package_part.split("/", 1))
    if not namespace_raw or not name_raw:
        fail("rpm purl namespace and name must be nonempty")
    for component in (namespace_raw, name_raw):
        if re.search(rb"%(?:2[fF]|40|3[fF]|23)", component):
            fail("encoded structural separator in rpm purl package identity")
    namespace = decode(namespace_raw, "namespace")
    name = decode(name_raw, "name")
    component_pattern = r"[A-Za-z0-9][A-Za-z0-9._+~-]*"
    if not re.fullmatch(component_pattern, namespace) or not re.fullmatch(component_pattern, name):
        fail("malformed rpm purl namespace or name")

    if tail.count("#") > 1 or tail.count("?") > 1:
        fail("malformed rpm purl suffix")
    if "#" in tail and "?" in tail and tail.index("#") < tail.index("?"):
        fail("rpm purl qualifiers must precede the subpath")
    before_fragment, separator, subpath_raw = tail.partition("#")
    version_raw, query_separator, qualifiers_raw = before_fragment.partition("?")
    if not version_raw:
        fail("rpm purl version must be nonempty")
    version = decode(version_raw.encode("utf-8"), "version")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+~:^!-]*", version):
        fail("malformed rpm purl version")
    if separator:
        if not subpath_raw:
            fail("rpm purl subpath must be nonempty")
        segments = subpath_raw.split("/")
        decoded_segments = [decode(item.encode("utf-8"), "subpath") for item in segments if item]
        if (len(decoded_segments) != len(segments)
                or any(item in (".", "..") or re.search(r"[\\\s?#]", item) for item in decoded_segments)):
            fail("malformed rpm purl subpath")
    if query_separator:
        if not qualifiers_raw:
            fail("rpm purl qualifiers must be nonempty")
        seen = set()
        for qualifier in qualifiers_raw.split("&"):
            if qualifier.count("=") != 1:
                fail("malformed rpm purl qualifier")
            key_raw, value_raw = qualifier.split("=", 1)
            if not key_raw or not value_raw:
                fail("malformed rpm purl qualifier")
            key = decode(key_raw.encode("utf-8"), "qualifier key")
            value = decode(value_raw.encode("utf-8"), "qualifier value")
            if re.search(r"\s", value):
                fail("malformed rpm purl qualifier value")
            if not re.fullmatch(r"[a-z][a-z0-9._-]*", key) or key in seen:
                fail("malformed or duplicate rpm purl qualifier key")
            seen.add(key)


try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        document = json.load(stream)
    arch = sys.argv[2]
    packages = document.get("packages")
    describes = document.get("documentDescribes")
    if not isinstance(packages, list) or not isinstance(describes, list):
        fail("packages and documentDescribes must be arrays")
    if any(not isinstance(item, str) for item in describes) or len(set(describes)) != len(describes):
        fail("documentDescribes IDs must be unique strings")
    by_id = {}
    for package in packages:
        if not isinstance(package, dict) or not isinstance(package.get("SPDXID"), str):
            fail("package has no SPDXID")
        by_id.setdefault(package["SPDXID"], []).append(package)
    for root_id in describes:
        if len(by_id.get(root_id, [])) != 1:
            fail(f"documentDescribes ID {root_id} does not resolve exactly once")

    marker_pattern = re.compile(
        r"(?:^|\n)TMPL01A child manifest digest=sha256:[0-9a-f]{64} "
        r"platform=linux/(amd64|arm64)(?=\n|$)"
    )
    roots_by_arch = {"amd64": [], "arm64": []}
    for package in packages:
        comment = package.get("comment", "")
        if comment is None:
            comment = ""
        if not isinstance(comment, str):
            fail("package comment is not a string")
        markers = marker_pattern.findall(comment)
        if comment.count("TMPL01A child manifest") != len(markers):
            fail("malformed child-root marker")
        if package["SPDXID"] in describes and len(markers) != 1:
            fail(f"described child root {package['SPDXID']} must carry exactly one marker")
        for marker_arch in markers:
            if package["SPDXID"] not in describes:
                fail(f"child-root marker {package['SPDXID']} is absent from documentDescribes")
            roots_by_arch[marker_arch].append(package["SPDXID"])
        if len(set(markers)) != len(markers) or len(markers) > 1:
            fail(f"child root {package['SPDXID']} is bound to multiple architectures or markers")
        for reference in package.get("externalRefs") or []:
            if not isinstance(reference, dict):
                fail("external reference is not an object")
            if reference.get("referenceType") == "purl" and str(reference.get("referenceLocator", "")).startswith("pkg:rpm/"):
                validate_locator(reference.get("referenceLocator"))
    if len(roots_by_arch[arch]) != 1:
        fail(f"linux/{arch} child root must be present exactly once")

    prefix = f"SPDXRef-{arch}-"
    locators = []
    for package in packages:
        if not package["SPDXID"].startswith(prefix) or package["SPDXID"] in describes:
            continue
        rpm = []
        for reference in package.get("externalRefs") or []:
            if (isinstance(reference, dict) and reference.get("referenceType") == "purl"
                    and isinstance(reference.get("referenceLocator"), str)
                    and reference["referenceLocator"].startswith("pkg:rpm/")):
                rpm.append(reference["referenceLocator"])
        if len(rpm) > 1:
            fail(f"{package['SPDXID']}: {len(rpm)} rpm purls")
        if rpm:
            if rpm[0] == "pkg:rpm/":
                fail(f"{package['SPDXID']}: malformed rpm purl")
            locators.append(rpm[0].encode("utf-8"))
    for locator in sorted(set(locators)):
        sys.stdout.buffer.write(locator + b"\n")
except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
PY
then
  exit 1
fi
mv -f -- "$tmp" "$output"
trap - EXIT
sha256sum "$output" | cut -d' ' -f1
