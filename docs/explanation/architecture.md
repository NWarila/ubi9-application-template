# Architecture

`ubi9-application-template` is the reference template for one-application
Red Hat UBI 9 image repositories. It owns the reusable contract and ships a
working example image so the contract is exercised end-to-end on every change.

## Template Boundary

The template owns:

- A manifest shape (schema v2) that records the base images, the `dnf` packages
  installed into the runtime rootfs, the application artifacts, runtime policy,
  and required evidence.
- A manifest-to-build-args generator so the manifest is the single review
  surface for buildx invocations.
- A Dockerfile pattern that assembles a runtime root filesystem with
  `dnf --installroot` in a `ubi-minimal` builder stage and starts the final
  image `FROM ubi-micro`.
- A deliberately useless example Go application under `app/`, built
  deterministically inside a pinned `golang` container, that proves the full
  pipeline works on every CI run.
- Runtime hardening assertions that the example image and downstream images
  must pass.
- Documentation for expected SBOM, provenance, signature, and attestation
  evidence.
- A CI workflow that builds the example image and runs the hardening checks
  against it on every push and pull request.

It does not own:

- A shared mutable base image.
- Application-specific upstream verification rules.
- Registry publication, promotion, or environment approval policy.
- Cosign signing and GitHub artifact attestation upload (those bind to a
  publish destination the template does not own).

## Build Flow

The expected downstream build has three layers:

1. **Input review.** The image manifest records the `ubi-minimal` builder and
   `ubi-micro` runtime digests, the `dnf.packages` list (and optional
   `dnf.repos`), the application artifact checksums, runtime policy, and
   required evidence.
2. **Root filesystem construction.** The `ubi-minimal` builder stage runs
   `dnf install --installroot=/rootfs` for the manifest's packages, prunes only
   the regenerable dnf cache and logs, and verifies that the rpm database under
   `/rootfs/var/lib/rpm` survives so scanners can enumerate installed packages.
3. **Runtime assembly.** The final image starts `FROM ubi-micro`, copies the
   assembled rootfs and the verified application binary, runs as `65532:65532`,
   and exposes only the application entrypoint. `ubi-micro` ships glibc and the
   CA bundle at `/etc/pki/tls/certs/ca-bundle.crt` but no shell and no package
   manager.

## External Dependencies

- Red Hat UBI 9 base images (`ubi-minimal` builder, `ubi-micro` runtime) and the
  RHEL 9 dnf repositories they ship.
- Docker BuildKit and Buildx for SBOM and provenance attestations.
- GitHub Actions for CI and artifact attestations in downstream repositories.
- Sigstore Cosign for image signatures.
