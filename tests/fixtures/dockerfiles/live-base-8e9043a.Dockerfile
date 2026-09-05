ARG UBI_MINIMAL_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal
ARG UBI_MICRO_IMAGE=registry.access.redhat.com/ubi9/ubi-micro
FROM ${UBI_MINIMAL_IMAGE} AS fips-verify
FROM ${UBI_MINIMAL_IMAGE} AS build-amd64
FROM ${UBI_MINIMAL_IMAGE} AS build-arm64
FROM build-${TARGETARCH} AS selected
FROM ${UBI_MICRO_IMAGE} AS dev
FROM dev AS runtime
