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

The image filesystem is inspected from `docker export` without extracting it
(tar -tvf for the manifest + permissions, tar -xOf for single-file contents) so
the check is identical on Linux CI runners and developer workstations and never
depends on the host's ability to recreate the rootfs's symlinks/devices.
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
tar_path="${tmp_dir}/rootfs.tar"
container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

container_id="$(docker create "${image_ref}")"
docker export "${container_id}" -o "${tar_path}"

# Path manifest (normalized: no leading ./, no trailing / on dirs for matching).
tar -tf "${tar_path}" | sed -e 's#^\./##' > "${tmp_dir}/files.txt"
# Verbose manifest: mode owner size date time path[ -> target]. Used for the
# permission scans below.
tar -tvf "${tar_path}" > "${tmp_dir}/files-v.txt"

# Emit one file to stdout from the tar, tolerating the optional leading ./.
extract_file() {
  local rel="${1#/}"
  tar -xOf "${tar_path}" "${rel}" 2>/dev/null \
    || tar -xOf "${tar_path}" "./${rel}" 2>/dev/null \
    || true
}

assert_absent_file() {
  local path="${1#/}"
  if grep -Fxq "${path}" "${tmp_dir}/files.txt" || grep -Fxq "${path}/" "${tmp_dir}/files.txt"; then
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
  if [[ "$(extract_file "${candidate}" | wc -c)" -gt 0 ]]; then
    rpmdb_found="${candidate}"
    break
  fi
done
if [[ -z "${rpmdb_found}" ]]; then
  echo "rpm database missing or empty under /var/lib/rpm (scanners would see zero packages)" >&2
  exit 1
fi

# The RHEL CA bundle must be populated. /etc/pki/tls/certs/ca-bundle.crt is a
# symlink into /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem on UBI; check
# the resolved regular file (and the link path itself, in case an image ships a
# regular file there). The Debian path /etc/ssl/certs/ca-certificates.crt does
# NOT exist on UBI.
ca_ok=""
for candidate in \
  etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  etc/pki/tls/certs/ca-bundle.crt
do
  if extract_file "${candidate}" | grep -q "BEGIN CERTIFICATE"; then
    ca_ok="${candidate}"
    break
  fi
done
if [[ -z "${ca_ok}" ]]; then
  echo "CA bundle empty/absent: expected certificates reachable from /etc/pki/tls/certs/ca-bundle.crt" >&2
  exit 1
fi

# Permission scans from the verbose manifest (no extraction needed). Field 1 is
# the mode string (type + 9 perm bits); symlinks (l...) are skipped.
violations="$(awk '
  {
    mode = $1
    type = substr(mode, 1, 1)
    if (type == "l") next
    # path is everything after the 5 leading fields (mode owner size date time)
    path = $0
    sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", path)
    setuid = substr(mode, 4, 1)
    setgid = substr(mode, 7, 1)
    owrite = substr(mode, 9, 1)
    sticky = substr(mode, 10, 1)
    if (setuid == "s" || setuid == "S" || setgid == "s" || setgid == "S")
      print "setuid/setgid: " path
    if (owrite == "w" && sticky != "t" && sticky != "T")
      print "world-writable (no sticky): " path
  }
' "${tmp_dir}/files-v.txt")"
if [[ -n "${violations}" ]]; then
  echo "runtime image permission violations:" >&2
  printf '  %s\n' "${violations}" >&2
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

echo "runtime hardening checks passed for ${image_ref} (rpmdb=${rpmdb_found}, ca=${ca_ok}, entrypoint~=${expected_entrypoint})"
