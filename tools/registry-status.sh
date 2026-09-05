#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then exit 2; fi
image=$1
tag=$2
[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || exit 2
bootstrap=${BOOTSTRAP:-false}
[[ "$bootstrap" == true || "$bootstrap" == false ]] || exit 2

case "$image" in
  */*) host=${image%%/*}; name=${image#*/} ;;
  *) exit 2 ;;
esac
[[ -n "$host" && -n "$name" ]] || exit 2
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmpl01a-status.XXXXXX") || exit 2
trap 'rm -rf -- "$work_dir"' EXIT
body="$work_dir/body.json"
response_headers="$work_dir/headers"

headers=(-H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json')
if [[ "${REGISTRY_INSECURE:-0}" == 1 ]]; then
  base="http://$host"
else
  [[ "$host" == ghcr.io ]] || exit 2
  [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_TOKEN:-}" ]] || exit 2
  token_json="$work_dir/token.json"
  if ! curl --silent --show-error --fail-with-body --max-time 30 \
    --user "${REGISTRY_USER}:${REGISTRY_TOKEN}" \
    --output "$token_json" \
    "https://ghcr.io/token?scope=repository:${name}:pull&service=ghcr.io"; then
    exit 2
  fi
  token=$(jq -er '.token | select(type == "string" and length > 0)' "$token_json") || exit 2
  headers+=(-H "Authorization: Bearer $token")
  base=https://ghcr.io
fi

if ! http_code=$(curl --silent --show-error --max-time 30 --output "$body" --dump-header "$response_headers" \
  --write-out '%{http_code}' "${headers[@]}" "$base/v2/$name/manifests/$tag"); then
  exit 2
fi
case "$http_code" in
  200)
    content_type=$(python3 - "$response_headers" <<'PY'
import re
import sys

try:
    lines = open(sys.argv[1], "rb").read().splitlines()
except OSError:
    sys.exit(2)
starts = [index for index, line in enumerate(lines)
          if re.fullmatch(rb"HTTP/[0-9]+(?:\.[0-9]+)? [0-9]{3}(?: .*)?", line)]
if not starts:
    sys.exit(2)
final = lines[starts[-1] + 1:]
values = []
for line in final:
    if line == b"":
        break
    if line[:1] in (b" ", b"\t") or b":" not in line:
        sys.exit(2)
    name, value = line.split(b":", 1)
    if name.lower() == b"content-type":
        try:
            values.append(value.strip().decode("ascii"))
        except UnicodeDecodeError:
            sys.exit(2)
if len(values) != 1:
    sys.exit(2)
match = re.fullmatch(r"([^;\s]+)(?:\s*;\s*charset=[A-Za-z0-9._-]+)?", values[0], re.IGNORECASE)
if not match:
    sys.exit(2)
print(match.group(1).lower())
PY
    ) || exit 2
    case "$content_type" in
      application/vnd.oci.image.index.v1+json|application/vnd.oci.image.manifest.v1+json|\
      application/vnd.docker.distribution.manifest.list.v2+json|application/vnd.docker.distribution.manifest.v2+json) ;;
      *) exit 2 ;;
    esac
    jq -e '
      type == "object" and .schemaVersion == 2 and
      if (.mediaType == "application/vnd.oci.image.index.v1+json" or
          .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json")
      then (.manifests | type) == "array"
      elif (.mediaType == "application/vnd.oci.image.manifest.v1+json" or
            .mediaType == "application/vnd.docker.distribution.manifest.v2+json")
      then (.config | type) == "object" and (.layers | type) == "array"
      else false
      end
    ' "$body" >/dev/null 2>&1 || exit 2
    body_media_type=$(jq -er '.mediaType' "$body") || exit 2
    [[ "$body_media_type" == "$content_type" ]] || exit 2
    printf 'exists\t-\n'
    ;;
  404)
    code=$(jq -er 'select((.errors | type) == "array" and (.errors | length) == 1) | .errors[0].code | select(type == "string")' "$body") || exit 2
    case "$code" in
      MANIFEST_UNKNOWN) printf 'first-publish\tMANIFEST_UNKNOWN\n' ;;
      NAME_UNKNOWN)
        [[ "$bootstrap" == true ]] || exit 2
        printf 'first-publish\tNAME_UNKNOWN\n'
        ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
