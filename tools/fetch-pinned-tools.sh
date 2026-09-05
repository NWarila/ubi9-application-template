#!/usr/bin/env bash
set -euo pipefail

install_dir="${1:-/tmp/tmpl01a-tools}"
case "$(uname -m)" in
  x86_64) arch=amd64; crane_arch=x86_64 ;;
  aarch64) arch=arm64; crane_arch=arm64 ;;
  *) echo "unsupported architecture" >&2; exit 6 ;;
esac

case "$arch" in
  amd64)
    oras_sha=f27adb935022d94df8dc77719c322dda592c78a0d57a6f7dcdd8d900b248c454
    crane_sha=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
    syft_sha=8fcb33017a0dc1058298c923c436d19dfa68ae93968e0b423248542e3afb9fc3
    gh_sha=e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be
    buildx_sha=ae43fa08c796b44efc86d7a63c55f73f7c35f3101188dea7bf93bcd6f99577ba
    registry_sha=6f330a3ba9ea1d23a6ee189f449d792595240585bb2f159123d76ac594f70dd8
    runtime_bash_sha=bc5945feb8bd26203ebfafea5ce1878bb2e32cb8fb50ab7ae395cfb1e1aaaef1
    runtime_jq_sha=59cfd58d7e470b103aede0e7589cfea929e45ee27f5471f08aa9676ac7bfc566
    runtime_python_sha=a92f0f95e883390c7256b2e441484aac06b1002dbe1d924141a77c8d82f96223
    runtime_gh_sha=553949e2efa12842771efe6012aa4de21f1d591530ec17fc435f610f10e017ee
    runtime_crane_sha=8e75c326adb43b053cfd78b9b987663f8f4fe4557f4d3915905643f25c730992
    ;;
  arm64)
    oras_sha=15702c6e3a4a56a8bd8ac5c17efdbcab56d9bada661ccbcf017f5b10c1d89399
    crane_sha=898c0cff975f898a33e8c4580bdafb0e7c02c7faa33374e946762f97c4ab7110
    syft_sha=a7fd2b784e6664acd44719270574f6cd8c6864fc2b1700bf9099bd1cccda7d7f
    gh_sha=ea4e7a581a32ccad6cc7923cb1576ac5859ba4b9a16ab22eb8f8a96e78e2e961
    buildx_sha=d263ce31bd2c9e9210aaa2c7537c67802bccabcd342e4c9fe4907085ddb41aa5
    registry_sha=8167316d2b4a57e10d44f8c8a3c75fea5f3ec1c71872760bb903e5e8e52e9ad6
    runtime_bash_sha=af955ef55333c8fc9c5aa50df91ad1a629d9a79a9afa125cd5e9629585f78015
    runtime_jq_sha=acac57d327657903ac38106ba2de53969ca9622634a5a48c3efcaa06beaa8ab8
    runtime_python_sha=1401f5c1ddd9e8f9d77622113a8d04b5f7ef57c0e3f40dd29db248a5aa91622e
    runtime_gh_sha=28a037b967065aa314cb6d539943b55d27ef2f97c523ab2b6023ccf284e1828d
    runtime_crane_sha=1799f559c299f068951822a5efe6689ebab6974f2054d5562e60798fa9db6a55
    ;;
esac

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
runtime_dir="$root_dir/tools/.tmpl01a-runtime"
cache_dir="${TMPDIR:-/tmp}/tmpl01a-download-cache"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmpl01a-fetch.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p "$install_dir" "$cache_dir"

