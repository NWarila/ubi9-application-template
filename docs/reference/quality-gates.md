# Quality Gates

These checks are only merge-blocking when the repository rulesets require their
reported status names. See [`governance.md`](governance.md) for the repository
settings that make the gates enforceable.

| Gate | Source | Role | Notes |
| --- | --- | --- | --- |
| Template verify | `python tools/verify.py ci` | Blocking | Checks docs layout, manifest contract, Dockerfile markers, runtime script coverage, Go builder image pinning, build-args generator, local build-helper boundaries, security caller workflows, the template reusable workflow, stale placeholders, and local Markdown links. |
| actionlint | `.github/workflows/ci.yaml` | Blocking | Validates workflow syntax and common GitHub Actions mistakes. |
| markdownlint | `.github/workflows/ci.yaml` | Blocking | Keeps docs readable across the template. |
| Image build + hardening | `.github/workflows/reusable-ubi-image-build.yaml` | Blocking | Template-specific reusable: builds application binaries, verifies their SHA256 against the manifest (`tools/verify_app_shas.py`), builds the UBI 9 image via `dnf --installroot` (`tools/build_image.sh`), and runs runtime hardening (`tests/runtime-hardening.sh`). `ci.yaml` calls it against the example manifest for `linux/amd64`; downstream repos call it against their real manifest. |
| Runtime hardening | `tests/runtime-hardening.sh <image>` | Blocking (CI) / Downstream blocking | Runs (via the reusable above) against the freshly built example image in CI and against the downstream image in derived repositories. |
| CodeQL | `.github/workflows/codeql.yaml` | Blocking | Calls `NWarila/.github/.github/workflows/reusable-codeql.yaml`. Scans `actions`, `python`, and `go` because the template ships executable code under `.github/workflows/`, `tools/`, and `app/`. |
| Trivy + Gitleaks + zizmor | `.github/workflows/security.yaml` | Blocking | Calls `NWarila/.github/.github/workflows/reusable-iac-security.yaml`. Trivy filesystem misconfig + secret scanning (HIGH/CRITICAL), Gitleaks full-history secret detection, zizmor GitHub Actions security analysis. SARIF uploaded to the Security tab. |
| OpenSSF Scorecard | `.github/workflows/scorecard.yaml` | Blocking | Calls `NWarila/.github/.github/workflows/reusable-scorecard.yaml`. Repo-level supply-chain posture (branch protection, code review, pinned dependencies, signed releases, vulnerabilities). |
| Repo hygiene | `.github/workflows/repo-hygiene.yaml` | Blocking | Calls `NWarila/.github/.github/workflows/reusable-repo-hygiene.yaml`. Enforces org workflow hygiene, including 40-character SHA pins and `pull_request_target` boundary safety. |
| Auto-merge for trusted bots | `.github/workflows/auto-merge.yaml` | Advisory | Calls `NWarila/.github/.github/workflows/reusable-auto-merge.yaml`. Enables GitHub auto-merge on Renovate and Dependabot PRs once required checks pass; human-authored PRs are never auto-merged. The central reusable authorizes the PR author read-only before any write token is used. |
| BuildKit SBOM/provenance | Downstream release workflow | Release | Should be emitted on the pushed image digest with `--sbom=true` and `--provenance=mode=max`. The preserved rpm database at `/var/lib/rpm` lets the SBOM enumerate installed packages. Local `--load` builds do not preserve attestations. |
| GitHub artifact attestations | Downstream release workflow | Release | Should attest image digest and SBOM. See [`publish-image.md`](../how-to/publish-image.md) for a drop-in workflow. |
| Cosign signature | Downstream release workflow | Release | Should sign the image digest with identity-bound keyless signing, using `cosign sign --recursive` so attached SBOM and attestation manifests are covered. See [`publish-image.md`](../how-to/publish-image.md) for keyless OIDC example. |
| OpenSCAP RHEL 9 STIG + Trivy + Grype | Downstream release workflow | Release | OpenSCAP evaluates the pushed image against the RHEL 9 STIG profile; Trivy and Grype scan it for vulnerabilities. The preserved rpm database makes these scans see the real package set. See [`publish-image.md`](../how-to/publish-image.md). |

## What Is Intentionally Not In This Template CI

- Pushing the example image to a registry or emitting release attestations: the
  template does not own a publish destination. Downstream repositories add
  `--push` and registry credentials.
- Cosign signing and GitHub artifact attestation upload: those are bound to a
  publish destination as well.
- Multi-architecture runtime hardening: the example image is built and tested
  for `linux/amd64` only; the manifest declares both `linux/amd64` and
  `linux/arm64` and the build args support both, but cross-platform runtime
  assertions need QEMU and add CI time without changing the contract.
- Application vulnerability scanning: downstream repos own application inputs.

Add those gates when deriving a concrete image repository.
