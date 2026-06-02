#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s ghcr.io/owner/image@sha256:...\n' "$0" >&2
  exit 2
fi

image_ref="$1"

if [[ "${image_ref}" != ghcr.io/* ]]; then
  printf 'expected a ghcr.io image reference, got: %s\n' "${image_ref}" >&2
  exit 2
fi

without_registry="${image_ref#ghcr.io/}"

if [[ "${without_registry}" == *@* ]]; then
  repository="${without_registry%@*}"
  reference="${without_registry#*@}"
elif [[ "${without_registry}" == *:* ]]; then
  repository="${without_registry%:*}"
  reference="${without_registry##*:}"
else
  printf 'expected an image tag or digest reference, got: %s\n' "${image_ref}" >&2
  exit 2
fi

if [[ -z "${repository}" || -z "${reference}" ]]; then
  printf 'invalid image reference: %s\n' "${image_ref}" >&2
  exit 2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

token_url="https://ghcr.io/token?service=ghcr.io&scope=repository:${repository}:pull"
token="$(python - "${token_url}" <<'PY'
import json
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=30) as response:
    payload = json.load(response)

token = payload.get("token")
if not token:
    raise SystemExit("anonymous GHCR token response did not include a token")

print(token)
PY
)"

manifest_url="https://ghcr.io/v2/${repository}/manifests/${reference}"
status="$(
  curl --silent --show-error --location \
    --output "${tmpdir}/manifest.json" \
    --dump-header "${tmpdir}/headers.txt" \
    --write-out '%{http_code}' \
    --header "Authorization: Bearer ${token}" \
    --header 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "${manifest_url}"
)"

if [[ "${status}" != "200" ]]; then
  printf 'anonymous GHCR manifest request failed for %s with HTTP %s\n' "${image_ref}" "${status}" >&2
  printf '%s\n' '--- response headers ---' >&2
  sed -n '1,80p' "${tmpdir}/headers.txt" >&2
  printf '%s\n' '--- response body ---' >&2
  sed -n '1,80p' "${tmpdir}/manifest.json" >&2
  exit 1
fi

digest="$(
  awk 'BEGIN { IGNORECASE = 1 } /^docker-content-digest:/ { gsub(/\r/, ""); print $2 }' \
    "${tmpdir}/headers.txt" \
    | tail -n 1
)"

if [[ -z "${digest}" ]]; then
  printf 'anonymous GHCR manifest request succeeded but did not return Docker-Content-Digest\n' >&2
  exit 1
fi

printf 'Verified anonymous public GHCR pull for ghcr.io/%s@%s\n' "${repository}" "${digest}"
