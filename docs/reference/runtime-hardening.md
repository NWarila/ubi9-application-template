# Runtime Hardening

The runtime baseline is intentionally small and inspectable.

## Required Assertions

`tests/runtime-hardening.sh <image-ref>` checks that:

- The image config uses a non-root user.
- The entrypoint targets `/usr/local/bin/app`.
- `/bin/sh` and `/bin/bash` are absent.
- `dnf`, `microdnf`, `rpm`, `yum`, `curl`, and `wget` are absent.
- The dnf cache and log trees are absent (only the regenerable cache is
  pruned; the rpm database at `/var/lib/rpm` is deliberately kept).

The script inspects the exported root filesystem, so it does not require the
application to start or accept a health-check flag.

## Downstream Extensions

Derived repositories should add application-specific assertions, such as:

- Expected ports.
- Read-only filesystem compatibility.
- Presence of the CA bundle at `/etc/pki/tls/certs/ca-bundle.crt` when the
  application makes outbound TLS connections.
- Absence of unexpected interpreters or package managers introduced by extra
  `dnf.packages`.
