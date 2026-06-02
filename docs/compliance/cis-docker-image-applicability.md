# CIS Docker Image Applicability Checklist

This checklist records the image-scope CIS Docker decisions for the
`ubi9-application-template` final OCI image. It deliberately separates static
image controls from Docker host, daemon, Kubernetes, registry, and release
operations.

## Source

- CIS official Docker Benchmark page: https://www.cisecurity.org/benchmark/docker
- Current CIS Docker Benchmark version observed: Docker 1.8.0
- CIS PDF access path observed: https://learn.cisecurity.org/benchmarks
- Docker image-scope guidance: https://docs.docker.com/dhi/core-concepts/cis/
- Public CIS Docker 1.8 policy implementation reference: https://docs.anchore.com/current/docs/compliance_management/policy_packs/cis/
- Public 4.12 carry-forward reference: https://wazuh.com/blog/scanning-docker-infrastructure-against-cis-benchmark/
- Review date: 2026-06-02

The official CIS page identifies Docker 1.8.0 as the current recent benchmark,
but the complete PDF requires the CIS download form. This checklist therefore
covers every image/Dockerfile control visible from accessible sources and marks
deployment-only items explicitly instead of inventing hidden benchmark text.

## Decision Values

| Decision | Meaning |
| --- | --- |
| `SATISFIED_IMAGE_CONTROL` | The image or Dockerfile implements the control directly and repo verification checks it. |
| `SATISFIED_REPO_CONTROL` | The repo implements the control through manifest, workflow, or release evidence requirements. |
| `SATISFIED_REPLACEMENT` | The original mechanism is obsolete or not appropriate, and the repo uses a stronger modern replacement. |
| `DEPLOYMENT_SPECIFIC` | The control is real, but baking it into this generic application image would either lose functionality or misrepresent deployment health. |

## Summary

| Decision | Count |
| --- | ---: |
| `SATISFIED_IMAGE_CONTROL` | 6 |
| `SATISFIED_REPO_CONTROL` | 4 |
| `SATISFIED_REPLACEMENT` | 1 |
| `DEPLOYMENT_SPECIFIC` | 1 |
| Total | 12 |

## Checklist

| CIS ID | Scope | Control | Decision | Rationale and Verification |
| --- | --- | --- | --- | --- |
| CIS-Docker-4.1 | Image | Ensure that a user for the container has been created. | `SATISFIED_IMAGE_CONTROL` | `containers/Dockerfile` sets `USER 65532:65532`, `examples/image-manifest.json` declares the same runtime user, and `tests/runtime-hardening.sh` rejects root image users. |
| CIS-Docker-4.2 | Image | Ensure that containers use only trusted base images. | `SATISFIED_REPO_CONTROL` | The final image is `FROM` Red Hat `ubi-micro`; both the `ubi-minimal` builder and the `ubi-micro` runtime are pinned by digest, RPM inputs are installed through GPG-checked microdnf, and the application artifacts come from official upstream release URLs pinned by digest. |
| CIS-Docker-4.3 | Image | Ensure that unnecessary packages are not installed in the container. | `SATISFIED_IMAGE_CONTROL` | The final rootfs carries only the application binary, its shared libraries, and the CA bundle at `/etc/pki/tls/certs/ca-bundle.crt`; runtime hardening asserts no shell, no dnf/microdnf/rpm/yum, no curl/wget, and no package-manager state beyond the read-only rpmdb preserved at `/var/lib/rpm`. |
| CIS-Docker-4.4 | Repo/Release | Ensure images are scanned and rebuilt to include security patches. | `SATISFIED_REPO_CONTROL` | The repo has scheduled security workflow coverage and Renovate configuration that rebuilds from digest-pinned UBI 9 bases. Full release evidence still depends on publishing a registry image with SBOM, provenance, signature, and vulnerability scan records. |
| CIS-Docker-4.5 | Release | Ensure Content Trust for Docker is enabled. | `SATISFIED_REPLACEMENT` | Docker documents Docker Content Trust as retired for hardened images; this repo uses the modern replacement path of keyless Cosign/Sigstore image signatures with `--recursive` plus GitHub artifact attestations in the implemented publish workflow. |
| CIS-Docker-4.6 | Deployment | Ensure that HEALTHCHECK instructions have been added to container images. | `DEPLOYMENT_SPECIFIC` | A generic application healthcheck can misreport readiness, TLS, listener, or auth-mode states and can break deployments that use orchestrator-specific readiness probes. The image stays neutral; the deployment must define application-aware health semantics. |
| CIS-Docker-4.7 | Dockerfile | Ensure update instructions are not used alone in Dockerfiles. | `SATISFIED_IMAGE_CONTROL` | Any `microdnf update` occurs in the `ubi-minimal` builder stage in the same `RUN` block as `microdnf install`, followed by `microdnf clean all` and cache removal; no package manager reaches the final `ubi-micro` image. |
| CIS-Docker-4.8 | Image | Ensure setuid and setgid permissions are removed. | `SATISFIED_IMAGE_CONTROL` | `tests/runtime-hardening.sh` exports the rootfs and rejects setuid or setgid regular files. |
| CIS-Docker-4.9 | Dockerfile | Ensure that COPY is used instead of ADD in Dockerfiles. | `SATISFIED_IMAGE_CONTROL` | `containers/Dockerfile` uses only `COPY --from=...` for image assembly and the verifier rejects `ADD` instructions. |
| CIS-Docker-4.10 | Dockerfile | Ensure secrets are not stored in Dockerfiles. | `SATISFIED_IMAGE_CONTROL` | The Dockerfile contains no secret-bearing `ARG`, `ENV`, or label values; repo verification rejects secret markers in Dockerfile content. |
| CIS-Docker-4.11 | Build | Ensure only verified packages are installed. | `SATISFIED_REPO_CONTROL` | Runtime artifacts are verified before use: the `ubi-minimal` builder and `ubi-micro` runtime are digest-pinned, RPM content is installed from Red Hat repositories with GPG-checked microdnf, and application release archives plus extracted binaries are hash-checked after signed checksum verification. |
| CIS-Docker-4.12 | Build/Release | Ensure all signed artifacts are validated. | `SATISFIED_REPO_CONTROL` | `tools/build_app.sh` verifies the upstream signed checksum file with the published signing key before validating application archives and binaries; `publish-image.yaml` signs the pushed image digest with keyless Cosign using `--recursive`, emits GitHub artifact attestations, and verifies both evidence paths before runtime hardening. |
