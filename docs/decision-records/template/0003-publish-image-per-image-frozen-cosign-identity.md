# ADR-0003: Publish-Image Workflow as a Per-Image Frozen Cosign Identity

| Field          | Value                                    |
| -------------- | ---------------------------------------- |
| Status         | Accepted                                 |
| Date           | 2026-06-02                               |
| Authors        | Nick Warila (@NWarila)                   |
| Decision-maker | Nick Warila (sole portfolio maintainer)  |
| Consulted      | None.                                    |
| Informed       | None.                                    |
| Reversibility  | Medium                                   |
| Review-by      | N/A (Accepted)                           |

## TL;DR

Each image repository keeps its own **frozen copy** of `publish-image.yaml`
rather than calling an org-level reusable publish workflow. The reason is the
cosign keyless certificate identity: with a per-repo workflow file, the signer
Subject Alternative Name is
`https://github.com/<repo>/.github/workflows/publish-image.yaml@refs/...`,
scoped to that repository. The existing Kyverno org-wildcard admission policy
verifies exactly that SAN shape, so the per-repo frozen copy keeps every cluster
admission policy working unchanged. Signing uses cosign keyless
(`--certificate-identity` against the workflow SAN, OIDC issuer
`https://token.actions.githubusercontent.com`) with `--recursive`, so the
multi-arch image index **and** each per-arch child manifest are signed. The
rejected alternative — promoting `publish-image.yaml` to an org reusable — would
collapse all images onto a single signer identity and force a rewrite of every
admission policy.

## Context and Problem Statement

Cosign keyless signing binds a signature to a Fulcio-issued short-lived
certificate whose identity is the GitHub Actions OIDC token's
`job_workflow_ref`. For a workflow file that lives in the repository being
built, that identity (the certificate's Subject Alternative Name) is:

```
https://github.com/NWarila/<repo>/.github/workflows/publish-image.yaml@refs/heads/main
```

The SAN therefore encodes **which workflow file in which repository** produced
the signature. Verification on the consuming side (cosign `verify`, and the
Kyverno admission policy in the cluster) pins against this SAN.

The org runs a single Kyverno policy with an **org-wildcard** identity matcher of
the shape `https://github.com/NWarila/*/.github/workflows/publish-image.yaml@*`.
That one policy admits any image in the org as long as it was signed by *that
repository's own* `publish-image.yaml`. This is deliberate: it is one policy that
scales across every image repo without per-repo policy maintenance.

The tension arises when considering DRY. The natural instinct is to lift the
publish logic into an org reusable workflow (under `NWarila/.github`) and have
each image repo `uses:` it. But a reusable workflow's `job_workflow_ref` — and
therefore the cosign SAN — points at the **reusable's** path, not the caller's.
Every image, regardless of repo, would then sign with the **same** identity:

```
https://github.com/NWarila/.github/.github/workflows/publish-image.yaml@<ref>
```

That single shared identity breaks the org-wildcard model: the wildcard segment
(`NWarila/*/...`) no longer distinguishes images by origin repo, and the policy
would have to be rewritten to match the reusable's fixed path — losing the
per-repo provenance that the wildcard was buying.

A second concern is multi-arch. The image is a multi-arch OCI **index** that
references per-arch child manifests. Signing only the index leaves the child
manifests unsigned, so a consumer that pulls a specific architecture digest is
verifying nothing. The signing step must cover the index and its children.

The problem statement: keep the publish/sign workflow maintainable **without**
collapsing the per-repo cosign identity that the org-wildcard Kyverno policy
depends on, and ensure every manifest in the multi-arch image is signed.

## Decision Drivers

1. **Stable, per-repo cosign identity.** The signer SAN must stay
   `.../<repo>/.github/workflows/publish-image.yaml@refs/...` so it identifies
   the origin repository.
2. **Unchanged admission policy.** The existing Kyverno **org-wildcard** policy
   must keep working with no rewrite as new image repos are derived.
3. **Full multi-arch coverage.** Both the OCI index and every per-arch child
   manifest must be signed.
4. **Keyless, no long-lived keys.** Signing must be keyless via GitHub OIDC and
   Fulcio; no private signing key to store or rotate.
5. **Derivability.** A newly derived image repo must inherit a working publish +
   sign path with no per-repo policy work in the cluster.
6. **Maintainability honesty.** The cost of frozen per-repo copies (drift across
   repos) must be acknowledged and managed, not pretended away.

## Considered Options

1. **Per-image frozen copy of `publish-image.yaml` in each repo**, cosign
   keyless `--recursive`, verified by the org-wildcard Kyverno policy. (Chosen.)
2. **Org reusable `publish-image.yaml`** under `NWarila/.github`, called by every
   image repo via `uses:`.
3. **Per-image copy but sign only the multi-arch index** (drop `--recursive`).
4. **Keyed cosign** with an org-managed private key instead of keyless OIDC.

## Decision Outcome

Chosen option: **Option 1, a per-image frozen copy of `publish-image.yaml`.**

Every image repository carries its own `publish-image.yaml` as a frozen copy
(not a `uses:` call to an org reusable). As a consequence:

- The cosign keyless certificate identity is
  `https://github.com/<repo>/.github/workflows/publish-image.yaml@refs/...`,
  scoped to the origin repository.
- The org's single **org-wildcard** Kyverno policy (matching
  `https://github.com/NWarila/*/.github/workflows/publish-image.yaml@*` with
  issuer `https://token.actions.githubusercontent.com`) continues to admit every
  image with no policy rewrite. Deriving a new image repo automatically falls
  under the wildcard.
