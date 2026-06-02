# ADR-0002: Compliance Gate via OpenSCAP DISA RHEL 9 STIG

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

The image's compliance gate combines three independent evaluations against the
UBI 9 runtime, all run in CI:

1. **OpenSCAP** against the DISA RHEL 9 STIG profile
   (`xccdf_org.ssgproject.content_profile_stig`) using SCAP Security Guide
   **v0.1.81**, built reproducibly from the **SHA512-pinned source tarball**.
2. **Trivy** and **Grype** vulnerability scans using Red Hat VEX/OVAL data with
   `--ignore-unfixed`, targeting **0 fixable HIGH/CRITICAL** findings.
3. A parsed **DISA RHEL 9 STIG V2R8 applicability checklist** of **446 rows**,
   pinned with `EXPECTED_RULE_COUNT=446` and
   `EXPECTED_SOURCE_HASH=418855970157b31e4026a6ca7075fc1e723f40f30ef4554affbd3cafff0cc518`.

Because the *built* `ssg-rhel9-ds.xml` datastream embeds build timestamps and is
therefore not byte-deterministic, the pinned constant is the **SHA512 of the
source tarball**, not the SHA256 of the generated datastream. The exact OpenSCAP
pass threshold (the minimum acceptable rule pass rate) is recorded here as an
open decision pending baseline measurement.

## Context and Problem Statement

[ADR-0001](0001-replace-chisel-with-ubi9.md) moved the runtime onto a UBI 9
base specifically so the image would sit on a platform with a published DISA
STIG and a maintained SCAP Security Guide. That decision is only worth its cost
if the template actually *evaluates* against that content in CI. A base with a
STIG that nobody runs is no better than a base without one.

Three distinct questions need answering for every build, and they are not
interchangeable:

1. **Is the runtime configured to the DISA STIG?** This is a configuration
   assessment — file permissions, crypto policy, disabled services, audit
   settings — and the tool for it is OpenSCAP evaluating an SSG datastream.
2. **Does the installed package set carry known, fixable vulnerabilities?** This
   is a CVE question, answered by vulnerability scanners reading the preserved
   rpm database and Red Hat's security data.
3. **Which STIG rules even apply to a minimal container image?** A large fraction
   of a full-OS STIG (bootloader, host firewall, physical console, GUI lockdown)
   is inapplicable to a `ubi-micro` runtime. Without an explicit applicability
   checklist, an operator cannot tell "passed" from "not applicable" from
   "silently skipped".

Each question needs its own evaluator, and each evaluator needs **pinned,
reproducible inputs**. The hard part is the pinning. SSG content is normally
consumed as a pre-built `ssg-rhel9-ds.xml` SCAP datastream. That generated
datastream embeds build metadata, including timestamps, so two builds of the
same SSG release produce datastreams with **different SHA256 digests**. Pinning
the datastream's hash would therefore be a non-reproducible pin that fails on
every rebuild. The input that *is* stable across rebuilds is the **SSG source
release tarball**: its bytes are fixed once published, so its SHA512 is a sound
constant to pin against. The build then generates the datastream locally from
that verified source.

## Decision Drivers

1. **Reproducible, pinned inputs.** Every compliance input must be pinned to a
   constant that is actually stable across rebuilds.
2. **Three orthogonal evaluations.** Configuration posture (OpenSCAP),
   vulnerability posture (Trivy + Grype), and applicability accounting (the STIG
   checklist) are different questions and must not be conflated.
3. **Defensible "0 CVE" claims.** A vulnerability pass must reflect the real
   installed set read from the preserved rpmdb, using authoritative Red Hat data.
4. **Applicability transparency.** An operator must be able to see, per STIG
   rule, whether it applies to a minimal container and what the result was.
5. **Determinism of the pin.** Because the built datastream is
   timestamp-nondeterministic, the pin must target the deterministic source
   artifact, not the generated one.
6. **Honest threshold accounting.** The pass threshold must be set from a
   measured baseline, not asserted blind; until measured, it is an open decision.

## Considered Options

1. **OpenSCAP (DISA RHEL 9 STIG, SSG v0.1.81 built from the SHA512-pinned source
   tarball) + Trivy + Grype (`--ignore-unfixed`, 0 fixable HIGH/CRITICAL) + a
   parsed 446-row V2R8 applicability checklist.** (Chosen.)
2. **OpenSCAP only.** Treat the SSG STIG evaluation as the whole gate; skip the
   separate vulnerability scanners and the applicability checklist.
3. **Vulnerability scanners only.** Run Trivy/Grype and drop the configuration
   (OpenSCAP/STIG) assessment entirely.
4. **Pin the built `ssg-rhel9-ds.xml` datastream by SHA256** instead of pinning
   the source tarball by SHA512.
5. **Consume the OS vendor's pre-built SSG package** from the distro repos with
   no independent hash pin.

## Decision Outcome

Chosen option: **Option 1, the three-evaluation gate with source-pinned SSG.**

