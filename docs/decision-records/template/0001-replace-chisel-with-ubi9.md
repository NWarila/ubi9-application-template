# ADR-0001: Replace Ubuntu Chisel with Red Hat UBI 9

| Field          | Value                                    |
| -------------- | ---------------------------------------- |
| Status         | Accepted                                 |
| Date           | 2026-06-02                               |
| Authors        | Nick Warila (@NWarila)                   |
| Decision-maker | Nick Warila (sole portfolio maintainer)  |
| Consulted      | None.                                    |
| Informed       | None.                                    |
| Reversibility  | Low                                      |
| Review-by      | N/A (Accepted)                           |

## TL;DR

This template retires the Ubuntu Chisel runtime path and adopts Red Hat
Universal Base Image 9: `ubi-minimal` as the builder stage (it carries `dnf`)
and `ubi-micro` as the runtime stage. Both bases are pinned by `@sha256:`
digest and Renovate-managed with `redhat` versioning. The runtime rootfs is
assembled with `dnf --installroot` so the rpm database is preserved at
`/var/lib/rpm` and the dnf history at `/var/lib/dnf`, which is how
Trivy/Grype/OpenSCAP enumerate installed packages. The CA bundle lives at
`/etc/pki/tls/certs/ca-bundle.crt`. No shell and none of `dnf`, `microdnf`,
`rpm`, `yum`, `curl`, or `wget` exist in the runtime image. The image manifest
moves to schema v2 (`base.{builder,runtime}` plus `dnf.packages`; the
`chisel`/`ubuntu_series` fields are dropped). The repository name encodes the
major version (`ubi9-`); a UBI 10 cutover is therefore a deliberate rename and
repeat, gated on a CMVP-validated RHEL 10 crypto module and a published DISA
RHEL 10 STIG.

## Context and Problem Statement

The earlier shape of this template built a minimal runtime image from Canonical
Chisel slices. Chisel resolves slice definitions and then fetches the
referenced `.deb` packages from the live Ubuntu archive at build time. Two
properties of that archive are structural, not incidental:

1. **It is mutable.** The pocket a slice resolves from (`<series>`,
   `<series>-updates`, `<series>-security`) is rewritten in place as Canonical
   publishes new package versions. A build run today and a build run tomorrow
   from byte-identical inputs can fetch different package versions, because the
   archive moved underneath the slice reference. There is no archive-side
   content digest the build pins against.
2. **It has publish windows.** During an Ubuntu `-security` publish, the archive
   is briefly inconsistent: `Packages` indices and the pool can be momentarily
   out of step. Chisel builds that land inside such a window fail or, worse,
   resolve a transitional state.

The consequence is that the supply-chain story the template is meant to
demonstrate — reproducible, digest-pinned, scanner-legible images — was
undermined at its root by a non-reproducible, non-pinnable base content source.

Red Hat's Universal Base Image solves the same "minimal runtime" problem with a
different content model:

- **Digest-pinnable bases.** `registry.access.redhat.com/ubi9/ubi-minimal` and
  `.../ubi9-micro` (and their `ubi9/ubi-micro` equivalents) are published as
  OCI images addressable by `@sha256:` digest. Pinning the digest pins the
  exact base bytes; Renovate bumps the digest with `redhat` versioning.
- **NVR-resolvable content.** `dnf` resolves packages to Name-Version-Release
  tuples against versioned RHEL 9 repositories. The same package spec resolves
  to the same NVR for the life of a repository snapshot, and the resolution is
  auditable after the fact.
- **A preserved rpm database.** Because the rootfs is built with
  `dnf --installroot`, the resulting tree carries `/var/lib/rpm` and
  `/var/lib/dnf`. Scanners read these to enumerate the installed package set.
- **A real compliance posture.** RHEL 9 has a published DISA STIG and a
  maintained SCAP Security Guide (SSG) content stream. Ubuntu's STIG/SSG
  coverage for a Chisel-sliced rootfs is comparatively thin, and a Chisel rootfs
  has no rpm/dpkg database in the conventional location for scanners to read.

