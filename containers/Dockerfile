# syntax=docker/dockerfile:1.7

# BuildKit SBOMs should include the build context as well as the builder stages
# that assemble and verify the runtime rootfs and application inputs, not only
# the final image. BUILDKIT_SBOM_SCAN_CONTEXT is a global ARG;
# BUILDKIT_SBOM_SCAN_STAGE must be set as a per-stage ARG inside each stage that
# should be scanned (see
# https://docs.docker.com/build/metadata/attestations/sbom/#configure-sbom-scanners).
ARG BUILDKIT_SBOM_SCAN_CONTEXT=true

# Both bases are digest-pinned (see the image manifest) and Renovate-managed
# with redhat versioning. ubi-minimal carries dnf for the builder; ubi-micro is
# the minimal runtime.
ARG UBI_MINIMAL_IMAGE
ARG UBI_MICRO_IMAGE

FROM ${UBI_MINIMAL_IMAGE} AS rpm-rootfs
ARG BUILDKIT_SBOM_SCAN_STAGE=true
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TARGETARCH
# Space-separated dnf package install specs (names), e.g. "ca-certificates".
ARG DNF_PACKAGES
# Optional space-separated repo IDs to enable exclusively. Empty = use the base
# image's default repositories.
ARG DNF_REPOS=""

# Assemble the runtime rootfs with microdnf --installroot so the resulting tree
# contains the rpm database (/var/lib/rpm) and dnf history (/var/lib/dnf).
# ubi-minimal ships microdnf (not dnf); --installroot requires it to be told
# where the host's repo/vars/config live (it cannot infer them from the empty
# installroot). PRESERVING the rpmdb is mandatory: it is how Trivy/Grype/OpenSCAP
# enumerate the installed packages. Deleting it would make scanners report zero
# packages (a false "0 CVE" result), so this stage NEVER removes
# /rootfs/var/lib/rpm or /rootfs/var/lib/dnf. Only regenerable cache/logs are pruned.
# The dependency closure of any RPM also drags the base shell (bash) into an empty
# installroot; a hardened runtime ships NO shell, so bash (and its /usr/bin/sh
# symlink) is removed below with rpm -e --noscripts while the rpmdb is preserved,
# and the stage fails closed if any shell survives. (No '#' comments inside the
# RUN: a comment line breaks the '\' continuation and silently drops the rest.)
RUN set -eux; \
    test -n "${DNF_PACKAGES}" || { echo "DNF_PACKAGES must be set" >&2; exit 1; }; \
    mkdir -p /rootfs; \
    microdnf install -y --installroot=/rootfs --releasever=9 \
      --config=/etc/dnf/dnf.conf --noplugins \
      --setopt=reposdir=/etc/yum.repos.d \
      --setopt=varsdir=/etc/dnf/vars \
      --setopt=cachedir=/var/cache/microdnf-installroot \
      --nodocs --setopt=install_weak_deps=0 \
      ${DNF_REPOS:+--disablerepo=* --enablerepo=${DNF_REPOS}} \
      ${DNF_PACKAGES}; \
    microdnf clean all; \
    rm -rf /rootfs/var/cache/* /var/cache/microdnf-installroot \
      /rootfs/var/log/dnf.log /rootfs/var/log/dnf.librepo.log /rootfs/var/log/hawkey.log; \
    if rpm --root=/rootfs -q bash >/dev/null 2>&1; then \
      rpm --root=/rootfs -e --nodeps --noscripts bash; \
    fi; \
    for shell in sh bash dash ash busybox ksh zsh tcsh csh; do \
      rm -f "/rootfs/usr/bin/${shell}" "/rootfs/usr/sbin/${shell}"; \
      if [ -e "/rootfs/usr/bin/${shell}" ] || [ -e "/rootfs/usr/sbin/${shell}" ]; then \
        echo "shell '${shell}' survived in the runtime rootfs" >&2; exit 1; \
      fi; \
    done; \
    test -s /rootfs/var/lib/rpm/rpmdb.sqlite || test -s /rootfs/var/lib/rpm/Packages || \
      { echo "rpm database missing from rootfs; scanners would see zero packages" >&2; exit 1; }

FROM ${UBI_MINIMAL_IMAGE} AS application
ARG BUILDKIT_SBOM_SCAN_STAGE=true
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TARGETARCH
# Paths are relative to the Docker build context and must be allowed by
# .dockerignore. Only the file matching TARGETARCH is copied into the image.
ARG APP_BINARY_AMD64="dist/app-amd64"
ARG APP_BINARY_ARM64="dist/app-arm64"
ARG APP_SHA256_AMD64=""
ARG APP_SHA256_ARM64=""

WORKDIR /work
RUN --mount=type=bind,source=.,target=/context,readonly \
    set -eux; \
    case "${TARGETARCH}" in \
      amd64) app_binary="${APP_BINARY_AMD64}"; expected_sha256="${APP_SHA256_AMD64}" ;; \
      arm64) app_binary="${APP_BINARY_ARM64}"; expected_sha256="${APP_SHA256_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    test -n "${app_binary}" || { echo "APP_BINARY_$(echo "${TARGETARCH}" | tr a-z A-Z) must be set" >&2; exit 1; }; \
    test -n "${expected_sha256}" || { echo "APP_SHA256_$(echo "${TARGETARCH}" | tr a-z A-Z) must be set" >&2; exit 1; }; \
    case "${app_binary}" in \
      /*|../*|*/../*|*/..|..) echo "Application binary path must be relative and stay inside the build context: ${app_binary}" >&2; exit 1 ;; \
    esac; \
    test -f "/context/${app_binary}" || { echo "Application binary not found in build context: ${app_binary}" >&2; exit 1; }; \
    cp "/context/${app_binary}" /work/app; \
    printf '%s  %s\n' "${expected_sha256}" "/work/app" | sha256sum -c -; \
    chmod 0555 /work/app

