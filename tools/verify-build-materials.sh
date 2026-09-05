#!/usr/bin/bash -p
# shellcheck disable=SC2034
set -euo pipefail

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
  *) exit 1 ;;
esac
readonly TRUST_BASH_SHA256 TRUST_JQ_SHA256 TRUST_PYTHON_SHA256 TRUST_GH_SHA256 TRUST_CRANE_SHA256
readonly MATERIALS_PY_SHA256=1307f9786a5952e1f2ca7765224b621ecdba97ab4b3a73d2cf873bdd50e06670
readonly ROOT_BASE_SHA256=7a315213952c6bd4344e7e327452f2172cde55e97af0fa294eb8533845bc51c4
readonly BUILDERS_SHA256=9b84b8d019c62e5f271f9729ded23c8682729838fc48445b4f13afdec1f196e1

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
script_path=$("$BOOT_REALPATH" -e -- "$script_source") || exit 1
tool_path=${script_path%/*}
installed_root=$("$BOOT_REALPATH" -e -- "$tool_path/..") || exit 1
[[ "$script_path" == "$installed_root/tools/verify-build-materials.sh" ]] || exit 1
root_owner=$("$BOOT_STAT" -Lc '%u' -- "$installed_root") || exit 1

runtime="$installed_root/tools/.tmpl01a-runtime"
contracts="$installed_root/contracts"
trusted_dir "$installed_root" "$root_owner" || exit 1
trusted_dir "$tool_path" "$root_owner" || exit 1
trusted_dir "$runtime" "$root_owner" || exit 1
trusted_dir "$contracts" "$root_owner" || exit 1
validate_self_file "$script_path" || exit 1
unset TMPL01A_EXPECTED_SELF_SHA256
open_trusted_file "$runtime/bash" "$runtime/bash" "$TRUST_BASH_SHA256" yes TRUST_BASH || exit 1
open_trusted_file "$runtime/jq" "$runtime/jq" "$TRUST_JQ_SHA256" yes TRUST_JQ || exit 1
open_trusted_file "$runtime/python3" "$runtime/python3" "$TRUST_PYTHON_SHA256" yes TRUST_PYTHON || exit 1
open_trusted_file "$runtime/gh" "$runtime/gh" "$TRUST_GH_SHA256" yes TRUST_GH || exit 1
open_trusted_file "$runtime/crane" "$runtime/crane" "$TRUST_CRANE_SHA256" yes TRUST_CRANE || exit 1

materials_py="$installed_root/tools/verify-build-materials.py"
root_base="$contracts/root-base.json"
builders="$contracts/builders.json"
open_trusted_file "$materials_py" "$materials_py" "$MATERIALS_PY_SHA256" no TRUST_MATERIALS_PY || exit 1
open_trusted_file "$root_base" "$root_base" "$ROOT_BASE_SHA256" no TRUST_ROOT_BASE || exit 1
open_trusted_file "$builders" "$builders" "$BUILDERS_SHA256" no TRUST_BUILDERS || exit 1
readonly TRUST_BASH TRUST_JQ TRUST_PYTHON TRUST_GH TRUST_CRANE
readonly TRUST_MATERIALS_PY TRUST_ROOT_BASE TRUST_BUILDERS

unset PYTHONHOME PYTHONPATH PYTHONUSERBASE
export PYTHONNOUSERSITE=1 PYTHONSAFEPATH=1
export TMPL01A_INSTALLED_ROOT="$installed_root"
export TMPL01A_MATERIALS_SOURCE_FD="${TRUST_MATERIALS_PY##*/}"
export TMPL01A_ROOT_BASE_FD="${TRUST_ROOT_BASE##*/}"
export TMPL01A_BUILDERS_FD="${TRUST_BUILDERS##*/}"
export TMPL01A_MATERIALS_SOURCE_SHA256="$MATERIALS_PY_SHA256"
exec "$TRUST_PYTHON" -I "$TRUST_MATERIALS_PY" "$@"