The problem statement is therefore: choose a base-image and content model that
makes the template's reproducibility and scanner-legibility claims actually
true, while preserving the "no shell, no package manager, tiny attack surface"
runtime property the Chisel path provided.

## Decision Drivers

1. **Reproducibility.** The base bytes and the installed package set must be
   pinnable and deterministic, not subject to a mutable upstream archive.
2. **Publish-window resilience.** A build must not fail or resolve a
   transitional state because an upstream security publish is mid-flight.
3. **Scanner legibility.** Trivy, Grype, and OpenSCAP must be able to enumerate
   the installed package set from a database in the rootfs, so that a "0 CVE"
   result reflects reality rather than a deleted database.
4. **Compliance posture.** The runtime must sit on a base with a published DISA
   STIG and maintained SSG content, so the compliance gate in
   [ADR-0002](0002-compliance-gate-openscap-rhel9-stig.md) has real content to
   evaluate against.
5. **Minimal runtime attack surface.** The runtime image must retain the
   no-shell, no-package-manager property: no `dnf`, `microdnf`, `rpm`, `yum`,
   `curl`, or `wget`, and no shell.
6. **Renovate fitness.** Both bases must be Renovate-manageable so digest bumps
   are explicit, reviewable PRs, consistent with the org's pin-everything
   posture.

## Considered Options

1. **Adopt UBI 9 (`ubi-minimal` builder, `ubi-micro` runtime), retire Chisel.**
2. **Keep Ubuntu Chisel, pin a base snapshot mirror.** Stand up or rely on a
   pinned Ubuntu archive snapshot so Chisel resolves from frozen content.
3. **Switch to a distroless base** (for example, a community distroless image)
   instead of UBI.
4. **Build from scratch with a hand-assembled rootfs** and a bespoke package
   provenance story.

## Decision Outcome

Chosen option: **Option 1, adopt Red Hat UBI 9 and retire the Chisel path.**

The template's image is built as:

- **Builder stage** from `ubi9/ubi-minimal`, digest-pinned, which carries `dnf`.
  The runtime rootfs is assembled with `dnf install --installroot=/rootfs`,
  `--setopt=install_weak_deps=false`, and `--setopt=tsflags=nodocs`. Only the
  regenerable dnf cache and logs are pruned. `/rootfs/var/lib/rpm` and
  `/rootfs/var/lib/dnf` are **never** removed.
- **Runtime stage** from `ubi9/ubi-micro`, digest-pinned, into which the
  assembled rootfs and the application are copied.

Both base references are `@sha256:` digest-pinned (recorded in the image
manifest) and Renovate-managed with `redhat` versioning. The trust-anchor CA
bundle is at `/etc/pki/tls/certs/ca-bundle.crt`. The runtime image contains no
shell and none of `dnf`, `microdnf`, `rpm`, `yum`, `curl`, or `wget`; the
runtime-hardening assertions enforce this (see
[reference/runtime-hardening.md](../../reference/runtime-hardening.md) and
[reference/invariants.md](../../reference/invariants.md)).

The image manifest moves to **schema v2** (`schema_version: "2.0"`): it carries
`base.builder` and `base.runtime` digest-pinned references and a `dnf.packages`
list, and it drops the Chisel-era `chisel` and `ubuntu_series` fields. The
schema is defined in
[contracts/image-manifest.schema.json](../../../contracts/image-manifest.schema.json)
and described in [reference/image-manifest.md](../../reference/image-manifest.md).

**Accepted trade-off — the major version is in the repo name.** The repository
is `NWarila/ubi9-application-template`; the `ubi9-` prefix encodes the RHEL
major. A move to UBI 10 is therefore not an in-place base bump: it is a
repository rename plus a repeat of this cutover (new bases, re-pinned digests,
re-baselined STIG content). The documented trigger to revisit this decision and
begin a UBI 10 cutover is the conjunction of (a) a CMVP-validated RHEL 10 crypto
module in FIPS mode and (b) a published DISA RHEL 10 STIG. Until both exist,
RHEL 9 remains the floor.

