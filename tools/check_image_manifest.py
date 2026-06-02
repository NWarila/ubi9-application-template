#!/usr/bin/env python3
"""Validate the UBI 9 application image manifest contract."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any


HEX64 = re.compile(r"^[a-f0-9]{64}$")
PLATFORM = re.compile(r"^linux/(amd64|arm64)$")
PKG = re.compile(r"^[a-zA-Z0-9._+-]+$")
REPO_ID = re.compile(r"^[a-zA-Z0-9._-]+$")
RHEL_VERSION = re.compile(r"^9(\.[0-9]+)?$")
DIGEST_PINNED = re.compile(r"^.+@sha256:[a-f0-9]{64}$")

FORBIDDEN_BASELINE = {
    "/bin/sh",
    "/bin/bash",
    "/usr/bin/sh",
    "/usr/bin/bash",
    "/usr/bin/dnf",
    "/usr/bin/microdnf",
    "/usr/bin/rpm",
    "/usr/bin/yum",
    "/usr/bin/curl",
    "/usr/bin/wget",
}

EVIDENCE_BASELINE = {
    "buildkit-sbom",
    "buildkit-provenance",
    "github-artifact-attestation",
    "cosign-signature",
    "runtime-hardening",
}

VERIFICATION_TYPES = {
    "checksum",
    "checksum-signature",
    "sigstore-bundle",
    "pgp-signature",
    "none",
}


class ManifestError(Exception):
    """Raised when the manifest violates the local contract."""


def has_placeholder(value: Any) -> bool:
    if isinstance(value, str):
        return "REPLACE_WITH_" in value or value.startswith("<") or value == "TBD"
    if isinstance(value, list):
        return any(has_placeholder(item) for item in value)
    if isinstance(value, dict):
        return any(has_placeholder(item) for item in value.values())
    return False


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ManifestError(message)


def require_keys(obj: dict[str, Any], keys: set[str], path: str) -> None:
    missing = sorted(keys - set(obj))
    require(not missing, f"{path} missing required keys: {', '.join(missing)}")


def require_relative_context_path(value: Any, path: str) -> None:
    require(isinstance(value, str) and value, f"{path} must be a non-empty string")
    require("\\" not in value, f"{path} must use POSIX '/' separators")
    parsed = PurePosixPath(value)
    require(not parsed.is_absolute(), f"{path} must be relative to the Docker build context")
    require(".." not in parsed.parts, f"{path} must not traverse outside the Docker build context")
    require(not value.endswith("/"), f"{path} must name a file, not a directory")
    require(parsed.name, f"{path} must name a file, not a directory")


def match_or_placeholder(pattern: re.Pattern[str], value: str, template: bool, message: str) -> None:
    if template and has_placeholder(value):
        return
    require(bool(pattern.match(value)), message)


def validate_manifest(manifest: dict[str, Any], *, template: bool) -> None:
    require(manifest.get("schema_version") == "2.0", "schema_version must be 2.0")
    require_keys(
        manifest,
        {"image", "base", "dnf", "application", "runtime", "evidence"},
        "manifest",
    )

    if not template:
        require(not has_placeholder(manifest), "real manifests must not contain replacement markers")

    image = manifest["image"]
    require_keys(image, {"name", "platforms"}, "image")
    require(isinstance(image["name"], str) and image["name"], "image.name must be non-empty")
    if "rhel_version" in image:
        require(bool(RHEL_VERSION.match(image["rhel_version"])), "image.rhel_version must look like 9 or 9.5")
    require(isinstance(image["platforms"], list) and image["platforms"], "image.platforms must be non-empty")
    seen_platforms = set()
    for platform in image["platforms"]:
        require(isinstance(platform, str), f"unsupported image platform: {platform}")
        require(bool(PLATFORM.match(platform)), f"unsupported image platform: {platform}")
        require(platform not in seen_platforms, f"duplicate image platform: {platform}")
        seen_platforms.add(platform)

    # Both UBI bases are digest-pinned: ubi-minimal for the builder stages,
    # ubi-micro for the runtime. The pins are Renovate-managed (redhat versioning).
    base = manifest["base"]
    require_keys(base, {"builder", "runtime"}, "base")
    for role in ("builder", "runtime"):
        value = base[role]
        require(isinstance(value, str) and value, f"base.{role} must be a non-empty string")
        if template and has_placeholder(value):
            require("@sha256:" in value, f"base.{role} must show digest pinning")
        else:
            require(
                bool(DIGEST_PINNED.match(value)),
                f"base.{role} must be pinned by sha256 digest (name@sha256:<64 hex>)",
            )

    # dnf.packages are install specs (package names) consumed by
    # `dnf install --installroot` in the builder stage. They are intentionally
    # validated as package-name specs, not pinned NVRs; reproducibility comes
    # from the digest-pinned base + Renovate-managed content, and the rpmdb is
    # preserved into the runtime so scanners enumerate the resolved versions.
    dnf = manifest["dnf"]
    require_keys(dnf, {"packages"}, "dnf")
    packages = dnf["packages"]
    require(isinstance(packages, list) and packages, "dnf.packages must be a non-empty list")
    require(len(packages) == len(set(packages)), "dnf.packages must not contain duplicates")
    for pkg in packages:
        require(isinstance(pkg, str) and bool(PKG.match(pkg)), f"invalid dnf package spec: {pkg}")
    if "repos" in dnf:
        repos = dnf["repos"]
        require(isinstance(repos, list), "dnf.repos must be a list")
        require(len(repos) == len(set(repos)), "dnf.repos must not contain duplicates")
        for repo_id in repos:
            require(
                isinstance(repo_id, str) and bool(REPO_ID.match(repo_id)),
                f"invalid dnf repo id: {repo_id}",
            )

    application = manifest["application"]
    require_keys(application, {"source", "binary_path", "artifacts", "verification"}, "application")
    require(
        application["source"] in {"go-binary", "vendor-release-binary", "static-binary", "other"},
        "application.source has unsupported value",
    )
    if application["source"] == "vendor-release-binary":
        # Vendor releases are fetched by name + version (for example to build
        # the upstream SHA256SUMS filename), so a manifest that omits them must
        # fail here at contract-validation time rather than later in the build.
        require_keys(application, {"name", "version"}, "application (vendor-release-binary)")
        require(bool(application["name"]), "application.name must be non-empty for vendor-release-binary")
        require(bool(application["version"]), "application.version must be non-empty for vendor-release-binary")
    require(application["binary_path"].startswith("/"), "application.binary_path must be absolute")
    require(isinstance(application["artifacts"], list) and application["artifacts"], "application.artifacts must be non-empty")
    artifact_platforms = set()
    for artifact in application["artifacts"]:
        require_keys(artifact, {"platform", "path", "sha256"}, "application.artifacts[]")
        require(bool(PLATFORM.match(artifact["platform"])), f"unsupported artifact platform: {artifact['platform']}")
        require(artifact["platform"] not in artifact_platforms, f"duplicate application artifact platform: {artifact['platform']}")
        require_relative_context_path(artifact["path"], "application.artifacts[].path")
        match_or_placeholder(HEX64, artifact["sha256"], template, "artifact sha256 must be 64 hex chars")
        artifact_platforms.add(artifact["platform"])
    require(set(image["platforms"]) <= artifact_platforms, "every image platform needs an application artifact")

    verification = application["verification"]
    require_keys(verification, {"type"}, "application.verification")
    require(verification["type"] in VERIFICATION_TYPES, "application.verification.type is unsupported")
    if verification["type"] in {"checksum-signature", "pgp-signature"}:
        require("signature_url" in verification, "signature verification requires signature_url")
    if verification["type"] == "sigstore-bundle":
        require(
            "certificate_identity" in verification and "certificate_oidc_issuer" in verification,
            "sigstore-bundle verification requires certificate identity and issuer",
        )

    # Optional from-source build provenance (used by FIPS-from-source images such
    # as the aws-signing-helper: pinned Go toolchain + GOFIPS140 validated module).
    if "build" in application:
        build = application["build"]
        require_keys(
            build,
            {"go_version", "gofips140", "cgo_enabled", "source_repo", "source_ref"},
            "application.build",
        )
        require(build["cgo_enabled"] in {"0", "1"}, "application.build.cgo_enabled must be '0' or '1'")
        if "go_image" in build:
            match_or_placeholder(
                DIGEST_PINNED, build["go_image"], template,
                "application.build.go_image must be pinned by sha256 digest",
            )

    runtime = manifest["runtime"]
    require_keys(runtime, {"user", "entrypoint", "forbidden_executables"}, "runtime")
    require(runtime["user"] not in {"", "0", "0:0", "root"}, "runtime.user must be non-root")
    require(isinstance(runtime["entrypoint"], list) and runtime["entrypoint"], "runtime.entrypoint must be non-empty")
    require(runtime["entrypoint"][0].startswith("/"), "runtime.entrypoint[0] must be absolute")
    forbidden = set(runtime["forbidden_executables"])
    require(FORBIDDEN_BASELINE <= forbidden, "runtime.forbidden_executables missing baseline tools")

    evidence = manifest["evidence"]
    require_keys(evidence, {"required"}, "evidence")
    required_evidence = set(evidence["required"])
    require(EVIDENCE_BASELINE <= required_evidence, "evidence.required missing baseline evidence types")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument(
        "--template",
        action="store_true",
        help="allow explicit REPLACE_WITH_* markers in the starter manifest",
    )
    args = parser.parse_args()

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        validate_manifest(manifest, template=args.template)
    except (OSError, json.JSONDecodeError, ManifestError) as exc:
        print(f"manifest check failed: {exc}", file=sys.stderr)
        return 1

    print(f"manifest check passed: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