The CI compliance gate runs all three evaluations against the built UBI 9 image:

**OpenSCAP / DISA RHEL 9 STIG.** The gate uses SCAP Security Guide **v0.1.81**.
The SSG **source release tarball** is fetched and verified against the pinned
constant `EXPECTED_SOURCE_HASH =
418855970157b31e4026a6ca7075fc1e723f40f30ef4554affbd3cafff0cc518` (SHA512). The
`ssg-rhel9-ds.xml` datastream is then built locally from the verified source and
evaluated with `oscap` against profile
`xccdf_org.ssgproject.content_profile_stig`. The built datastream's own SHA256
is **deliberately not pinned**, because the build embeds timestamps and the
digest changes on every rebuild; the SHA512 of the source tarball is the stable
pin.

**Trivy + Grype.** Both scanners evaluate the runtime image, reading the
preserved `/var/lib/rpm` (per [ADR-0001](0001-replace-chisel-with-ubi9.md)) and
using Red Hat VEX/OVAL security data. Both run with `--ignore-unfixed`, and the
gate target is **0 fixable HIGH/CRITICAL** findings. Two scanners are used
because their data sources and matching heuristics differ; agreement raises
confidence and either tool flagging a fixable HIGH/CRITICAL fails the gate.

**Applicability checklist.** A parsed **DISA RHEL 9 STIG V2R8** checklist of
**446 rows** is carried as a fixture. The parser asserts `EXPECTED_RULE_COUNT =
446` so a truncated or drifted source is caught, and it ties each row to its
applicability disposition for a minimal container, making "passed" versus "not
applicable" versus "skipped" explicit and auditable.

**Open decision — the exact oscap pass threshold.** The minimum acceptable
OpenSCAP rule pass rate (or the explicit allowlist of accepted
inapplicable/failed rules) is **not fixed by this ADR**. It is to be set from a
measured baseline of the current image against the V2R8 applicable subset, then
recorded in [reference/quality-gates.md](../../reference/quality-gates.md). Until
then, the gate reports the score and the applicability breakdown without failing
on a numeric threshold.

The gate's mechanics and thresholds are documented in
[reference/quality-gates.md](../../reference/quality-gates.md) and
[reference/supply-chain-evidence.md](../../reference/supply-chain-evidence.md).

## Pros and Cons of the Options

### Option 1: Three-evaluation gate with source-pinned SSG (chosen)

- **Good, because** configuration, vulnerability, and applicability are
  evaluated separately by the right tool for each, with no conflation.
- **Good, because** pinning the source tarball's SHA512 is a *reproducible* pin;
  it survives rebuilds, unlike a datastream SHA256.
- **Good, because** Trivy and Grype on the preserved rpmdb with Red Hat data
  make "0 fixable HIGH/CRITICAL" a defensible, double-checked claim.
- **Good, because** the 446-row checklist with a pinned row count and source
  hash makes STIG applicability auditable and tamper-evident.
- **Bad, because** building the datastream from source adds a build step
  (fetch + verify + `make`) versus consuming a pre-built artifact.
- **Bad, because** the pass threshold is left open, so the gate is initially
  reporting-only for the OpenSCAP score.
- **Neutral, because** maintaining the pinned SSG version and V2R8 checklist is
  ongoing work, but it is the work that makes the gate trustworthy.

### Option 2: OpenSCAP only

- **Good, because** it is the simplest single-tool configuration gate.
- **Bad, because** STIG configuration assessment says nothing about CVEs in the
  installed packages; a fully STIG-compliant image can still ship a critical CVE.
- **Bad, because** without an applicability checklist, inapplicable container
  rules muddy the score and obscure what actually passed.

### Option 3: Vulnerability scanners only

- **Good, because** it directly answers the "any fixable critical CVEs?"
  question with minimal moving parts.
- **Bad, because** it abandons configuration posture entirely; crypto policy,
  permissions, and audit settings go unassessed.
- **Bad, because** it forfeits the DISA STIG anchor that
  [ADR-0001](0001-replace-chisel-with-ubi9.md) chose UBI 9 to obtain.

### Option 4: Pin the built datastream by SHA256

- **Good, because** pinning the exact evaluated artifact is intuitively the
  tightest pin.
- **Bad, because** the built `ssg-rhel9-ds.xml` embeds build timestamps and is
  **not** byte-deterministic; its SHA256 changes on every rebuild, so the pin
  fails spuriously and forces churn.
- **Bad, because** it creates a false sense of determinism over an artifact that
  is inherently non-reproducible.

### Option 5: Consume the distro SSG package with no hash pin

- **Good, because** it is the lowest-effort way to get SSG content.
- **Bad, because** it abandons input pinning; the content can move under the gate
  with no tamper-evidence, defeating the reproducibility goal.

## Confirmation

Adherence is confirmed by the following. `MUST`, `SHOULD`, and `MAY` follow
[RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) conventions.

