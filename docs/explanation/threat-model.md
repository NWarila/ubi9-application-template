# Threat Model

This template focuses on supply-chain and runtime-surface risks for custom
application images.

## Primary Risks

| Risk | Template Response |
| --- | --- |
| Mutable base image drift | Require downstream repos to pin both the `ubi-minimal` builder and the `ubi-micro` runtime images by digest and build the runtime rootfs themselves. |
| Unreviewed runtime contents | Require an explicit `dnf.packages` list in the manifest; the `dnf --installroot` step installs only those packages with weak deps disabled. |
| Scanners blind to image contents | Preserve the rpm database at `/var/lib/rpm` so Trivy, Grype, and OpenSCAP enumerate the installed packages instead of reporting an empty image. |
| Tampered application artifact | Require per-platform application checksums and a verification mode. |
| Excess runtime tooling | Assert no shell and no dnf, microdnf, rpm, yum, curl, or wget in the final image. |
| Root runtime | Require a non-root runtime user. |
| Missing release evidence | Document SBOM, provenance, GitHub attestation, Cosign signature, and compliance/scan (OpenSCAP RHEL 9 STIG, Trivy, Grype) expectations. |

## Out Of Scope

- Registry compromise response.
- Admission-controller policy.
- Application-level vulnerability management.
- Runtime sandbox configuration in Kubernetes or another orchestrator.
- Secrets handling inside applications.

Those belong in downstream image repos or deployment platforms.
