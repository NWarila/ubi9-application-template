# Testing Strategy

The template builds and exercises a working example image so the manifest,
Dockerfile, generator, and runtime hardening assertions are proven together
on every change, not just described in isolation.

## Contract Checks (`python tools/verify.py ci`)

Run on every push and PR; no Docker required. Validates:

- Diataxis and ADR directory layout.
- The starter image manifest in strict mode, plus an in-process check that the
  permissive template mode still accepts `REPLACE_WITH_*` markers for
  downstream consumers.
- Dockerfile contract markers that protect the `dnf --installroot` build pattern
  and the preserved rpm database.
- The build-args generator: every Dockerfile ARG (other than runtime-only
  inputs) has a manifest source, and every generated arg has a matching
  Dockerfile ARG.
- The local image helper uses `--load` for runtime tests and disables
  provenance so it is not mistaken for the release evidence path.
- The example Go builder image is digest-pinned and tracked by Renovate.
- Runtime hardening script coverage for forbidden tools.
- Stale placeholder markers that indicate unfinished template text.
- Local Markdown links, so documentation cannot point at missing release
  guides or other repo files.

## End-To-End Image Build (CI `image-build` job)

Runs on every push and PR; needs Docker. Proves the entire pipeline by:

1. Building `dist/app-{amd64,arm64}` in a digest-pinned `golang` container so
   the binaries are byte-identical to the committed SHA256 values.
2. Running `tools/verify_app_shas.py` to detect drift before the image build
   begins.
3. Generating docker buildx flags from the manifest via
   `tools/generate_build_args.py` (no hand-typed duplication).
4. Building and loading the UBI 9 OCI image for `linux/amd64`.
5. Running `tests/runtime-hardening.sh` and executing the
   image entrypoint to confirm it works.

The CI image build uses Docker's `--load` path so the runtime tests can inspect
the image locally. BuildKit SBOM and provenance attestations are intentionally
kept in the downstream publish flow, where the image is pushed by digest and
the registry can store the attestation manifests.

The example application is deliberately a one-line Go program. Any future
breakage in the base-image pins, the `dnf --installroot` build, the Dockerfile,
or the build helpers surfaces immediately as a CI failure on the template
itself.

## Downstream Additions

A real image repository should layer on:

- Application-specific build and unit tests for the upstream artifact source.
- Push to a registry with digest pinning.
- GitHub artifact attestation upload for the pushed digest and SBOM.
- Cosign or other signing of the image digest.
- Production-grade scanning (Trivy/Grype) as a release gate.

## Non-Goals

The template does not include fake or decorative tests. Every check in CI
exercises a real artifact or contract. Tests that depend on a real registry
destination (push, sign, attest) belong in downstream repositories, not here.
