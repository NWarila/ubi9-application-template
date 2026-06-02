# Governance

This repository carries workflow files and local checks, but GitHub repository
settings do not transfer automatically when a new repository is created from a
template. Apply this reference to each downstream image repository before
relying on auto-merge or treating a green pull request as release-ready.

## Repository Rulesets

Use rulesets or branch protection to cover the default branch.

| Rule area | Expected setting |
| --- | --- |
| Branch creation, update, deletion | Protected on the default branch. |
| Non-fast-forward updates | Blocked. |
| Linear history | Required when the repository uses squash-only merges. |
| Signed commits | Required if the owning organization requires verified commits. |
| Pull request review | At least one approval, stale approvals dismissed on push, code-owner review required, review-thread resolution required. |
| Allowed merge methods | Squash unless the owning organization has a different baseline. |

The template repository currently uses repository rulesets named **Branch
Safety**, **Pull Request Gate**, and **Release Tag Protection**. Downstream
repositories may use different names, but they should preserve the intent.

## Required Status Checks

Rulesets must name real status checks. Empty required-status-check lists make
CI visible but non-blocking.

After the first pull request runs, require the exact check names GitHub reports
for these gates:

| Gate | Source |
| --- | --- |
| actionlint | `.github/workflows/ci.yaml` |
| markdownlint | `.github/workflows/ci.yaml` |
| template verify | `.github/workflows/ci.yaml` |
| image build + hardening | `.github/workflows/ci.yaml` calling `.github/workflows/reusable-ubi-image-build.yaml` |
| CodeQL | `.github/workflows/codeql.yaml` |
| Trivy + Gitleaks + zizmor | `.github/workflows/security.yaml` |
| OpenSSF Scorecard | `.github/workflows/scorecard.yaml` |

Do not require the auto-merge workflow as a merge gate. Auto-merge is the
mechanism that enables GitHub auto-merge for trusted bots after required checks
pass; it is not itself a quality gate.

## CODEOWNERS

`.github/CODEOWNERS` must reference users or teams with write access to the
repository. An organization login by itself is not a valid CODEOWNERS owner.
Verify CODEOWNERS after generation:

```sh
gh api repos/OWNER/REPO/codeowners/errors
```

The expected result is an empty `errors` array.

## Required Signatures

If rulesets require signed commits or signed tags, make that visible in the
repository onboarding notes. Bot commits, release tags, and emergency fixes
must be able to satisfy the signature requirement or use an explicitly approved
bypass path.

Release tags should also block deletion and non-fast-forward updates.

## Security Settings

Enable these repository settings or inherit them from the organization:

- Secret scanning.
- Push protection.
- Dependabot alerts and security updates.
- Vulnerability alerts.
- Delete branch on merge.
- Auto-merge, if trusted-bot auto-merge is desired.
- Squash merge as the only allowed merge method, if using the baseline above.

## Actions Policy

This template calls reusable workflows from `NWarila/.github` for CodeQL,
Scorecard, and security scanning. A downstream organization must allow those
cross-repository reusable workflow calls, or it must mirror the reusable
workflows into its own `.github` repository and update the pins.

## Variables And Secrets

The template CI does not require repository variables or custom secrets. It
uses `GITHUB_TOKEN` only. Downstream publish workflows usually need package
write permission for `GITHUB_TOKEN` or an organization-approved registry
credential, depending on the target registry.

If a repository later adopts release-please, document the enabling variable and
the release PR approval path in that repository. This template does not ship a
release-please workflow by default.
