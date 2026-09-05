#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: install-trust-tree.sh SOURCE_ROOT INSTALL_ROOT" >&2
  exit 6
fi

source_root=$(realpath -e -- "$1") || exit 6
install_root=$(realpath -m -- "$2") || exit 6
[[ -d "$source_root" && ! -L "$source_root" && "$source_root" != "$install_root" ]] || exit 6
case "$install_root/" in
  "$source_root"/*) exit 6 ;;
esac

if [[ -e "$install_root" ]]; then
  [[ -d "$install_root" && ! -L "$install_root" ]] || exit 6
  [[ -z "$(find "$install_root" -mindepth 1 -print -quit)" ]] || exit 6
else
  install -d -m 0755 -- "$install_root" || exit 6
fi
chmod 0755 -- "$install_root" || exit 6

for top in contracts tools tests; do
  [[ -d "$source_root/$top" && ! -L "$source_root/$top" ]] || exit 6
  if find "$source_root/$top" -xdev ! -type d ! -type f -print -quit | grep -q .; then
    echo "unsupported trust-tree object below $top" >&2
    exit 6
  fi
done

while IFS= read -r -d '' source_dir; do
  relative=${source_dir#"$source_root"/}
  install -d -m 0755 -- "$install_root/$relative"
done < <(find "$source_root"/contracts "$source_root"/tools "$source_root"/tests \
  -xdev -type d -print0)

while IFS= read -r -d '' source_file; do
  relative=${source_file#"$source_root"/}
  source_mode=$(stat -Lc '%a' -- "$source_file") || exit 6
  case "$relative" in
    tools/.tmpl01a-runtime/*)
      [[ "$relative" == tools/.tmpl01a-runtime/README ]] || continue
      mode=0644
      ;;
    tools/check-signer.sh|tools/verify-attestations.sh|tools/verify-and-promote.sh|tools/verify-build-materials.sh)
      mode=0555
      ;;
    *)
      if (( (8#$source_mode & 0111) != 0 )); then mode=0755; else mode=0644; fi
      ;;
  esac
  install -m "$mode" -- "$source_file" "$install_root/$relative"
done < <(find "$source_root"/contracts "$source_root"/tools "$source_root"/tests \
  -xdev -type f -print0)

while IFS= read -r -d '' installed_dir; do
  chmod 0755 -- "$installed_dir"
done < <(find "$install_root" -xdev -type d -print0)

if find "$install_root" -xdev \( -perm /0022 -o ! -user "$(id -un)" \) -print -quit | grep -q .; then
  echo "unsafe installed trust-tree ownership or mode" >&2
  exit 6
fi
