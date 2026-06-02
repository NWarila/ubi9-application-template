# Architecture Decision Records

This directory holds the Architecture Decision Records (ADRs) governing this
template. Per [org ADR-0001](org/0001-use-architecture-decision-records.md),
ADRs are organized into three scopes:

- `org/` - org-baseline ADR mirrors from `NWarila/.github`;
  `.github/workflows/org-adr-sync.yaml` enforces byte identity.
- `template/` - decisions owned by this UBI 9 application image template.
- `repo/` - repository-specific ADRs for this repository only.

## Template ADRs

The `template/` scope records the decisions that define this template's UBI 9
image shape.

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-0001](template/0001-replace-chisel-with-ubi9.md) | Accepted | Replace Ubuntu Chisel with Red Hat UBI 9 (`ubi-minimal` builder, `ubi-micro` runtime). |
| [ADR-0002](template/0002-compliance-gate-openscap-rhel9-stig.md) | Accepted | Add a compliance gate via OpenSCAP DISA RHEL 9 STIG. |
| [ADR-0003](template/0003-publish-image-per-image-frozen-cosign-identity.md) | Accepted | Treat the publish-image workflow as a per-image frozen Cosign identity. |

## Org ADRs

The `org/` scope is mirrored from `NWarila/.github`.

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-0001](org/0001-use-architecture-decision-records.md) | Accepted | Use ADRs to document design rationale. |
| [ADR-0002](org/0002-adopt-diataxis-documentation-framework.md) | Accepted | Use Diataxis for non-ADR documentation. |
| [ADR-0003](org/0003-use-deny-all-gitignore-strategy.md) | Accepted | Use deny-all `.gitignore` allowlists. |
| [ADR-0004](org/0004-use-renovate-for-dependency-updates.md) | Accepted | Use Renovate for dependency updates. |
| [ADR-0005](org/0005-pin-terraform-and-provider-versions-exactly.md) | Accepted | Pin Terraform and provider versions exactly. |
| [ADR-0006](org/0006-keep-github-control-planes-namespace-local.md) | Accepted | Keep GitHub control planes namespace-local. |
| [ADR-0007](org/0007-centralize-universal-ci-reusables-within-each-namespace.md) | Accepted | Centralize universal CI reusables within each namespace. |
| [ADR-0008](org/0008-enforce-repo-hygiene-by-repo-type.md) | Accepted | Enforce repo hygiene by repo type. |
| [ADR-0009](org/0009-classify-baseline-manifest-byte-identity.md) | Accepted | Classify baseline-manifest byte identity. |
| [ADR-0010](org/0010-keep-ai-attribution-out-of-version-control.md) | Accepted | Keep AI attribution out of version control. |

The `.gitkeep` placeholder in `repo/` keeps the directory skeleton complete
until this repository has a repo-specific ADR.
