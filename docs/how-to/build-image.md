# Build A Derived Image

This template ships a working example image. Use these flows directly to see
the contract in action, then replace the example artifact with your own.

## End-To-End From The Template (Example Image)

```sh
make image
```

This runs:

1. `tools/build_app.sh` - builds `dist/app-{amd64,arm64}` inside a
   digest-pinned `golang` container, producing byte-identical binaries across
   machines.
2. `tools/verify_app_shas.py` - checks the built SHA256 values against
   `examples/image-manifest.json`. Drift fails the build and prints both
   expected and actual digests so the manifest update is obvious.
3. `tools/build_image.sh` - renders the docker buildx flags from the manifest
   via `tools/generate_build_args.py`, then runs `docker buildx build` for
   `linux/amd64` and loads the result into the local Docker daemon for testing.
4. `tests/runtime-hardening.sh` - exports the rootfs of the built image and
   asserts no shell, no dnf/microdnf/rpm/yum, no curl or wget, a non-root
   runtime user, and the expected entrypoint.

The local `--load` path is not an evidence path. Docker does not preserve
BuildKit SBOM attestations in the local image store, and the helper disables
BuildKit provenance explicitly. Use
[`publish-image.md`](publish-image.md) when wiring a downstream release job.

## End-To-End For A Real Downstream Repository

After a downstream repository has replaced the example manifest with real pins
and the example app with the real artifact source, the same flow applies:

### Prepare Inputs

1. Pin the `ubi-minimal` builder image by digest in `base.builder`.
2. Pin the `ubi-micro` runtime image by digest in `base.runtime`.
3. Choose the minimum `dnf.packages` the application needs in its runtime
   rootfs. Add `dnf.repos` only if the build must enable specific repository
   IDs exclusively instead of the base image's defaults.
4. Place the per-platform application artifacts under `dist/`, or update
   `.dockerignore` with the minimum build-context paths needed by the
   downstream builder.
5. Verify the application artifacts and record the per-platform paths and
   SHA256 values in the manifest. For vendor release binaries, prefer
   `verification.type` of `checksum-signature` or `sigstore-bundle`; for
   self-built artifacts, `none` is acceptable because the SHA256 in the
   manifest still pins the exact binary the image must contain.

Do not pass secrets through Docker build args. If a future build needs private
fetch credentials, use BuildKit secrets and keep them out of the final image and
provenance-visible build arguments.

### Build From The Manifest

The recommended pattern reads the build args from the manifest rather than
duplicating them:

```sh
# Single-platform build that loads the image into the local Docker daemon.
bash tools/build_image.sh path/to/image-manifest.json my-image:dev linux/amd64
```

To bypass the helper and call docker buildx directly in a release workflow that
needs `--push`, multi-platform output, and BuildKit attestations:

```sh
mapfile -t buildargs < <(python tools/generate_build_args.py path/to/image-manifest.json)

docker buildx build \
  --file containers/Dockerfile \
  --tag ghcr.io/<owner>/<image>:<version> \
  "${buildargs[@]}" \
  --provenance=mode=max \
  --sbom=true \
  --push \
  .
```

`tools/generate_build_args.py` emits one token per line (alternating
`--build-arg` and `KEY=VALUE`) so that `mapfile -t` produces an array suitable
for `"${buildargs[@]}"` expansion without shell-quoting concerns. Use
`--format=json` instead when feeding values into a GitHub Actions matrix.

The Dockerfile selects the matching application artifact path and application
SHA256 based on `TARGETARCH`, and fails fast if the selected architecture's
value is empty or points outside the build context.

## Verify Runtime Hardening

```sh
tests/runtime-hardening.sh <image-ref>
```

The script exports the image filesystem and checks for forbidden runtime tools
without needing the application to start successfully.