fetch() {
  local url=$1 sha=$2 name=${1##*/} target="$cache_dir/${1##*/}"
  if [[ ! -f "$target" ]] || [[ "$(sha256sum "$target" | cut -d' ' -f1)" != "$sha" ]]; then
    rm -f -- "$target"
    curl --fail --location --silent --show-error --retry 3 --output "$target" "$url"
  else
    curl --fail --location --silent --show-error --retry 3 --time-cond "$target" --output "$target.new" "$url" || true
    if [[ -s "$target.new" ]]; then mv -f -- "$target.new" "$target"; else rm -f -- "$target.new"; fi
  fi
  printf '%s  %s\n' "$sha" "$target" | sha256sum -c -
  cp -- "$target" "$work_dir/$name"
}

oras_file="oras_1.3.4_linux_${arch}.tar.gz"
crane_file="go-containerregistry_Linux_${crane_arch}.tar.gz"
syft_file="syft_1.51.1_linux_${arch}.tar.gz"
gh_file="gh_2.100.0_linux_${arch}.tar.gz"
buildx_file="buildx-v0.37.0.linux-${arch}"
registry_file="registry_3.1.1_linux_${arch}.tar.gz"

fetch "https://github.com/oras-project/oras/releases/download/v1.3.4/$oras_file" "$oras_sha"
fetch "https://github.com/google/go-containerregistry/releases/download/v0.22.1/$crane_file" "$crane_sha"
fetch "https://github.com/anchore/syft/releases/download/v1.51.1/$syft_file" "$syft_sha"
fetch "https://github.com/cli/cli/releases/download/v2.100.0/$gh_file" "$gh_sha"
fetch "https://github.com/docker/buildx/releases/download/v0.37.0/$buildx_file" "$buildx_sha"
fetch "https://github.com/distribution/distribution/releases/download/v3.1.1/$registry_file" "$registry_sha"

tar -xzf "$work_dir/$oras_file" -C "$work_dir" oras
install -m 0755 "$work_dir/oras" "$install_dir/oras"
tar -xzf "$work_dir/$crane_file" -C "$work_dir" crane
install -m 0755 "$work_dir/crane" "$install_dir/crane"
tar -xzf "$work_dir/$syft_file" -C "$work_dir" syft
install -m 0755 "$work_dir/syft" "$install_dir/syft"
tar -xzf "$work_dir/$gh_file" -C "$work_dir" "gh_2.100.0_linux_${arch}/bin/gh"
install -m 0755 "$work_dir/gh_2.100.0_linux_${arch}/bin/gh" "$install_dir/gh"
install -m 0755 "$work_dir/$buildx_file" "$install_dir/docker-buildx"
tar -xzf "$work_dir/$registry_file" -C "$work_dir" registry
install -m 0755 "$work_dir/registry" "$install_dir/registry"

install -d -m 0755 -- "$runtime_dir"
for runtime_source in /usr/bin/bash /usr/bin/jq /usr/bin/python3; do
  [[ -f "$runtime_source" ]] || exit 6
done
printf '%s  %s\n' "$runtime_bash_sha" /usr/bin/bash | /usr/bin/sha256sum -c -
printf '%s  %s\n' "$runtime_jq_sha" /usr/bin/jq | /usr/bin/sha256sum -c -
printf '%s  %s\n' "$runtime_python_sha" /usr/bin/python3 | /usr/bin/sha256sum -c -
printf '%s  %s\n' "$runtime_gh_sha" "$install_dir/gh" | /usr/bin/sha256sum -c -
printf '%s  %s\n' "$runtime_crane_sha" "$install_dir/crane" | /usr/bin/sha256sum -c -
install -m 0555 /usr/bin/bash "$runtime_dir/bash"
install -m 0555 /usr/bin/jq "$runtime_dir/jq"
install -m 0555 /usr/bin/python3 "$runtime_dir/python3"
install -m 0555 "$install_dir/gh" "$runtime_dir/gh"
install -m 0555 "$install_dir/crane" "$runtime_dir/crane"

rm -rf -- "$install_dir/pylib"
python3 -m pip install --disable-pip-version-check --no-compile --require-hashes \
  --target "$install_dir/pylib" -r "$root_dir/tests/fixtures/requirements-spdx.txt"
