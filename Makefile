.PHONY: help verify ci manifest docs dockerfile build-args app-build app-verify image-build image-test image clean

# Path to the reviewed image manifest. Downstream repositories override this
# to point at their own manifest.
MANIFEST    ?= examples/image-manifest.json
IMAGE_TAG   ?= ubi9-application-template:local
# renovate: datasource=docker depName=golang versioning=docker
GO_IMAGE    ?= golang:1.23.4-alpine3.21@sha256:c23339199a08b0e12032856908589a6d41a0dab141b8b3b21f156fc571a3f1d3
APP_PLATFORM ?= linux/amd64

help:
	@printf '%s\n' \
		'Contract checks (no Docker required):' \
		'  verify     Run the full local verification surface' \
		'  ci         Alias for verify' \
		'  manifest   Validate the starter image manifest contract' \
		'  docs       Validate documentation layout' \
		'  dockerfile Validate Dockerfile contract markers' \
		'  build-args Render docker buildx flags from the manifest' \
		'' \
		'End-to-end image lifecycle (Docker required):' \
		'  app-build  Build the example Go binary deterministically' \
		'  app-verify Verify built binary SHA256s match the manifest' \
		'  image-build Build the OCI image for $$APP_PLATFORM (default linux/amd64)' \
		'  image-test  Run runtime-hardening assertions against the built image' \
		'  image       app-build + app-verify + image-build + image-test' \
		'  clean       Remove dist/ build outputs'

verify:
	python tools/verify.py verify

ci:
	python tools/verify.py ci

manifest:
	python tools/check_image_manifest.py --template $(MANIFEST)

docs:
	python tools/verify.py docs-layout

dockerfile:
	python tools/verify.py dockerfile-contract

build-args:
	python tools/generate_build_args.py $(MANIFEST)

app-build:
	GO_IMAGE='$(GO_IMAGE)' bash tools/build_app.sh

app-verify:
	python tools/verify_app_shas.py $(MANIFEST)

image-build: app-verify
	bash tools/build_image.sh '$(MANIFEST)' '$(IMAGE_TAG)' '$(APP_PLATFORM)'

image-test:
	bash tests/runtime-hardening.sh '$(IMAGE_TAG)'

image: app-build app-verify image-build image-test

clean:
	rm -rf dist
