# Publish A Derived Image

Use this pattern in downstream image repositories once the manifest points at
real application inputs and a registry destination exists. Keep the local
`make image` flow for fast runtime checks; use the publish flow for digest
evidence.

## Release Contract

The release job should:

1. Verify the audited SLSA generator tag still resolves to the reviewed commit.
2. Build application artifacts and verify their SHA256 values against the
   reviewed manifest.
3. Build and push the image by digest with BuildKit SBOM and provenance
   enabled. Because the runtime rootfs keeps the rpm database at
   `/var/lib/rpm`, the SBOM and scanners see every installed package.
4. Sign the pushed digest with Cosign/Sigstore keyless, using `--recursive`
   so attached SBOM and attestation manifests are signed too.
5. Scan and compliance-check the pushed digest: OpenSCAP against the RHEL 9
   STIG profile, plus Trivy and Grype.
6. Run runtime hardening against the same digest, not a mutable tag.
7. Call the SLSA container generator with the image name and digest so it writes
   a cosign OCI provenance attestation from the trusted reusable workflow.

Docker's local `--load` exporter is not an evidence path. It is useful for
runtime tests, but it does not preserve image attestations in the Docker image
store. Use a registry push for release evidence, or the local/tar exporter when
you are validating SBOM files before a push.

## Workflow Skeleton

Pin every ordinary `uses:` value to a reviewed commit SHA before enabling this
in a real repository. The SLSA generator reusable is the exception: keep it on
the semantic-version tag shown below and keep the tag-integrity guard beside it.
The version comments on SHA-pinned actions are orientation labels, not pins.

```yaml
name: Publish image

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
    tags:
      - "v*"

permissions:
  contents: read

env:
  MANIFEST: examples/image-manifest.json
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
  SLSA_GENERATOR_TAG: "v2.1.0"
  SLSA_GENERATOR_TAG_SHA: "f7dd8c54c2067bafc12ca7a55595d5ee9b75204a"

jobs:
  slsa-generator-tag-integrity:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - name: Verify SLSA generator tag binding
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          actual="$(gh api "repos/slsa-framework/slsa-github-generator/git/ref/tags/${SLSA_GENERATOR_TAG}" --jq '.object.sha')"
          if [[ "${actual}" != "${SLSA_GENERATOR_TAG_SHA}" ]]; then
            printf 'SLSA generator tag drift: expected %s, got %s\n' "${SLSA_GENERATOR_TAG_SHA}" "${actual}" >&2
            exit 1
          fi

  publish:
    needs: slsa-generator-tag-integrity
    if: ${{ github.event_name == 'push' && (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v')) }}
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
      id-token: write
      packages: write
    outputs:
      image: ${{ steps.image.outputs.image }}
      digest: ${{ steps.image.outputs.digest }}
      ref: ${{ steps.image.outputs.ref }}
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

      - name: Sign image digest
        env:
          COSIGN_YES: "true"
        run: cosign sign --recursive "${{ steps.image.outputs.ref }}"

      - name: Verify image signature
        env:
          CERTIFICATE_IDENTITY: https://github.com/${{ github.repository }}/.github/workflows/publish-image.yaml@${{ github.ref }}
        run: |
          cosign verify "${{ steps.image.outputs.ref }}" \
            --certificate-identity "${CERTIFICATE_IDENTITY}" \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com

      - name: Scan and compliance-check published image
        run: |
          # OpenSCAP RHEL 9 STIG profile, plus Trivy and Grype, against the
          # pushed digest. Fail the release on findings above the agreed
          # severity bar.
          trivy image --severity HIGH,CRITICAL --exit-code 1 "${{ steps.image.outputs.ref }}"
          grype "${{ steps.image.outputs.ref }}" --fail-on high

      - name: Test published image hardening
        run: bash tests/runtime-hardening.sh "${{ steps.image.outputs.ref }}"

  slsa-provenance:
    needs: publish
    permissions:
      actions: read
      contents: read
      id-token: write
      packages: write
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.1.0
    with:
      image: ${{ needs.publish.outputs.image }}
      digest: ${{ needs.publish.outputs.digest }}
      registry-username: ${{ github.actor }}
    secrets:
      registry-password: ${{ secrets.GITHUB_TOKEN }}
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
checkout with the exact SLSA generator identity. The reference contract is
kept in [`../reference/slsa-l3-provenance.md`](../reference/slsa-l3-provenance.md).

```sh
cosign verify-attestation --type slsaprovenance <image>@<digest> \
  --certificate-identity https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.1.0 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

```sh
slsa-verifier verify-image <image>@<digest> \
  --source-uri github.com/NWarila/ubi9-application-template \
  --builder-id https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.1.0
```
