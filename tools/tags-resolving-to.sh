#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then exit 2; fi
owner=$1
owner_type=$2
name=$3
target_digest=$4
[[ "$owner" =~ ^[A-Za-z0-9-]+$ ]] || exit 2
[[ "$name" =~ ^[a-z0-9][a-z0-9._-]{0,127}$ ]] || exit 2
[[ "$target_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 2
case "$owner_type" in
  User) route="users/$owner" ;;
  Organization) route="orgs/$owner" ;;
  *) exit 2 ;;
esac
owner_lower=$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$owner" | tr -d '\n')
image="ghcr.io/${owner_lower}/${name}"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmpl01a-tags.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

if ! gh api --paginate "/${route}/packages/container/${name}/versions" \
  --jq '.[] | .metadata.container.tags[]' > "$work_dir/tags"; then
  exit 2
fi
if LC_ALL=C sort -u "$work_dir/tags" | awk 'length($0) == 0 {exit 1} {print}' > "$work_dir/sorted"; then :; else exit 2; fi
match=false
: > "$work_dir/rows"
while IFS= read -r tag; do
  [[ -n "$tag" ]] || exit 2
  if ! digest=$(crane digest "${image}:${tag}"); then exit 2; fi
  printf '%s\t%s\n' "$tag" "$digest" >> "$work_dir/rows"
  if [[ "$digest" == "$target_digest" ]]; then match=true; fi
done < "$work_dir/sorted"
cat "$work_dir/rows"
if [[ "$match" == true ]]; then exit 1; fi