1. **Source-hash verification.** The SSG source tarball MUST be verified against
   `EXPECTED_SOURCE_HASH` (SHA512) before the datastream is built; a mismatch
   MUST fail the build.
2. **Profile and version.** OpenSCAP MUST evaluate profile
   `xccdf_org.ssgproject.content_profile_stig` from SSG **v0.1.81** built from
   the verified source.
3. **Vulnerability target.** Trivy and Grype MUST run with `--ignore-unfixed`
   against the runtime image's preserved rpmdb; the gate target is 0 fixable
   HIGH/CRITICAL from either tool.
4. **Checklist integrity.** The applicability parser MUST assert
   `EXPECTED_RULE_COUNT = 446`; a different row count MUST fail the gate.
5. **No datastream-hash pin.** The build MUST NOT pin the generated
   `ssg-rhel9-ds.xml` by SHA256; the documented reason is its
   timestamp-nondeterminism.
6. **Threshold provenance.** When the OpenSCAP pass threshold is set, it MUST be
   recorded in [reference/quality-gates.md](../../reference/quality-gates.md)
   with the baseline measurement it derives from.

## Consequences

### Positive

- Configuration, vulnerability, and applicability are each evaluated by the
  appropriate tool against pinned, reproducible inputs.
- "0 fixable HIGH/CRITICAL" is double-checked (Trivy + Grype) against Red Hat
  data on the real installed set.
- STIG applicability is auditable and tamper-evident via the pinned 446-row
  V2R8 checklist.
- The SSG pin survives rebuilds because it targets the deterministic source.

### Negative

- The build does more work: fetch, verify, and build the datastream from source.
- The OpenSCAP pass threshold is initially open; the score is reported but not
  yet a hard fail condition.
- Maintenance: the pinned SSG version, source hash, and V2R8 checklist must be
  bumped deliberately as DISA and SSG release new content.

### Neutral

- Two vulnerability scanners mean two sets of advisories to reconcile when they
  disagree, but the reconciliation itself is signal.
- The checklist is a fixture in the repo; its row count and source hash are part
  of the gate's tamper-evidence surface.

## Assumptions

If any of these becomes false, this ADR should be revisited:

1. SSG **v0.1.81** remains the chosen content version, and its source release
   tarball's SHA512 remains `EXPECTED_SOURCE_HASH` as recorded above.
2. The built `ssg-rhel9-ds.xml` continues to embed nondeterministic build
   metadata, so source-tarball pinning remains the correct strategy.
3. DISA RHEL 9 STIG **V2R8** remains the applicable revision and continues to
   resolve to **446** rules for the parsed checklist.
4. Trivy and Grype continue to read the preserved rpmdb and to consume Red Hat
   VEX/OVAL data with a working `--ignore-unfixed` semantics.

## Supersedes

None.

## Superseded by

None (current).

## Implementing PRs

Pending. The implementing PRs add the OpenSCAP STIG step (fetch + SHA512-verify
SSG v0.1.81 source, build the datastream, run `oscap` against the STIG profile),
wire Trivy and Grype with `--ignore-unfixed` into the CI gate, add the parsed
446-row V2R8 applicability checklist fixture with its `EXPECTED_RULE_COUNT` and
`EXPECTED_SOURCE_HASH` assertions, and document the gate and the open threshold
in [reference/quality-gates.md](../../reference/quality-gates.md) and
[reference/supply-chain-evidence.md](../../reference/supply-chain-evidence.md).

## Related ADRs

- [ADR-0001](0001-replace-chisel-with-ubi9.md) — adopts the UBI 9 base and
  preserves `/var/lib/rpm`, which this compliance gate depends on.
- [ADR-0003](0003-publish-image-per-image-frozen-cosign-identity.md) — the
  compliance evidence produced here is attached to the signed, published image.
- [org ADR-0001](../org/0001-use-architecture-decision-records.md) — establishes
  the ADR format and scope structure.

## Compliance Notes

This ADR is itself the compliance-evaluation mechanism for the template; it
contributes flaw-remediation and configuration-assessment evidence.

| Framework              | Control / Practice ID                                               | Potential Evidence Contribution                                                                                          |
| ---------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| NIST SP 800-53 Rev. 5  | RA-5 (Vulnerability Monitoring and Scanning)                       | Trivy + Grype scans of the preserved rpmdb against Red Hat data provide per-build vulnerability evidence.               |
| NIST SP 800-53 Rev. 5  | CM-6 (Configuration Settings)                                      | OpenSCAP evaluation against the DISA RHEL 9 STIG profile assesses configuration settings against an authoritative baseline. |
| NIST SP 800-218 (SSDF) | RV.1 (Identify and Confirm Vulnerabilities on an Ongoing Basis)    | The combined scanner-plus-OpenSCAP gate runs on every build, confirming vulnerabilities and configuration drift continuously. |
| DISA STIG              | RHEL 9 STIG V2R8                                                   | The 446-row applicability checklist and OpenSCAP STIG profile evaluation map directly to DISA RHEL 9 STIG requirements. |
