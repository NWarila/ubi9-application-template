#!/usr/bin/bash -p
# shellcheck disable=SC2016,SC2034
set -euo pipefail

# This is the only TAG-MUTATING or PROMOTIONAL production path.

readonly BOOT_REALPATH=/usr/bin/realpath
readonly BOOT_SHA256SUM=/usr/bin/sha256sum
readonly BOOT_STAT=/usr/bin/stat
readonly BOOT_UNAME=/usr/bin/uname
case "$("$BOOT_UNAME" -m)" in
  x86_64)
    TRUST_BASH_SHA256=bc5945feb8bd26203ebfafea5ce1878bb2e32cb8fb50ab7ae395cfb1e1aaaef1
    TRUST_JQ_SHA256=59cfd58d7e470b103aede0e7589cfea929e45ee27f5471f08aa9676ac7bfc566
    TRUST_PYTHON_SHA256=a92f0f95e883390c7256b2e441484aac06b1002dbe1d924141a77c8d82f96223
    TRUST_GH_SHA256=553949e2efa12842771efe6012aa4de21f1d591530ec17fc435f610f10e017ee
    TRUST_CRANE_SHA256=8e75c326adb43b053cfd78b9b987663f8f4fe4557f4d3915905643f25c730992
    ;;
  aarch64)
    TRUST_BASH_SHA256=af955ef55333c8fc9c5aa50df91ad1a629d9a79a9afa125cd5e9629585f78015
    TRUST_JQ_SHA256=acac57d327657903ac38106ba2de53969ca9622634a5a48c3efcaa06beaa8ab8
    TRUST_PYTHON_SHA256=1401f5c1ddd9e8f9d77622113a8d04b5f7ef57c0e3f40dd29db248a5aa91622e
    TRUST_GH_SHA256=28a037b967065aa314cb6d539943b55d27ef2f97c523ab2b6023ccf284e1828d
    TRUST_CRANE_SHA256=1799f559c299f068951822a5efe6689ebab6974f2054d5562e60798fa9db6a55
    ;;
  *) exit 6 ;;
esac
readonly TRUST_BASH_SHA256 TRUST_JQ_SHA256 TRUST_PYTHON_SHA256 TRUST_GH_SHA256 TRUST_CRANE_SHA256
readonly CHECK_SIGNER_SHA256=f9bac137f05c1eeeee695d45a0f659e976914652be462c273c4b53a04cb390f8
readonly VERIFY_ATTESTATIONS_SHA256=4aac422a77dd65c130049e4bcd68183de5d553b88b100a5d0e7a7b0d1928ede3

