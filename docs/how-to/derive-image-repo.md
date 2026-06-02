# Derive An Image Repository

Use this flow when creating a real application image repository from
`NWarila/ubi9-application-template`.

## Create The Repository

Create the new repository from the template, then work in a branch:

```sh
gh repo create OWNER/IMAGE_REPO \
  --template NWarila/ubi9-application-template \
  --public \
  --clone
```

The GitHub UI path is also fine: choose **Use this template** on
`NWarila/ubi9-application-template`, create the downstream repository, and
then clone it locally.

## First Downstream Edit

Keep the generated repository working while replacing the example:

1. Rename `image.name` in `examples/image-manifest.json` to the real image
   name.
2. Replace `app/` with the real application source, or replace
   `tools/build_app.sh` with the smallest builder needed to produce the
   application artifacts under `dist/`.
3. Update `application.artifacts[*].path` and
   `application.artifacts[*].sha256` after building the real artifacts.
4. Keep `containers/Dockerfile` focused on the `dnf --installroot` rootfs build
   and the final runtime assembly. If the application needs a different
   entrypoint, change `application.binary_path`, `runtime.entrypoint`, and the
   Dockerfile entrypoint together.
5. Update `.github/CODEOWNERS` to a user or team that exists and has write
   access to the downstream repository. Do not use an organization login as a
   CODEOWNERS owner.
6. Update `README.md` and repository-specific docs under
   `docs/decision-records/repo/`.

Run the local contract checks before opening the first pull request:

```sh
python tools/verify.py ci
make image
```

`python tools/verify.py ci` does not need Docker. `make image` needs Docker
Buildx and proves the application artifact, manifest, Dockerfile, and runtime
hardening script together.

## CI Shape

The generated repository already has a build caller. `.github/workflows/ci.yaml`
calls the local `.github/workflows/reusable-ubi-image-build.yaml`, so a new
repository does not need a separate `.github/workflows/image.yaml` to build and
test an image.

Keep the local reusable when the downstream repository is expected to own its
application build details. If a repository should be a thin consumer of the
upstream template workflow instead, replace the local call with a pinned
cross-repository call after review:

```yaml
jobs:
  image-build:
    name: image build + hardening
    permissions:
      contents: read
    uses: NWarila/ubi9-application-template/.github/workflows/reusable-ubi-image-build.yaml@0123456789abcdef0123456789abcdef01234567
    with:
      manifest_path: examples/image-manifest.json
      image_tag: my-image:ci
      platform: linux/amd64
      run_smoke_test: true
```

Use a real reviewed commit SHA in the `uses:` line. Do not pin to a branch or
tag.

## Publish Path

The template CI builds with Docker's local `--load` path so runtime tests can
inspect the image. That is not a release-evidence path. Add a publish workflow
only after the registry destination is known, following
[`publish-image.md`](publish-image.md).

The publish workflow should push an image by digest, emit BuildKit SBOM and
provenance attestations, create a GitHub artifact attestation for the digest,
sign the digest, and run runtime hardening against the pushed digest.

## Governance Setup

Configure the repository settings before enabling auto-merge:

1. Create or inherit the rulesets described in
   [`../reference/governance.md`](../reference/governance.md).
2. Require the CI, security, and review gates that are expected to block
   merges.
3. Enable secret scanning, push protection, Dependabot alerts, squash merge,
   delete branch on merge, and auto-merge if those are part of the owning
   organization's baseline.

Use this template repository as the source of truth for the scaffold. Do not
use a partially initialized downstream repository as the canonical example
until it has been backfilled from this shape and has a green first pull
request.
