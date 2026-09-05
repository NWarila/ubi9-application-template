#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: mutations.sh EXECUTABLE_TOOL_DIR" >&2
  exit 6
fi
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool_dir=$(cd "$1" && pwd -P)
scratch=$(mktemp -d "$tool_dir/tmpl01a-mutations.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
installed_root="$scratch/installed"
status_file="$scratch/observed-statuses"
ids_file="$scratch/mutation-ids"
: > "$status_file"
: > "$ids_file"
rows=(
  'manifest-corrupt|1'
  'index-swapped|1'
  'descriptor-variant|1'
  'dockerfile-unbraced|1'
  'dockerfile-comment-smuggle|1'
  'pkgset-two|1'
  'pkgset-tab|1'
  'registry-503|2'
  'registry-401|2'
  'promote-mismatch|4'
  'verify-fail-4|1'
  'signer-unknown-old|6'
  'signer-candidate-wrong-workflow|6'
  'promote-candidate-wrong-workflow|6'
  'promote-probe-digest-error|2'
  'dockerfile-external-copy|1'
  'dockerfile-external-run-mount|1'
  'dockerfile-parser-directive|6'
  'pkgset-percent-0a|1'
  'pkgset-missing-root|1'
  'registry-200-html|2'
  'signer-env-override|6'
  'promotion-direct-rejected|127'
  'dockerfile-policy-override|2'
  'schema-root-forbidden|1'
  'schema-root-pull-request|1'
  'schema-root-homoglyph|1'
  'schema-context-extra-property|1'
  'schema-root-extra-property|1'
  'dockerfile-indirect-arg|1'
  'dockerfile-platform-unapproved|1'
  'dockerfile-mixed-case-copy|1'
  'dockerfile-mixed-case-run-mount|1'
  'dockerfile-heredoc-copy|6'
  'dockerfile-onbuild|6'
  'pkgset-percent-slash|1'
  'pkgset-multiple-at|1'
  'pkgset-dual-arch-root|1'
  'pkgset-percent-at|1'
  'pkgset-percent-question|1'
  'pkgset-percent-hash|1'
  'pkgset-zero-at|1'
  'pkgset-empty-version|1'
  'pkgset-malformed-qualifier|1'
  'materials-extra-alpine|1'
  'materials-missing-digest|1'
  'materials-different-digest|1'
  'materials-syntax-frontend|1'
  'materials-resolved-dependencies-incomplete|1'
  'materials-resolved-dependencies-missing-completeness|1'
  'materials-wrong-build-type|1'
  'runtime-path-fake-bash|6'
  'runtime-path-fake-jq|6'
  'runtime-path-fake-gh|6'
  'runtime-path-fake-crane|6'
  'runtime-path-fake-python3|1'
  'runtime-pythonpath-json|1'
  'trust-hardlink-check-signer|6'
  'trust-hardlink-verify-attestations|6'
  'trust-hardlink-verify-and-promote|6'
  'trust-hardlink-materials-tool|1'
  'trust-hardlink-signers-policy|6'
  'trust-hardlink-root-base-policy|1'
  'trust-hardlink-builders-policy|1'
  'registry-text-plain|2'
  'registry-schema-version-1|2'
  'registry-redirect|2'
  'registry-malformed-chunk|2'
  'registry-missing-content-type|2'
  'registry-duplicate-content-type|2'
  'registry-malformed-content-type|2'
  'registry-conflicting-content-type|2'
  'promote-nonnumeric-run-id|6'
  'signer-uppercase-digest|6'
  'signer-symlink-escape|6'
  'trust-open-once-runtime-swap|0'
  'signer-single-snapshot|0'
  'trust-mode-group-file|6'
  'trust-mode-group-parent|1'
  'trust-mode-world-runtime|6'
)
for row in "${rows[@]}"; do
  printf '%s\n' "${row%%|*}" >> "$ids_file"
done
bash "$source_root/tools/install-trust-tree.sh" "$source_root" "$installed_root"
output=$(TMPL01A_META_INNER=1 \
  TMPL01A_OBSERVED_STATUS_FILE="$status_file" \
  TMPL01A_OBSERVED_IDS_FILE="$ids_file" \
  bash "$installed_root/tests/contracts.sh" "$tool_dir")
[[ "${output##*$'\n'}" == 'TOTAL 210/210' ]]
[[ "$(wc -l < "$status_file")" -eq "${#rows[@]}" ]]
for row in "${rows[@]}"; do
  fixture=${row%%|*}
  expected=${row#*|}
  [[ "$(grep -Fxc "PASS $fixture" <<<"$output")" -eq 1 ]]
  count=$(awk -F '|' -v id="$fixture" '$1 == id {count++} END {print count + 0}' "$status_file")
  if [[ "$count" -ne 1 ]]; then
    printf 'mutation %s: expected one observed status, got %s\n' "$fixture" "$count" >&2
    exit 1
  fi
  observed=$(awk -F '|' -v id="$fixture" '$1 == id {print $2}' "$status_file")
  if [[ "$observed" != "$expected" ]]; then
    printf 'mutation %s: expected %s, observed %s\n' "$fixture" "$expected" "$observed" >&2
    exit 1
  fi
  printf 'MUTATION\t%s\t%s\n' "$fixture" "$observed"
done
