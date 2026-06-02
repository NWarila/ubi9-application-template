#!/usr/bin/env python3
"""Generate docker buildx build flags from a reviewed image manifest.

The image manifest is the single human-reviewable source of truth for the pins
that produce a UBI 9 application image. Downstream build pipelines should
derive their `docker buildx build` invocation from the manifest rather than
maintaining a parallel set of build args.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import check_image_manifest


ARCH_ORDER = ("amd64", "arm64")


class GenerateError(Exception):
    """Raised when the manifest cannot be turned into build args."""


def _artifact_by_arch(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    by_arch: dict[str, dict[str, Any]] = {}
    for artifact in manifest["application"]["artifacts"]:
        arch = artifact["platform"].split("/", 1)[1]
        by_arch[arch] = artifact
    return by_arch


def build_invocation(manifest: dict[str, Any]) -> dict[str, Any]:
    """Return a structured docker buildx invocation derived from the manifest.

    The shape is intentionally small: a list of platforms plus an ordered map
    of build args. Consumers can render it as `--build-arg` flags or use the
    JSON form directly (for example, in a GitHub Actions matrix).
    """

    image = manifest["image"]
    base = manifest["base"]
    dnf = manifest["dnf"]

    artifacts = _artifact_by_arch(manifest)
    image_arches = [platform.split("/", 1)[1] for platform in image["platforms"]]

    build_args: dict[str, str] = {}
    build_args["UBI_MINIMAL_IMAGE"] = base["builder"]
    build_args["UBI_MICRO_IMAGE"] = base["runtime"]
    build_args["DNF_PACKAGES"] = " ".join(dnf["packages"])
    build_args["DNF_REPOS"] = " ".join(dnf.get("repos", []))

    for arch in ARCH_ORDER:
        if arch not in image_arches:
            continue
        artifact = artifacts.get(arch)
        if artifact is None:
            raise GenerateError(
                f"application.artifacts missing entry for platform linux/{arch}"
            )
        build_args[f"APP_BINARY_{arch.upper()}"] = artifact["path"]
        build_args[f"APP_SHA256_{arch.upper()}"] = artifact["sha256"]

    build_args["OCI_TITLE"] = image["name"]

    return {
        "platforms": list(image["platforms"]),
        "build_args": build_args,
    }


def render_docker_buildx(invocation: dict[str, Any]) -> str:
    """Render as one token per line for `mapfile -t` consumption.

    Each flag and its value occupy adjacent lines so that values containing
    spaces (notably DNF_PACKAGES) survive intact when read into a bash array.
    """

    lines: list[str] = []
    if invocation["platforms"]:
        lines.append("--platform")
        lines.append(",".join(invocation["platforms"]))
    for key, value in invocation["build_args"].items():
        lines.append("--build-arg")
        lines.append(f"{key}={value}")
    return "\n".join(lines) + "\n"


def render_json(invocation: dict[str, Any]) -> str:
    return json.dumps(invocation, indent=2, sort_keys=False) + "\n"


RENDERERS = {
    "docker-buildx": render_docker_buildx,
    "json": render_json,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument(
        "--format",
        choices=sorted(RENDERERS),
        default="docker-buildx",
        help="output format (default: docker-buildx for mapfile consumption)",
    )
    parser.add_argument(
        "--template",
        action="store_true",
        help="allow REPLACE_WITH_* markers from the starter manifest",
    )
    args = parser.parse_args()

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        check_image_manifest.validate_manifest(manifest, template=args.template)
        invocation = build_invocation(manifest)
    except (OSError, json.JSONDecodeError, check_image_manifest.ManifestError, GenerateError) as exc:
        print(f"generate build args failed: {exc}", file=sys.stderr)
        return 1

    # Always emit LF endings: this output feeds bash `mapfile -t` and docker
    # buildx invocations that run inside Linux containers, where a stray CR
    # would corrupt argument parsing.
    sys.stdout.buffer.write(RENDERERS[args.format](invocation).encode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
