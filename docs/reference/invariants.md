# Invariants

The following invariants should remain true for this template and its derived
application image repositories.

| Invariant | Why It Matters |
| --- | --- |
| The final image uses `FROM ubi-micro`. | Runtime contents are a minimal Red Hat UBI 9 base plus explicit copies, not a broad general-purpose image. |
| Both the `ubi-minimal` builder and the `ubi-micro` runtime images are pinned by digest. | Builds do not silently follow mutable tags. |
| The runtime rootfs is assembled with `dnf --installroot` from the manifest's `dnf.packages`. | Installed contents are an explicit, reviewable package list. |
| The rpm database is preserved at `/var/lib/rpm`. | Trivy, Grype, and OpenSCAP can enumerate installed packages; deleting it would yield a false "0 CVE" result. |
| The CA bundle lives at `/etc/pki/tls/certs/ca-bundle.crt`. | TLS-using applications find trusted roots at the standard RHEL path. |
| Application artifacts are selected per target architecture and verified before copy. | The final image is not assembled from the wrong platform or unchecked binaries. |
| Runtime user is non-root. | Default execution does not grant root inside the container. |
| Runtime image has no shell and no dnf, microdnf, rpm, yum, curl, or wget. | Post-compromise download and package-install paths are reduced. |
| SBOM, provenance, signature, and attestation evidence are published by digest. | Consumers can verify what was built and how. |
