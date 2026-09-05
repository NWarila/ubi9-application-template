#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: clean-clone-umask-0007.sh LOCAL_SOURCE_REPOSITORY EXECUTABLE_TOOL_DIR [PACKET_OVERLAY]" >&2
  exit 6
fi

repository=$(realpath -e -- "$1") || exit 6
tool_dir=$(realpath -e -- "$2") || exit 6
[[ -d "$repository/.git" && -d "$tool_dir" ]] || exit 6
packet_overlay=
if [[ $# -eq 3 ]]; then
  packet_overlay=$(realpath -e -- "$3") || exit 6
  [[ -d "$packet_overlay/contracts" && -d "$packet_overlay/tools" && -d "$packet_overlay/tests" ]] || exit 6
fi

scratch=$(mktemp -d "$tool_dir/tmpl01a-clean-clone.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
clone="$scratch/clone"
installed="$scratch/installed"

(
  umask 0007
  git clone --quiet --local --no-hardlinks -- "$repository" "$clone"
)
[[ -z "$(git -C "$clone" status --short)" ]]
(( (8#$(stat -Lc '%a' "$clone/contracts/signers.json") & 0020) != 0 ))
if [[ -n "$packet_overlay" ]]; then
  (
    umask 0007
    cp -R -- "$packet_overlay/contracts/." "$clone/contracts/"
    cp -R -- "$packet_overlay/tools/." "$clone/tools/"
    cp -R -- "$packet_overlay/tests/." "$clone/tests/"
  )
fi

bash "$clone/tools/install-trust-tree.sh" "$clone" "$installed"
[[ -z "$(find "$installed" -xdev -perm /0022 -print -quit)" ]]

contracts_output=$(bash "$installed/tests/contracts.sh" "$tool_dir")
printf '%s\n' "$contracts_output"
[[ "${contracts_output##*$'\n'}" == 'TOTAL 207/207' ]]

mutations_output=$(bash "$installed/tests/mutations.sh" "$tool_dir")
printf '%s\n' "$mutations_output"
[[ "$(grep -c $'^MUTATION\t' <<< "$mutations_output")" -eq 77 ]]