trusted_dir() {
  local path=$1 owner=$2 metadata kind uid mode
  metadata=$("$BOOT_STAT" -Lc '%F|%u|%a' -- "$path") || return 1
  IFS='|' read -r kind uid mode <<<"$metadata"
  [[ "$kind" == directory && "$uid" == "$owner" ]] || return 1
  (( (8#$mode & 0022) == 0 && (8#$mode & 07000) == 0 ))
}

validate_self_file() {
  local canonical=$1 fd_path="/proc/$$/fd/255" metadata kind links uid mode physical actual
  local expected_hash=${TMPL01A_EXPECTED_SELF_SHA256:-}
  metadata=$("$BOOT_STAT" -Lc '%F|%h|%u|%a' -- "$fd_path") || return 1
  IFS='|' read -r kind links uid mode <<<"$metadata"
  [[ "$kind" == 'regular file' && "$links" == 1 && "$uid" == "$root_owner" ]] || return 1
  (( (8#$mode & 0022) == 0 && (8#$mode & 07000) == 0 && (8#$mode & 0111) != 0 )) || return 1
  physical=$("$BOOT_REALPATH" -e -- "$fd_path") || return 1
  [[ "$physical" == "$canonical" ]] || return 1
  actual=$("$BOOT_SHA256SUM" < "$fd_path") || return 1
  [[ -z "$expected_hash" || "${actual%% *}" == "$expected_hash" ]]
}

open_trusted_file() {
  local path=$1 canonical=$2 expected_hash=$3 require_exec=$4 output_name=$5
  local fd fd_path metadata kind links uid mode physical actual
  exec {fd}< "$path" || return 1
  fd_path="/proc/$$/fd/$fd"
  metadata=$("$BOOT_STAT" -Lc '%F|%h|%u|%a' -- "$fd_path") || return 1
  IFS='|' read -r kind links uid mode <<<"$metadata"
  [[ "$kind" == 'regular file' && "$links" == 1 && "$uid" == "$root_owner" ]] || return 1
  (( (8#$mode & 0022) == 0 && (8#$mode & 07000) == 0 )) || return 1
  if [[ "$require_exec" == yes ]]; then (( (8#$mode & 0111) != 0 )) || return 1; fi
  physical=$("$BOOT_REALPATH" -e -- "$fd_path") || return 1
  [[ "$physical" == "$canonical" ]] || return 1
  if [[ -n "$expected_hash" ]]; then
    actual=$("$BOOT_SHA256SUM" < "$fd_path") || return 1
    [[ "${actual%% *}" == "$expected_hash" ]] || return 1
  fi
  printf -v "$output_name" '%s' "$fd_path"
}

script_source=${BASH_SOURCE[0]}
script_path=$("$BOOT_REALPATH" -e -- "$script_source") || exit 6
tool_path=${script_path%/*}
installed_root=$("$BOOT_REALPATH" -e -- "$tool_path/..") || exit 6
[[ "$script_path" == "$installed_root/tools/verify-and-promote.sh" ]] || exit 6
root_owner=$("$BOOT_STAT" -Lc '%u' -- "$installed_root") || exit 6

runtime="$installed_root/tools/.tmpl01a-runtime"
trusted_dir "$installed_root" "$root_owner" || exit 6
trusted_dir "$tool_path" "$root_owner" || exit 6
trusted_dir "$runtime" "$root_owner" || exit 6
validate_self_file "$script_path" || exit 6
unset TMPL01A_EXPECTED_SELF_SHA256
open_trusted_file "$runtime/bash" "$runtime/bash" "$TRUST_BASH_SHA256" yes TRUST_BASH || exit 6
open_trusted_file "$runtime/jq" "$runtime/jq" "$TRUST_JQ_SHA256" yes TRUST_JQ || exit 6
open_trusted_file "$runtime/python3" "$runtime/python3" "$TRUST_PYTHON_SHA256" yes TRUST_PYTHON || exit 6
open_trusted_file "$runtime/gh" "$runtime/gh" "$TRUST_GH_SHA256" yes TRUST_GH || exit 6
open_trusted_file "$runtime/crane" "$runtime/crane" "$TRUST_CRANE_SHA256" yes TRUST_CRANE || exit 6
readonly TRUST_BASH TRUST_JQ TRUST_PYTHON TRUST_GH TRUST_CRANE

check_signer="$installed_root/tools/check-signer.sh"
verify_attestations="$installed_root/tools/verify-attestations.sh"
open_trusted_file "$check_signer" "$check_signer" "$CHECK_SIGNER_SHA256" yes TRUST_CHECK_SIGNER || exit 6
open_trusted_file "$verify_attestations" "$verify_attestations" "$VERIFY_ATTESTATIONS_SHA256" yes TRUST_VERIFY_ATTESTATIONS || exit 6
readonly TRUST_CHECK_SIGNER TRUST_VERIFY_ATTESTATIONS

: "${IMAGE:?required}"
: "${INDEX_DIGEST:?required}"
: "${CALLER_REPO:?required}"
: "${SIGNER_WORKFLOW:?required}"
: "${SIGNER_DIGEST:?required}"
: "${TEMPLATE_REF:?required}"
: "${SIGNER_ROLE:?required}"
: "${RUN_ID:?required}"
: "${RUN_ATTEMPT:?required}"
: "${PUBLISH_DATE:?required}"
: "${PROMOTE_STABLE:?required}"
: "${DECISION:?required}"

TMPL01A_EXPECTED_SELF_SHA256="$CHECK_SIGNER_SHA256" \
  "$TRUST_BASH" --noprofile --norc -p "$TRUST_CHECK_SIGNER"
TMPL01A_EXPECTED_SELF_SHA256="$VERIFY_ATTESTATIONS_SHA256" \
  "$TRUST_BASH" --noprofile --norc -p "$TRUST_VERIFY_ATTESTATIONS" >/dev/null

[[ "$INDEX_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 6
[[ "$RUN_ID" =~ ^[0-9]+$ ]] || exit 6
[[ "$RUN_ATTEMPT" =~ ^[0-9]+$ ]] || exit 6
[[ "$PUBLISH_DATE" =~ ^[0-9]{8}$ ]] || exit 6
[[ "$PROMOTE_STABLE" == true || "$PROMOTE_STABLE" == false ]] || exit 6
case "$DECISION:$SIGNER_ROLE" in
  publish:candidate|recovered:recovery) ;;
  *) exit 6 ;;
esac

tags=("build-${RUN_ID}-${RUN_ATTEMPT}" "$PUBLISH_DATE")
policies=(immutable mutable)
if [[ "$PROMOTE_STABLE" == true ]]; then
  tags+=(stable)
  policies+=(mutable)
fi
tags+=(latest)
policies+=(mutable)

[[ "${tags[0]}" =~ ^build-[0-9]+-[0-9]+$ ]] || exit 6
[[ "${tags[1]}" =~ ^[0-9]{8}$ ]] || exit 6
[[ "${tags[-1]}" == latest ]] || exit 6
crane_flags=()
if [[ "${REGISTRY_INSECURE:-0}" == 1 ]]; then crane_flags+=(--insecure); fi
for i in "${!tags[@]}"; do
  tag=${tags[$i]}
  policy=${policies[$i]}
  if [[ "$policy" == immutable ]]; then
    if ! status_line=$("$TRUST_BASH" --noprofile --norc -p "$installed_root/tools/registry-status.sh" "$IMAGE" "$tag"); then
      exit 2
    fi
    case "$status_line" in
      $'first-publish\tMANIFEST_UNKNOWN'|$'first-publish\tNAME_UNKNOWN') ;;
      $'exists\t-')
        if ! existing=$("$TRUST_CRANE" digest "${crane_flags[@]}" "${IMAGE}:${tag}"); then exit 2; fi
        if [[ "$existing" == "$INDEX_DIGEST" ]]; then
          continue
        fi
        exit 3
        ;;
      *) exit 2 ;;
    esac
  fi
  if ! "$TRUST_CRANE" tag "${crane_flags[@]}" "${IMAGE}@${INDEX_DIGEST}" "$tag" >/dev/null; then exit 2; fi
  actual=$("$TRUST_CRANE" digest "${crane_flags[@]}" "${IMAGE}:${tag}") || exit 4
  [[ "$actual" == "$INDEX_DIGEST" ]] || exit 4
done
tags_json=$(printf '%s\n' "${tags[@]}" | "$TRUST_JQ" -Rsc 'split("\n")[:-1]')
"$TRUST_JQ" -cn --arg decision "$DECISION" --argjson tags "$tags_json" \
  '{decision:$decision,"tags-written":$tags}'