- Signing is **cosign keyless with `--recursive`**: the multi-arch OCI index is
  signed, and so is each per-arch child manifest it references. A consumer
  verifying any architecture-specific digest gets a real signature to check.
- Verification (in CI and at admission) pins `--certificate-identity` to the
  workflow SAN and `--certificate-oidc-issuer` to
  `https://token.actions.githubusercontent.com`.

The publish and verification mechanics are documented in
[how-to/publish-image.md](../../how-to/publish-image.md) and
[reference/supply-chain-evidence.md](../../reference/supply-chain-evidence.md);
the mirroring posture for the org-wildcard policy is covered in
[reference/mirroring.md](../../reference/mirroring.md).

**Rejected alternative, recorded explicitly.** Promoting `publish-image.yaml` to
an org reusable workflow would give DRY (one file to maintain) but would collapse
every image onto the **single** signer identity of the reusable's own path. That
defeats the per-repo SAN the org-wildcard policy relies on and would force a
rewrite of the admission policy (and a loss of per-repo provenance). One
maintained file is not worth rewriting every admission policy and discarding
origin-repo attribution; the frozen per-repo copy is accepted instead.

## Pros and Cons of the Options

### Option 1: Per-image frozen copy, `--recursive` (chosen)

- **Good, because** the cosign SAN stays per-repo, so signatures identify the
  origin repository.
- **Good, because** the existing org-wildcard Kyverno policy keeps working
  unchanged; new derived repos fall under the wildcard automatically.
- **Good, because** `--recursive` signs the index and every per-arch child
  manifest, so per-architecture pulls are verifiable.
- **Good, because** keyless OIDC signing means no private key to store or rotate.
- **Bad, because** the workflow file is duplicated across image repos, so a fix
  must be propagated to each copy (drift risk).
- **Neutral, because** propagation can be templated/automated, turning drift into
  a managed, mechanical update rather than a design flaw.

### Option 2: Org reusable publish workflow

- **Good, because** there is exactly one publish workflow file to maintain.
- **Bad, because** every image signs with the reusable's single identity; the
  per-repo SAN is lost.
- **Bad, because** the org-wildcard Kyverno policy no longer distinguishes images
  by origin and must be rewritten to the reusable's fixed path.
- **Bad, because** origin-repo provenance in the signature is discarded.

### Option 3: Per-image copy but index-only signing

- **Good, because** it is marginally simpler than `--recursive`.
- **Bad, because** per-arch child manifests are left unsigned; a consumer pulling
  a specific architecture digest verifies nothing.
- **Bad, because** it creates a false sense of "the image is signed" while part
  of it is not.

### Option 4: Keyed cosign with an org-managed key

- **Good, because** verification does not depend on Fulcio/OIDC availability.
- **Bad, because** it reintroduces a long-lived private key to store, protect,
  and rotate — the exact problem keyless signing removes.
- **Bad, because** it abandons the workflow-identity provenance that the SAN and
  the org-wildcard policy are built around.

## Confirmation

Adherence is confirmed by the following. `MUST`, `SHOULD`, and `MAY` follow
[RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) conventions.

1. **Frozen per-repo workflow.** Each image repo MUST contain its own
   `publish-image.yaml` and MUST NOT replace it with a `uses:` call to an org
   reusable publish workflow.
