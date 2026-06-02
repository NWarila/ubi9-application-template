# Image Manifest Contract

The image manifest is the review surface for downstream image repositories. The
working example is [`examples/image-manifest.json`](../../examples/image-manifest.json)
and the schema is [`contracts/image-manifest.schema.json`](../../contracts/image-manifest.schema.json).
The example ships with real pinned upstream values so the template builds an
end-to-end image without any further edits.

## Required Sections

The manifest is schema v2 (`schema_version` is `"2.0"`).

| Section | Purpose |
| --- | --- |
| `image` | Image name, RHEL version (`9`), and supported platforms. |
| `base.builder` | Digest-pinned `ubi-minimal` builder image. |
| `base.runtime` | Digest-pinned `ubi-micro` runtime image. |
| `dnf.packages` | Exact package list installed into the runtime rootfs via `dnf --installroot`. |
| `dnf.repos` | Optional repository IDs to enable exclusively (default: the base image's repositories). |
| `application` | Application artifact source, final binary path, build-context artifact paths, checksums, and verification mode. |
| `runtime` | Non-root user, entrypoint, and forbidden executable baseline. |
| `evidence` | Required release evidence types. |

`base.builder` and `base.runtime` must both be `@sha256`-pinned references; the
builder is `ubi-minimal` (it carries `dnf`) and the runtime is `ubi-micro` (no
shell, no package manager).

`application.artifacts[]` is keyed by platform and records the reviewed
build-context path plus the expected SHA256 for that platform's binary. Paths
must be relative, use `/` separators, and stay inside the Docker build context.
The template `.dockerignore` allows `dist/**` by default; downstream repositories
that build from source should add only the minimum additional source paths their
builder stage needs.

## Manifest Modes

| Mode | Use When | How |
| --- | --- | --- |
| Strict | Production. The manifest must contain only real pins. | `python tools/check_image_manifest.py path/to/image-manifest.json` |
| Template | Downstream repository in the middle of replacing template pins. Allows `REPLACE_WITH_*` markers to pass validation. | `python tools/check_image_manifest.py --template path/to/image-manifest.json` |

The committed `examples/image-manifest.json` validates in strict mode. The
template-mode acceptance is regression-tested in `tools/verify.py` against an
in-memory manifest containing a `REPLACE_WITH_*` marker.

## From Manifest To docker buildx

`python tools/generate_build_args.py <manifest>` emits the docker buildx flags
derived from the manifest. The default `docker-buildx` format pairs each flag
with its value on adjacent lines for `mapfile -t` consumption; the alternate
`json` format produces a structured object useful in GitHub Actions matrices.
See [`docs/how-to/build-image.md`](../how-to/build-image.md) for the recommended
invocation pattern.

## Verification Modes

| Mode | Use When |
| --- | --- |
| `checksum` | The upstream artifact has a trusted checksum source. |
| `checksum-signature` | The upstream publishes signed checksums. |
| `pgp-signature` | The upstream publishes detached PGP signatures. |
| `sigstore-bundle` | The upstream publishes Sigstore bundle evidence. |
| `none` | Only for internally built artifacts whose SHA256 in the manifest is the contract. |

Prefer signed checksums or Sigstore bundles for vendor release binaries. The
example uses `none` because the application is self-built; the per-platform
SHA256 entries still pin the exact binary the image must contain.
