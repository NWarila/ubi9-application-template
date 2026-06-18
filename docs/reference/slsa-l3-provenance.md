# SLSA L3 Provenance Verification

Published images use the SLSA container generator reusable workflow to write a
cosign OCI attestation for the pushed image digest. The caller workflow builds
and pushes the image, captures the digest, and passes the image name plus digest
to the trusted generator.

## Trusted Generator

| Field | Value |
| --- | --- |
| Generator workflow | `slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml` |
| Generator tag | `v2.1.0` |
| Audited tag target | `f7dd8c54c2067bafc12ca7a55595d5ee9b75204a` |
| Certificate identity / builder ID | `https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.1.0` |
| OIDC issuer | `https://token.actions.githubusercontent.com` |

The workflow reference is tag-pinned because the upstream generator resolves its
builder binary from a semantic-version tag. The publish workflow therefore runs
a tag-integrity guard on pull requests and publish pushes, and fails if
`refs/tags/v2.1.0` no longer resolves to the audited commit above.

## Verify Contract

Run both commands against the digest reference that was published:

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

`gh attestation verify` is intentionally excluded: it verifies GitHub-native
Artifact Attestations, not the cosign OCI attestation written by this SLSA
generator.
