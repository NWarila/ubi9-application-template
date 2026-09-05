ARG BASE_IMAGE
ARG BASE_DIGEST
ARG BUILDER_IMAGE
ARG BUILDER_DIGEST
FROM ${BUILDER_IMAGE}@${BUILDER_DIGEST} AS builder
RUN true
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS runtime-amd64
COPY --from=builder /bin/true /bin/true
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS runtime-arm64
COPY --from=builder /bin/true /bin/true
FROM runtime-${TARGETARCH} AS runtime