## Pros and Cons of the Options

### Option 1: Adopt UBI 9, retire Chisel (chosen)

- **Good, because** the bases are `@sha256:` digest-pinnable; the base bytes are
  reproducible and Renovate-manageable.
- **Good, because** `dnf` resolves to auditable NVRs against versioned RHEL 9
  repositories; the installed set is deterministic and post-hoc verifiable.
- **Good, because** `dnf --installroot` preserves `/var/lib/rpm` and
  `/var/lib/dnf`, so Trivy/Grype/OpenSCAP enumerate the real package set.
- **Good, because** RHEL 9 has a published DISA STIG and maintained SSG content,
  giving [ADR-0002](0002-compliance-gate-openscap-rhel9-stig.md) genuine content
  to evaluate.
- **Good, because** `ubi-micro` preserves the minimal-runtime property: no shell
  and no package manager once the rootfs is copied in.
- **Bad, because** the `ubi9-` repo name encodes the major; a UBI 10 move is a
  rename-and-repeat, not a bump.
- **Bad, because** UBI subscription/entitlement nuances and Red Hat repository
  availability are now part of the build's dependency surface.
- **Neutral, because** the runtime image is larger than a hand-sliced Chisel
  rootfs, but the difference is small for the example and is the price of a
  scanner-legible rpmdb.

### Option 2: Keep Chisel, pin a snapshot mirror

- **Good, because** it would preserve the existing Chisel tooling and a smaller
  rootfs.
- **Bad, because** it requires standing up and operating a pinned Ubuntu archive
  snapshot, which is itself infrastructure to maintain and secure.
- **Bad, because** a Chisel rootfs still has no conventional package database
  for scanners; the "0 CVE" legibility problem remains.
- **Bad, because** Ubuntu STIG/SSG coverage for a sliced rootfs is thin compared
  with RHEL 9, so the compliance gate would have little to evaluate.

### Option 3: Switch to a community distroless base

- **Good, because** distroless images are minimal and widely used.
- **Bad, because** most distroless bases also ship without an rpm/dpkg database
  in the conventional location, re-introducing the scanner-legibility gap.
- **Bad, because** distroless bases generally lack a published DISA STIG, so the
  compliance gate loses its anchor.

### Option 4: Build from scratch with a bespoke rootfs

- **Good, because** it offers total control over every byte.
- **Bad, because** it requires inventing a package-provenance and
  scanner-legibility story from nothing, duplicating what UBI provides for free.
- **Bad, because** it maximizes maintenance burden for a template whose purpose
  is to demonstrate a clean supply-chain shape, not bespoke rootfs assembly.

## Confirmation

Adherence is confirmed by the following mechanisms. `MUST`, `SHOULD`, and `MAY`
follow [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) conventions.

1. **Digest pins.** Both `base.builder` and `base.runtime` in the image manifest
   MUST be `@sha256:` digest references. The manifest contract
   ([contracts/image-manifest.schema.json](../../../contracts/image-manifest.schema.json))
   and the manifest check assert this.
2. **rpmdb preservation.** The runtime image MUST contain a non-empty
   `/var/lib/rpm`. A runtime-hardening assertion confirms scanners can enumerate
   the package set (see
   [reference/runtime-hardening.md](../../reference/runtime-hardening.md)).
3. **Runtime forbiddance.** The runtime image MUST NOT contain a shell or any of
   `dnf`, `microdnf`, `rpm`, `yum`, `curl`, or `wget`. The runtime-hardening
   assertions enforce this; the invariants are listed in
   [reference/invariants.md](../../reference/invariants.md).
4. **CA bundle location.** The trust anchors MUST be at
   `/etc/pki/tls/certs/ca-bundle.crt`.
5. **Schema v2.** The manifest MUST set `schema_version: "2.0"` and MUST NOT
   carry `chisel` or `ubuntu_series` keys (the schema is `additionalProperties:
   false`).
