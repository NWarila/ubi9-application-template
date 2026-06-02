# Supply Chain Evidence

Downstream image repositories should publish evidence for the image digest, not
only for mutable tags. See [`docs/how-to/publish-image.md`](../how-to/publish-image.md)
for a drop-in workflow that produces every required evidence type below.

## Required Evidence

| Evidence | Expected Mechanism |
| --- | --- |
| SBOM | Docker BuildKit SBOM attestation, created with `--sbom=true` or `--attest type=sbom`. The preserved rpm database at `/var/lib/rpm` lets the scanner enumerate installed packages. |
| Provenance | Docker BuildKit provenance attestation, preferably `--provenance=mode=max`. |
| Artifact attestation | GitHub `actions/attest` for the pushed image digest. BuildKit carries the SBOM attestation. |
| Signature | Cosign/Sigstore keyless signature over the image digest, signed with `cosign sign --recursive` so attached SBOM and attestation manifests are covered. |
| Compliance and scan | OpenSCAP against the RHEL 9 STIG profile, plus Trivy and Grype vulnerability scans of the pushed digest. |
| Runtime hardening | Output from `tests/runtime-hardening.sh <image-ref>`. |

## Anchors

- Red Hat Universal Base Images (UBI), including `ubi-minimal` and `ubi-micro`,
  are the freely redistributable RHEL-derived base images:
  <https://catalog.redhat.com/software/base-images>
- `dnf` installs packages into an alternate root with `--installroot`, which is
  how the runtime rootfs is assembled while keeping the rpm database:
  <https://dnf.readthedocs.io/en/latest/command_ref.html>
- OpenSCAP evaluates images against SCAP content such as the RHEL 9 STIG
  profile:
  <https://www.open-scap.org/>
- Docker BuildKit creates provenance and SBOM attestations with `--provenance`
  and `--sbom`:
  <https://docs.docker.com/build/metadata/attestations/>
- Docker documents SBOM attestation generation and local validation:
  <https://docs.docker.com/build/metadata/attestations/sbom/>
- GitHub artifact attestations can establish provenance for binaries and
  container images:
  <https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations>
- Sigstore Cosign signs and verifies container images:
  <https://docs.sigstore.dev/quickstart/quickstart-cosign/>
- SLSA Build levels describe increasing provenance guarantees:
  <https://slsa.dev/spec/v1.0/levels>
- NIST SP 800-190 is the application container security guide:
  <https://csrc.nist.gov/pubs/sp/800/190/final>

## Review Notes

Docker's local `--load` exporter is for runtime testing only. It does not
preserve SBOM or provenance attestations in the local image store. Publish
jobs should use `--push` for registry-backed evidence, or a local/tar exporter
only when validating attestation JSON before publishing.

Build args are visible in provenance. Do not put secrets in build args. If a
derived image needs private fetch credentials, use BuildKit secrets and document
why the secret is needed in the downstream repository.
