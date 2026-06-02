#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tests/runtime-hardening.sh <image-ref> [expected-entrypoint]

Inspect a built downstream UBI 9 (ubi-micro) image for the template's runtime
hardening baseline: non-root user; no shell; no dnf/microdnf/rpm/yum; no curl
or wget; the rpm database PRESENT (so scanners enumerate packages); the RHEL CA
bundle populated at /etc/pki/tls/certs/ca-bundle.crt; no setuid and no
world-writable-without-sticky paths; and the expected entrypoint.

expected-entrypoint defaults to /usr/local/bin/app; image repos pass their own
(e.g. /usr/local/bin/vault).
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

image_ref="${1:-}"
expected_entrypoint="${2:-/usr/local/bin/app}"
if [[ -z "${image_ref}" ]]; then
  usage >&2
  exit 2
fi

command -v docker >/dev/null 2>&1 || {
  echo "docker is required for runtime hardening assertions" >&2
  exit 2
}

tmp_dir="$(mktemp -d)"
rootfs_dir="${tmp_dir}/rootfs"
mkdir -p "${rootfs_dir}"
container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

container_id="$(docker create "${image_ref}")"
docker export "${container_id}" -o "${tmp_dir}/rootfs.tar"
tar -xf "${tmp_dir}/rootfs.tar" -C "${rootfs_dir}"
tar -tf "${tmp_dir}/rootfs.tar" | sed 's#^\./##' > "${tmp_dir}/files.txt"

assert_absent_file() {
  local path="${1#/}"
  if grep -Fxq "${path}" "${tmp_dir}/files.txt"; then
    echo "forbidden runtime file exists: /${path}" >&2
    exit 1
  fi
}

assert_absent_tree() {
  local path="${1#/}"
  if grep -Eq "^${path}(/|$)" "${tmp_dir}/files.txt"; then
    echo "forbidden runtime tree exists: /${path}" >&2
    exit 1
  fi
}

# No shell, no package manager, no network fetch tools in the runtime image.
for executable in \
  /bin/sh \
  /bin/bash \
  /bin/dash \
  /usr/bin/dnf \
  /usr/bin/microdnf \
  /usr/bin/rpm \
  /usr/bin/yum \
  /usr/bin/curl \
  /usr/bin/wget
do
  assert_absent_file "${executable}"
done

# Regenerable dnf cache/logs must not ship; the rpm DB and dnf history below
# are deliberately NOT in this list (they are required present).
for directory in \
  /var/cache/dnf
do
  assert_absent_tree "${directory}"
done

# The rpm database must be PRESENT and non-empty so Trivy/Grype/OpenSCAP can
# enumerate the installed packages. An empty rpmdb yields a false "zero CVE".
rpmdb_found=""
for candidate in \
  var/lib/rpm/rpmdb.sqlite \
  var/lib/rpm/Packages \
  var/lib/rpm/Packages.db
do
  if [[ -s "${rootfs_dir}/${candidate}" ]]; then
    rpmdb_found="${candidate}"
    break
  fi
done
if [[ -z "${rpmdb_found}" ]]; then
  echo "rpm database missing or empty under /var/lib/rpm (scanners would see zero packages)" >&2
  exit 1
fi

# The RHEL CA bundle must be populated. /etc/pki/tls/certs/ca-bundle.crt is a
# symlink into /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem on UBI, so
# resolve it inside the exported rootfs before asserting it carries certs. The
# Debian path (/etc/ssl/certs/ca-certificates.crt) does NOT exist on UBI.
resolve_in_rootfs() {
  local rel="${1#/}"
  local p="${rootfs_dir}/${rel}"
  local hops=0
  while [[ -L "${p}" && ${hops} -lt 8 ]]; do
    local tgt
    tgt="$(readlink "${p}")"
    case "${tgt}" in
      /*) p="${rootfs_dir}${tgt}" ;;
      *)  p="$(dirname "${p}")/${tgt}" ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s' "${p}"
}

ca_link="/etc/pki/tls/certs/ca-bundle.crt"
ca_real="$(resolve_in_rootfs "${ca_link}")"
if [[ ! -s "${ca_real}" ]]; then
  echo "CA bundle missing/empty: ${ca_link} (resolved to ${ca_real#${rootfs_dir}})" >&2
  exit 1
fi
if ! grep -q "BEGIN CERTIFICATE" "${ca_real}"; then
  echo "CA bundle at ${ca_link} contains no certificates" >&2
  exit 1
fi

# No setuid/setgid binaries.
mapfile -t setuid_hits < <(find "${rootfs_dir}" -type f -perm /6000 2>/dev/null || true)
if [[ ${#setuid_hits[@]} -gt 0 ]]; then
  echo "setuid/setgid files present in runtime image:" >&2
  printf '  /%s\n' "${setuid_hits[@]#${rootfs_dir}/}" >&2
  exit 1
fi

# No world-writable paths unless the sticky bit is set (e.g. /tmp).
mapfile -t ww_hits < <(find "${rootfs_dir}" -perm -0002 ! -perm -1000 2>/dev/null || true)
if [[ ${#ww_hits[@]} -gt 0 ]]; then
  echo "world-writable non-sticky paths present in runtime image:" >&2
  printf '  /%s\n' "${ww_hits[@]#${rootfs_dir}/}" >&2
  exit 1
fi

runtime_user="$(docker image inspect --format '{{.Config.User}}' "${image_ref}")"
case "${runtime_user}" in
  ""|"0"|"0:0"|"root")
    echo "image must run as a non-root numeric or named user; got '${runtime_user}'" >&2
    exit 1
    ;;
esac

entrypoint="$(docker image inspect --format '{{json .Config.Entrypoint}}' "${image_ref}")"
if [[ "${entrypoint}" == "null" || "${entrypoint}" != *"${expected_entrypoint}"* ]]; then
  echo "image entrypoint should target ${expected_entrypoint}; got ${entrypoint}" >&2
  exit 1
fi

echo "runtime hardening checks passed for ${image_ref} (rpmdb=${rpmdb_found}, entrypoint~=${expected_entrypoint})"
