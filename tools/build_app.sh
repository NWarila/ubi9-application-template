#!/usr/bin/env bash
# Build the example Go application for the platforms the manifest declares.
#
# The build runs inside a digest-pinned golang container so the same Go
# toolchain image produces byte-identical binaries across local and CI
# environments.
# This keeps the SHA256 values stored in examples/image-manifest.json valid
# without requiring a host Go install.

set -euo pipefail

# Stop Git-Bash / MSYS from rewriting POSIX paths inside the docker arguments
# when this script runs on Windows. Harmless on native Linux/macOS shells.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# renovate: datasource=docker depName=golang versioning=docker
GO_IMAGE="${GO_IMAGE:-golang:1.23.4-alpine3.21@sha256:c23339199a08b0e12032856908589a6d41a0dab141b8b3b21f156fc571a3f1d3}"

# On Linux/macOS bind-mount the host as the calling user so the resulting
# binaries are not owned by root. On Windows + Docker Desktop the bind mount
# is owned by the host user already and `id` returns 0:0, so skip the flag.
user_flag=()
if [[ -z "${MSYSTEM:-}" && "${OSTYPE:-}" != "msys" && "${OSTYPE:-}" != "cygwin" ]]; then
  user_flag=("--user" "$(id -u):$(id -g)")
fi

cd "${ROOT}"
mkdir -p dist

docker run --rm \
  "${user_flag[@]}" \
  -v "${ROOT}:/work" \
  -w /work/app \
  -e CGO_ENABLED=0 \
  -e GOFLAGS=-buildvcs=false \
  -e GOCACHE=/tmp/.gocache \
  -e GOMODCACHE=/tmp/.gomodcache \
  "${GO_IMAGE}" \
  sh -eux -c '
    for arch in amd64 arm64; do
      GOOS=linux GOARCH=${arch} \
        go build -trimpath -ldflags="-s -w -buildid=" -o /work/dist/app-${arch} .
    done
  '

sha256sum dist/app-amd64 dist/app-arm64
