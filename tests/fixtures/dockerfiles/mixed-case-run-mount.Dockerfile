ARG BASE_IMAGE
ARG BASE_DIGEST
ARG BUILDER_IMAGE
ARG BUILDER_DIGEST
FROM ${BUILDER_IMAGE}@${BUILDER_DIGEST} AS builder
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS runtime
RUN --Mount=type=bind,FROM=docker.io/library/alpine:latest,source=/,target=/mnt true
