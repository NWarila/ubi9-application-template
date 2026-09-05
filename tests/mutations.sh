#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: mutations.sh EXECUTABLE_TOOL_DIR" >&2
  exit 6
fi
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(bash "$root_dir/tests/contracts.sh" "$1")
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
[[ "${output##*$'\n'}" == 'TOTAL 203/203' ]]
for row in "${rows[@]}"; do
  fixture=${row%%|*}
  exit_code=${row#*|}
  [[ "$(grep -Fxc "PASS $fixture" <<<"$output")" -eq 1 ]]
  printf 'MUTATION\t%s\t%s\n' "$fixture" "$exit_code"
done
