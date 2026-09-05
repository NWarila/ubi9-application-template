#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: noexec-construction.sh SOURCE_TREE EXECUTABLE_TOOL_DIR" >&2
  exit 6
fi
source_tree=$(cd "$1" && pwd)
install_dir=$2
mkdir -p -- "$install_dir"
scratch=$(mktemp -d /tmp/tmpl01a-noexec.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
case ",$(findmnt -T "$scratch" -no OPTIONS)," in
  *,noexec,*) ;;
  *) echo "/tmp is not a noexec mount" >&2; exit 6 ;;
esac
copy="$scratch/tree"
bash "$source_tree/tools/install-trust-tree.sh" "$source_tree" "$copy"
derived="$scratch/.tmpl01a-tools"
[[ ! -e "$derived" ]]
output=$(bash "$copy/tests/contracts.sh" "$install_dir")
printf '%s\n' "$output"
[[ "$output" != *'FAIL '* ]]
[[ "${output##*$'\n'}" == 'TOTAL 210/210' ]]
[[ ! -e "$derived" ]]
