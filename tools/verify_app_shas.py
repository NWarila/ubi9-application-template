#!/usr/bin/env python3
"""Verify that built application artifacts match the manifest's SHA256 values.

This is the bridge between the deterministic Go build in `tools/build_app.sh`
and the manifest's `application.artifacts[].sha256` entries. If the binaries
on disk drift from the manifest (for example after a Go version bump or a
source change), this script reports the expected/actual digests so the
developer can update the manifest in the same commit as the source change.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="repository root from which artifact paths are resolved",
    )
    args = parser.parse_args()

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"failed to read manifest: {exc}", file=sys.stderr)
        return 1

    artifacts = manifest.get("application", {}).get("artifacts", [])
    if not artifacts:
        print("manifest has no application.artifacts to verify", file=sys.stderr)
        return 1

    mismatches: list[str] = []
    for artifact in artifacts:
        platform = artifact["platform"]
        rel_path = artifact["path"]
        expected = artifact["sha256"]
        artifact_path = args.root / rel_path
        if not artifact_path.is_file():
            mismatches.append(f"{platform}: missing artifact {artifact_path}")
            continue
        actual = sha256_of(artifact_path)
        if actual != expected:
            mismatches.append(
                f"{platform}: sha256 drift for {rel_path}\n"
                f"  expected: {expected}\n"
                f"  actual:   {actual}"
            )
        else:
            print(f"{platform}: {rel_path} ok")

    if mismatches:
        print("application artifact sha256 verification failed:", file=sys.stderr)
        for line in mismatches:
            print(line, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