FROM ${UBI_MICRO_IMAGE} AS runtime

ARG OCI_CREATED
ARG OCI_DESCRIPTION="Red Hat UBI 9 application image"
ARG OCI_REVISION
ARG OCI_SOURCE
ARG OCI_TITLE="ubi9-application"
ARG OCI_VERSION

LABEL org.opencontainers.image.created="${OCI_CREATED}" \
      org.opencontainers.image.description="${OCI_DESCRIPTION}" \
      org.opencontainers.image.revision="${OCI_REVISION}" \
      org.opencontainers.image.source="${OCI_SOURCE}" \
      org.opencontainers.image.title="${OCI_TITLE}" \
      org.opencontainers.image.version="${OCI_VERSION}"

# The assembled rootfs (including /var/lib/rpm for scanners) and the verified
# application binary. ubi-micro ships glibc + the CA bundle at
# /etc/pki/tls/certs/ca-bundle.crt and NO package manager -- but it DOES ship
# bash, and COPY cannot delete a file the base already carries, so the shell is
# removed in the RUN below (the builder stage already dropped bash from the
# overlaid rpmdb, so scanners stay consistent).
COPY --from=rpm-rootfs /rootfs/ /
COPY --from=application /work/app /usr/local/bin/app

# ubi-micro itself carries /usr/bin/bash (+ the /usr/bin/sh symlink). A hardened
# runtime must ship no shell, so delete every shell from the final image and fail
# closed if one survives. This RUN uses the base shell that exists at this point;
# after it returns, none remain.
RUN ["/bin/sh", "-c", "for s in sh bash dash ash busybox ksh zsh tcsh csh; do rm -f \"/usr/bin/$s\" \"/usr/sbin/$s\" \"/bin/$s\" \"/sbin/$s\"; done; for s in sh bash dash ash busybox; do if [ -e \"/usr/bin/$s\" ] || [ -e \"/usr/sbin/$s\" ]; then echo \"shell $s survived in runtime image\" >&2; exit 1; fi; done"]

# Derived image repositories that need a named non-root account (rather than a
# bare numeric UID) synthesize /etc/passwd + /etc/group in the rpm-rootfs stage,
# for example:
#   printf 'nonroot:x:65532:65532:nonroot:/nonexistent:/usr/sbin/nologin\n' >> /rootfs/etc/passwd
#   printf 'nonroot:x:65532:\n' >> /rootfs/etc/group
# (owned 0:0, mode 0644). The template's example app runs as the bare numeric
# UID below, so no passwd entry is required here.
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/app"]
