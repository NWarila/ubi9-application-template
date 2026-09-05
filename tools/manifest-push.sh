#!/usr/bin/env bash
set -euo pipefail

# Authorized digest-addressed staging write before attestation; this path cannot change a tag.

if [[ $# -ne 4 ]]; then
  echo "usage: manifest-push.sh IMAGE DIGEST FILE MEDIATYPE" >&2
  exit 6
fi
image=$1 digest=$2 file=$3 media_type=$4
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 6
case "$media_type" in
  application/vnd.oci.image.index.v1+json|application/vnd.oci.image.manifest.v1+json) ;;
  *) exit 6 ;;
esac
[[ -f "$file" ]] || exit 6

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmpl01a-push.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
oras_flags=()
crane_flags=()
if [[ "${REGISTRY_INSECURE:-0}" == 1 ]]; then
  oras_flags+=(--plain-http)
  crane_flags+=(--insecure)
fi
oras manifest push "${oras_flags[@]}" --media-type "$media_type" \
  --descriptor "${image}@${digest}" "$file" > "$work_dir/pushed-descriptor.json"
crane manifest "${crane_flags[@]}" "${image}@${digest}" > "$work_dir/fetched.bin"
cmp "$file" "$work_dir/fetched.bin"
[[ "sha256:$(sha256sum "$work_dir/fetched.bin" | cut -d' ' -f1)" == "$digest" ]]
jq -e --arg d "$digest" '.digest == $d' "$work_dir/pushed-descriptor.json" >/dev/null
