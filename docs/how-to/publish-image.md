# Publish A Derived Image

Use this pattern in downstream image repositories once the manifest points at
real application inputs and a registry destination exists. Keep the local
`make image` flow for fast runtime checks; use the publish flow for digest
evidence.

## Release Contract

The release job should:

1. Build application artifacts and verify their SHA256 values against the
   reviewed manifest.
2. Build and push the image by digest with BuildKit SBOM and provenance
   enabled. Because the runtime rootfs keeps the rpm database at
   `/var/lib/rpm`, the SBOM and scanners see every installed package.
3. Generate a GitHub artifact attestation for the pushed image digest.
4. Sign the pushed digest with Cosign/Sigstore keyless, using `--recursive`
   so attached SBOM and attestation manifests are signed too.
5. Scan and compliance-check the pushed digest: OpenSCAP against the RHEL 9
   STIG profile, plus Trivy and Grype.
6. Run runtime hardening against the same digest, not a mutable tag.

Docker's local `--load` exporter is not an evidence path. It is useful for
runtime tests, but it does not preserve image attestations in the Docker image
store. Use a registry push for release evidence, or the local/tar exporter when
you are validating SBOM files before a push.

## Workflow Skeleton

Pin every `uses:` value to a reviewed commit SHA before enabling this in a real
repository. The tags below are orientation labels, not pins.

```yaml
name: Publish image

on:
  push:
    tags:
      - "v*"
  workflow_dispatch:

permissions:
  contents: read

env:
  MANIFEST: examples/image-manifest.json
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  publish:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      id-token: write
      packages: write
      attestations: write
      artifact-metadata: write
    steps:
      - name: Checkout
        uses: actions/checkout@<40-char-sha> # v6.0.2
        with:
          fetch-depth: 1
          persist-credentials: false

      - name: Set up Python
        uses: actions/setup-python@<40-char-sha> # v6.2.0
        with:
          python-version: "3.12"

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@<40-char-sha> # v3.11.1

      - name: Install Cosign
        uses: sigstore/cosign-installer@<40-char-sha>

      - name: Login to registry
        run: |
          printf '%s' "${{ secrets.GITHUB_TOKEN }}" \
            | docker login "${REGISTRY}" \
                --username "${{ github.actor }}" \
                --password-stdin

      - name: Build application artifacts
        run: bash tools/build_app.sh

      - name: Verify application artifact SHAs
        run: python tools/verify_app_shas.py "${MANIFEST}"

      - name: Generate build arguments
        run: python tools/generate_build_args.py "${MANIFEST}" > dist/buildargs.txt

      - name: Build and push image
        id: image
        run: |
          mapfile -t buildargs < dist/buildargs.txt
          image="${REGISTRY}/${IMAGE_NAME}"
          docker buildx build \
            --file containers/Dockerfile \
            --tag "${image}:${GITHUB_SHA}" \
            --tag "${image}:${GITHUB_REF_NAME}" \
            --provenance=mode=max \
            --sbom=true \
            --metadata-file dist/image-metadata.json \
            --push \
            "${buildargs[@]}" \
            .
          digest="$(python -c 'import json; print(json.load(open("dist/image-metadata.json"))["containerimage.digest"])')"
          {
            printf 'image=%s\n' "${image}"
            printf 'digest=%s\n' "${digest}"
            printf 'ref=%s@%s\n' "${image}" "${digest}"
          } >> "${GITHUB_OUTPUT}"

      - name: Generate GitHub artifact attestation
        uses: actions/attest@<40-char-sha> # v4
        with:
          subject-name: ${{ steps.image.outputs.image }}
          subject-digest: ${{ steps.image.outputs.digest }}
          push-to-registry: true

      - name: Sign image digest
        env:
          COSIGN_YES: "true"
        run: cosign sign --recursive "${{ steps.image.outputs.ref }}"

      - name: Scan and compliance-check published image
        run: |
          # OpenSCAP RHEL 9 STIG profile, plus Trivy and Grype, against the
          # pushed digest. Fail the release on findings above the agreed
          # severity bar.
          trivy image --severity HIGH,CRITICAL --exit-code 1 "${{ steps.image.outputs.ref }}"
          grype "${{ steps.image.outputs.ref }}" --fail-on high

      - name: Test published image hardening
        run: bash tests/runtime-hardening.sh "${{ steps.image.outputs.ref }}"
```

## Review Rules

- Do not pass secrets as Docker build args. BuildKit max provenance can expose
  build argument values.
- Attest and sign `image@sha256:...`, not a mutable tag.
- Keep registry credentials in GitHub Actions secrets or OIDC-backed registry
  auth, not in the manifest.
- For vendor release binaries, verify upstream checksum signatures or Sigstore
  bundles before writing the artifact SHA256 into the manifest.
- If you need an SBOM file before pushing, build with
  `docker buildx build --sbom=true --output type=local,dest=dist/evidence .`
  and inspect `dist/evidence/sbom.spdx.json`.

## Verification

After the workflow publishes an image, verify the evidence from a clean
checkout:

```sh
gh attestation verify oci://ghcr.io/OWNER/IMAGE:TAG -R OWNER/REPO
cosign verify ghcr.io/OWNER/IMAGE@sha256:DIGEST \
  --certificate-identity-regexp 'https://github.com/OWNER/REPO/.github/workflows/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```
