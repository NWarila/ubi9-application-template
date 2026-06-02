#!/usr/bin/env bash
# Build the UBI 9 application image for a single platform.
#
# Reads build args from the reviewed image manifest and ignores the manifest's
# `--platform` value in favor of the explicit platform argument, because
# Docker's `--load` only supports single-platform builds. Multi-platform
# release builds and BuildKit attestations belong in the downstream release
# workflow, which can use `--push` or `--output type=oci`. The Docker `--load`
# exporter used here is only for local runtime testing and does not persist
# SBOM or provenance attestations.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/build_image.sh <manifest> <image-tag> [platform]

  manifest    Path to a reviewed image-manifest.json
  image-tag   Local tag for the built image (e.g. example/ubi9-app:dev)
  platform    Optional, defaults to linux/amd64 (must appear in manifest.image.platforms)
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

manifest="${1:-}"
image_tag="${2:-}"
platform="${3:-linux/amd64}"

if [[ -z "${manifest}" || -z "${image_tag}" ]]; then
  usage >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

# Discard the generator's --platform pair; build_image.sh owns the build
# platform so that the caller can pick between native build + --load and
# multi-platform release builds.
mapfile -t generated < <(python tools/generate_build_args.py "${manifest}")
build_args=()
skip_next=0
for entry in "${generated[@]}"; do
  if [[ "${skip_next}" -eq 1 ]]; then
    skip_next=0
    continue
  fi
  if [[ "${entry}" == "--platform" ]]; then
    skip_next=1
    continue
  fi
  build_args+=("${entry}")
done

docker buildx build \
  --file containers/Dockerfile \
  --platform "${platform}" \
  --provenance=false \
  --tag "${image_tag}" \
  --load \
  "${build_args[@]}" \
  .
