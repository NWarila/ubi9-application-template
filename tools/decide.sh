#!/usr/bin/env bash
set -euo pipefail

required=(IMAGE INDEX_DIGEST CANDIDATE_SBOM GIT_SHA BASE_DIGEST CALLER_REPO SIGNER_WORKFLOW FORCE BOOTSTRAP TEMPLATE_REF)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || exit 6
done
[[ ${CURRENT_SIGNER_DIGEST+x} ]] || exit 6
[[ "$INDEX_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 6
[[ "$GIT_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 6
[[ "$BASE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 6
[[ "$TEMPLATE_REF" =~ ^[0-9a-f]{40}$ ]] || exit 6
[[ "$FORCE" == true || "$FORCE" == false ]] || exit 6
[[ "$BOOTSTRAP" == true || "$BOOTSTRAP" == false ]] || exit 6
[[ -f "$CANDIDATE_SBOM" ]] || exit 6
tool_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
current_signer=${CURRENT_SIGNER_DIGEST:-$TEMPLATE_REF}
SIGNER_DIGEST=$current_signer SIGNER_ROLE=current bash "$tool_dir/check-signer.sh" || exit 6

export BOOTSTRAP
if ! status_line=$(bash "$tool_dir/registry-status.sh" "$IMAGE" latest); then exit 2; fi
case "$status_line" in
  $'first-publish\tMANIFEST_UNKNOWN'|$'first-publish\tNAME_UNKNOWN')
    printf '%s\n' '{"decision":"publish","reasons":["first-publish"]}'
    exit 0
    ;;
  $'exists\t-') ;;
  *) exit 2 ;;
esac

crane_flags=()
if [[ "${REGISTRY_INSECURE:-0}" == 1 ]]; then crane_flags+=(--insecure); fi
current=$(crane digest "${crane_flags[@]}" "${IMAGE}:latest") || exit 2
[[ "$current" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 2
if ! INDEX_DIGEST=$current SIGNER_DIGEST=$current_signer \
  bash "$tool_dir/verify-attestations.sh" >/dev/null; then
  exit 3
fi

if ! verified_spdx=$(gh attestation verify "oci://${IMAGE}@${current}" -R "$CALLER_REPO" \
  --signer-workflow "$SIGNER_WORKFLOW" --signer-digest "$current_signer" \
  --predicate-type https://spdx.dev/Document/v2.3 --format json); then
  exit 3
fi
current_hex=${current#sha256:}
if ! jq -e --arg d "$current_hex" '
  type == "array" and length == 1 and
  .[0].verificationResult.statement.predicateType == "https://spdx.dev/Document/v2.3" and
  any(.[0].verificationResult.statement.subject[]?; .digest.sha256 == $d)
' <<<"$verified_spdx" >/dev/null; then
  exit 5
fi
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmpl01a-decide.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
jq -e '.[0].verificationResult.statement.predicate' <<<"$verified_spdx" > "$work_dir/current-sbom.json" || exit 5

if ! crane manifest "${crane_flags[@]}" "${IMAGE}@${current}" > "$work_dir/current-index.json"; then exit 2; fi
if ! amd64_child=$(jq -er '
  [.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")] as $m
  | if ($m | length) == 1 then $m[0].digest else error("linux/amd64 child cardinality") end
  | select(test("^sha256:[0-9a-f]{64}$"))
' "$work_dir/current-index.json"); then
  exit 5
fi
if ! crane config "${crane_flags[@]}" "${IMAGE}@${amd64_child}" > "$work_dir/current-config.json"; then exit 2; fi
revision=$(jq -r '.config.Labels["org.opencontainers.image.revision"] // ""' "$work_dir/current-config.json") || exit 2
base=$(jq -r '.config.Labels["io.nwarila.base.digest"] // ""' "$work_dir/current-config.json") || exit 2

mkdir "$work_dir/current" "$work_dir/candidate"
if ! current_amd=$(cd "$work_dir/current" && bash "$tool_dir/pkgset.sh" "$work_dir/current-sbom.json" amd64); then exit 5; fi
if ! current_arm=$(cd "$work_dir/current" && bash "$tool_dir/pkgset.sh" "$work_dir/current-sbom.json" arm64); then exit 5; fi
candidate_path=$(cd "$(dirname "$CANDIDATE_SBOM")" && pwd)/$(basename "$CANDIDATE_SBOM")
if ! candidate_amd=$(cd "$work_dir/candidate" && bash "$tool_dir/pkgset.sh" "$candidate_path" amd64); then exit 5; fi
if ! candidate_arm=$(cd "$work_dir/candidate" && bash "$tool_dir/pkgset.sh" "$candidate_path" arm64); then exit 5; fi

reasons=()
if [[ "$FORCE" == true ]]; then reasons+=(force); fi
if [[ "$revision" != "$GIT_SHA" ]]; then reasons+=(revision); fi
if [[ "$base" != "$BASE_DIGEST" ]]; then reasons+=(base); fi
if [[ "$current_amd" != "$candidate_amd" ]]; then reasons+=(pkgset-amd64); fi
if [[ "$current_arm" != "$candidate_arm" ]]; then reasons+=(pkgset-arm64); fi
if [[ ${#reasons[@]} -eq 0 ]]; then
  printf '%s\n' '{"decision":"unchanged","reasons":[]}'
else
  reasons_json=$(printf '%s\n' "${reasons[@]}" | jq -Rsc 'split("\n")[:-1]')
  jq -cn --argjson reasons "$reasons_json" '{decision:"publish",reasons:$reasons}'
fi