6. **Renovate management.** Both base digests MUST be Renovate-managed with
   `redhat` versioning so each bump is an explicit, reviewable PR.

## Consequences

### Positive

- Reproducible, digest-pinned bases and an auditable, NVR-resolvable package set.
- Builds are resilient to upstream publish windows.
- A scanner-legible rpmdb makes "0 fixable HIGH/CRITICAL" a real claim.
- A published DISA RHEL 9 STIG anchors the compliance gate.
- The minimal-runtime attack surface (no shell, no package manager) is retained.

### Negative

- The major version is in the repo name; UBI 10 is a rename-and-repeat cutover.
- Red Hat repository availability and entitlement nuances enter the build's
  dependency surface.
- The runtime image is modestly larger than a hand-sliced Chisel rootfs.

### Neutral

- Existing Chisel-era documentation and example inputs are replaced by their
  UBI 9 equivalents in a one-time editorial pass.
- The template now demonstrates an RHEL-shaped supply chain; consumers who need
  a Debian/Ubuntu lineage must fork and re-establish the base content model.

## Assumptions

If any of these becomes false, this ADR should be revisited:

1. Red Hat continues to publish `ubi9/ubi-minimal` and `ubi9/ubi-micro` as
   digest-addressable OCI images with NVR-resolvable RHEL 9 repository content.
2. RHEL 9 remains in a support window with a maintained SSG content stream and a
   current DISA STIG.
3. `dnf --installroot` continues to produce a rootfs that preserves
   `/var/lib/rpm` and `/var/lib/dnf` in a form Trivy/Grype/OpenSCAP can read.
4. No CMVP-validated RHEL 10 crypto module **and** published DISA RHEL 10 STIG
   yet exist together; once both do, a UBI 10 cutover (and repo rename) is
   considered.

## Supersedes

None. This is the first template-scoped ADR. It replaces the Ubuntu Chisel
direction that was previously documented in the README and reference material
rather than in a template ADR; that prose is updated by the implementing PRs.

## Superseded by

None (current).

## Implementing PRs

Pending. The implementing PRs replace the Chisel builder/runtime stages in
[containers/Dockerfile](../../../containers/Dockerfile) with the UBI 9
`ubi-minimal` builder / `ubi-micro` runtime stages, move the manifest to schema
v2 in [contracts/image-manifest.schema.json](../../../contracts/image-manifest.schema.json)
and [examples/image-manifest.json](../../../examples/image-manifest.json),
update the build and verification tooling, and rewrite the Chisel-era prose in
[reference/image-manifest.md](../../reference/image-manifest.md) and
[reference/runtime-hardening.md](../../reference/runtime-hardening.md).

## Related ADRs

- [org ADR-0001](../org/0001-use-architecture-decision-records.md) — establishes
  the ADR format and the three-tier (org/template/repo) scope structure.
- [ADR-0002](0002-compliance-gate-openscap-rhel9-stig.md) — the compliance gate
  that the UBI 9 base and preserved rpmdb make possible.
- [ADR-0003](0003-publish-image-per-image-frozen-cosign-identity.md) — how the
  UBI 9 image is signed and published with a frozen cosign identity.

## Compliance Notes

Moving to a digest-pinned UBI 9 base with a preserved rpm database directly
strengthens the configuration-baseline and integrity story and gives the
compliance gate real content to evaluate.

| Framework              | Control / Practice ID                                               | Potential Evidence Contribution                                                                                       |
| ---------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| NIST SP 800-53 Rev. 5  | CM-2 (Baseline Configuration)                                       | Digest-pinned bases plus an NVR-resolvable package set define a reproducible baseline image.                          |
| NIST SP 800-53 Rev. 5  | SI-7 (Software, Firmware, and Information Integrity)                | A preserved `/var/lib/rpm` lets scanners verify the installed-package integrity rather than trusting a deleted store. |
| NIST SP 800-218 (SSDF) | PW.4 (Reuse Existing, Well-Secured Software)                        | Adopting Red Hat's maintained, STIG-backed UBI bases reuses well-secured, supported components.                       |