2. **Per-repo SAN.** The cosign certificate identity MUST resolve to
   `https://github.com/<repo>/.github/workflows/publish-image.yaml@refs/...`.
3. **Recursive signing.** Signing MUST use cosign `--recursive` so the index and
   every per-arch child manifest are signed; a CI verification step SHOULD
   confirm a child-manifest signature, not only the index.
4. **Keyless issuer.** Signing and verification MUST use OIDC issuer
   `https://token.actions.githubusercontent.com`; no long-lived key is used.
5. **Org-wildcard compatibility.** The signer SAN MUST match the org-wildcard
   Kyverno matcher `https://github.com/NWarila/*/.github/workflows/publish-image.yaml@*`
   without requiring a policy edit.

## Consequences

### Positive

- Per-repo cosign identity is preserved; signatures attribute to the origin repo.
- The single org-wildcard admission policy keeps working as repos are derived.
- The entire multi-arch image (index plus children) is signed and verifiable.
- No private signing key exists to be lost or rotated.

### Negative

- `publish-image.yaml` is duplicated across image repos; fixes must be propagated
  to each frozen copy.
- A botched propagation can leave repos on divergent publish logic until
  reconciled.

### Neutral

- Propagation is mechanical and templatable, so the duplication is a managed cost
  rather than an open-ended maintenance hole.
- The decision couples the repo to GitHub OIDC and Fulcio for the signing path;
  this is consistent with the rest of the org's keyless posture.

## Assumptions

If any of these becomes false, this ADR should be revisited:

1. GitHub Actions continues to issue OIDC tokens whose `job_workflow_ref` (and
   thus the cosign SAN) reflects the **caller's** workflow file for a per-repo
   workflow, and the reusable's path for a `uses:` reusable.
2. The org keeps a single org-wildcard Kyverno policy of the documented SAN shape
   rather than per-repo admission policies.
3. Cosign `--recursive` continues to sign multi-arch index children, and
   keyless verification against the GitHub OIDC issuer remains available.
4. The maintenance cost of propagating frozen-copy changes stays low enough
   (via templating) that DRY's pull does not outweigh the identity benefit.

## Supersedes

None.

## Superseded by

None (current).

## Implementing PRs

Pending. The implementing PRs land the frozen `publish-image.yaml` in the image
repo with cosign keyless `--recursive` signing pinned to the per-repo SAN and the
GitHub OIDC issuer, add a CI verification step that checks a per-arch child
manifest signature, and document the publish/verify path and org-wildcard
compatibility in [how-to/publish-image.md](../../how-to/publish-image.md),
[reference/supply-chain-evidence.md](../../reference/supply-chain-evidence.md),
and [reference/mirroring.md](../../reference/mirroring.md).

## Related ADRs

- [ADR-0001](0001-replace-chisel-with-ubi9.md) — produces the multi-arch UBI 9
  image that this workflow signs and publishes.
- [ADR-0002](0002-compliance-gate-openscap-rhel9-stig.md) — the compliance
  evidence attached to the signed, published image.
- [org ADR-0007](../org/0007-centralize-universal-ci-reusables-within-each-namespace.md)
  — the org reusable-workflow policy; this ADR records the deliberate exception
  for `publish-image.yaml` driven by the cosign-identity constraint.
- [org ADR-0001](../org/0001-use-architecture-decision-records.md) — establishes
  the ADR format and scope structure.

## Compliance Notes

A per-repo frozen workflow with keyless `--recursive` signing strengthens
software-release integrity and provenance.

| Framework              | Control / Practice ID                                               | Potential Evidence Contribution                                                                                       |
| ---------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| NIST SP 800-53 Rev. 5  | SI-7 (Software, Firmware, and Information Integrity)                | Cosign signatures over the index and child manifests let consumers verify image integrity before use.                 |
| NIST SP 800-53 Rev. 5  | CM-5 (Access Restrictions for Change)                              | The per-repo workflow SAN ties published images to a specific, attributable change pipeline.                          |
| NIST SP 800-218 (SSDF) | PS.2 (Provide a Mechanism for Verifying Software Release Integrity) | Keyless cosign signatures verifiable at admission provide the release-integrity verification mechanism.               |
| NIST SP 800-218 (SSDF) | PO.5 (Implement and Maintain Secure Environments)                 | Keyless OIDC signing removes long-lived signing keys from the build environment, reducing key-management exposure.    |
