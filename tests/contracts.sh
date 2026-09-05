#!/usr/bin/env bash
set -uo pipefail

# Fixture ID table (the printed order is the contract):
# schema-{json,root-valid,normal-valid,promote-only,root-forbidden,root-forbidden-each}, pins-{literal,network}, descriptor-{valid,variant,nested,stale,missing,duplicate},
# index-{vector,repeat,swapped}, manifest-{push,corrupt}, spdx-{regenerate,repeat,rescan,validate,naive,ids,roots,size},
# pkgset-{busybox-amd64,busybox-arm64,handcrafted and structural rejection rows}, dockerfile-* (all files below), materials-*,
# registry-{exists,valid-manifest,valid-index,all invalid body/header/transport rows},
# promotion-{removed,absent,equal,collision,mutable,mismatch}, verify-{success,empty,mismatch,fail-1..4}, signer-*, recovery-success,
# tags-{match,none,duplicate,empty,owner-type,user-route,org-route,api-fail,digest-fail}, decide-*, fault-hook, static-all.

if [[ $# -gt 1 ]]; then exit 6; fi
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool_dir=${1:-/tmp/tmpl01a-tools}
mkdir -p -- "$tool_dir" || exit 6
root_dir=$(mktemp -d "$tool_dir/tmpl01a-tree.XXXXXX") || exit 6
cp -a "$source_root/." "$root_dir/" || exit 6
fixture_dir="$root_dir/tests/fixtures"
work_dir=$(mktemp -d "$tool_dir/tmpl01a-contracts.XXXXXX") || exit 6
registry_pid=
mock_pid=
pass=0
total=0

cleanup() {
  if [[ -n "$mock_pid" ]]; then kill "$mock_pid" 2>/dev/null || true; wait "$mock_pid" 2>/dev/null || true; fi
  if [[ -n "$registry_pid" ]]; then kill "$registry_pid" 2>/dev/null || true; wait "$registry_pid" 2>/dev/null || true; fi
  rm -rf -- "$work_dir"
  rm -rf -- "$root_dir"
}
trap cleanup EXIT

check() {
  local id=$1
  shift
  total=$((total + 1))
  if ("$@") >"$work_dir/${id}.stdout" 2>"$work_dir/${id}.stderr"; then
    printf 'PASS %s\n' "$id"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$id"
    sed -n '1,40p' "$work_dir/${id}.stderr" >&2
  fi
}

expect_exit() {
  local expected=$1
  shift
  "$@"
  [[ $? -eq "$expected" ]]
}

fixture_pinned_tools() {
  "$root_dir/tools/fetch-pinned-tools.sh" "$tool_dir"
  [[ "$("$tool_dir/crane" version)" == 0.22.1 ]]
  "$tool_dir/oras" version | grep -q '1.3.4'
  "$tool_dir/syft" version | grep -q 'Version: *1.51.1'
  "$tool_dir/gh" --version | grep -q 'gh version 2.100.0'
  "$tool_dir/registry" --version | grep -q '3.1.1'
  PYTHONPATH="$tool_dir/pylib" python3 -c 'import importlib.metadata; assert importlib.metadata.version("spdx-tools") == "0.8.5"'
  [[ "$("$root_dir/tools/.tmpl01a-runtime/bash" --version | sed -n '1p')" == 'GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)' ]]
  [[ "$("$root_dir/tools/.tmpl01a-runtime/jq" --version)" == jq-1.7 ]]
  [[ "$("$root_dir/tools/.tmpl01a-runtime/python3" -I --version)" == 'Python 3.12.3' ]]
  [[ "$("$root_dir/tools/.tmpl01a-runtime/crane" version)" == 0.22.1 ]]
  "$root_dir/tools/.tmpl01a-runtime/gh" --version | grep -q 'gh version 2.100.0'
}

configure_fixture_runtime() {
  local runtime="$root_dir/tools/.tmpl01a-runtime" gh_sha crane_sha signer_sha attest_sha script
  install -m 0555 "$fixture_dir/bin/gh" "$runtime/gh"
  install -m 0555 "$fixture_dir/trusted-runtime/crane" "$runtime/crane"
  gh_sha=$(sha256sum "$runtime/gh"); gh_sha=${gh_sha%% *}
  crane_sha=$(sha256sum "$runtime/crane"); crane_sha=${crane_sha%% *}
  for script in check-signer.sh verify-attestations.sh verify-and-promote.sh verify-build-materials.sh; do
    sed -i -E "s/^    TRUST_GH_SHA256=.*/    TRUST_GH_SHA256=$gh_sha/" "$root_dir/tools/$script"
    sed -i -E "s/^    TRUST_CRANE_SHA256=.*/    TRUST_CRANE_SHA256=$crane_sha/" "$root_dir/tools/$script"
  done
  signer_sha=$(sha256sum "$root_dir/tools/check-signer.sh"); signer_sha=${signer_sha%% *}
  attest_sha=$(sha256sum "$root_dir/tools/verify-attestations.sh"); attest_sha=${attest_sha%% *}
  sed -i -E "s/^readonly CHECK_SIGNER_SHA256=.*/readonly CHECK_SIGNER_SHA256=$signer_sha/" \
    "$root_dir/tools/verify-and-promote.sh"
  sed -i -E "s/^readonly VERIFY_ATTESTATIONS_SHA256=.*/readonly VERIFY_ATTESTATIONS_SHA256=$attest_sha/" \
    "$root_dir/tools/verify-and-promote.sh"
}

fixture_pin_literals() {
  grep -q '8167316d2b4a57e10d44f8c8a3c75fea5f3ec1c71872760bb903e5e8e52e9ad6' "$root_dir/tools/fetch-pinned-tools.sh"
  grep -q '7c2d5865941be9d2e898f5b084e8d5422dd298dc5a29320ddb198fec304f59c4' "$fixture_dir/requirements-spdx.txt"
  grep -q 'x86_64) arch=amd64; crane_arch=x86_64' "$root_dir/tools/fetch-pinned-tools.sh"
  grep -q 'aarch64) arch=arm64; crane_arch=arm64' "$root_dir/tools/fetch-pinned-tools.sh"
}

fixture_schema_json() {
  jq -e . "$root_dir/contracts/publish-inputs.schema.json" "$root_dir/contracts/root-base.json" \
    "$root_dir/contracts/builders.json" "$root_dir/contracts/descriptor.schema.json" "$root_dir/contracts/signers.json" >/dev/null
}

fixture_schema_inputs() {
  jq -e '
    (.properties.inputs.required | index("base-digest") != null) and
    (.properties.inputs.required | index("bootstrap") != null) and
    .properties.inputs.properties["base-digest"].pattern == "^(|sha256:[0-9a-f]{64})$" and
    .properties.inputs.properties.bootstrap.default == false and
    .required == ["inputs","context"] and
    .properties.context.required == ["repository","ref","event_name"] and
    has("allOf")
  ' "$root_dir/contracts/publish-inputs.schema.json" >/dev/null
}

fixture_schema_accept() {
  local name=$1
  python3 "$root_dir/tools/validate-envelope.py" "$fixture_dir/envelopes/$name.json"
  python3 - "$root_dir/contracts/publish-inputs.schema.json" "$fixture_dir/envelopes/$name.json" <<'PY'
import json
import sys
from jsonschema import Draft202012Validator
schema = json.load(open(sys.argv[1], encoding="utf-8"))
instance = json.load(open(sys.argv[2], encoding="utf-8"))
Draft202012Validator.check_schema(schema)
Draft202012Validator(schema).validate(instance)
PY
}

fixture_schema_reject() {
  local name=$1
  python3 "$root_dir/tools/validate-envelope.py" "$fixture_dir/envelopes/$name.json" >/dev/null 2>&1
  [[ $? -eq 1 ]] || return 1
  python3 - "$root_dir/contracts/publish-inputs.schema.json" "$fixture_dir/envelopes/$name.json" <<'PY'
import json
import sys
from jsonschema import Draft202012Validator
schema = json.load(open(sys.argv[1], encoding="utf-8"))
instance = json.load(open(sys.argv[2], encoding="utf-8"))
sys.exit(0 if list(Draft202012Validator(schema).iter_errors(instance)) else 1)
PY
}

fixture_schema_root_forbidden_each() {
  local field value output
  local pairs=(
    'base-image=ghcr.io/nwarila/base'
    'base-digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'base-repo=NWarila/base'
    'base-signer-workflow=NWarila/base/.github/workflows/publish.yml'
    'base-signer-digest=2222222222222222222222222222222222222222'
    'builder-image=registry.access.redhat.com/ubi9/ubi-minimal'
    'builder-digest=sha256:463cae32c6f6f5594b11a5c22de275016bd8545ce58a6373388e8b24f13fc15c'
    'recover-digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    'recover-signer-digest=3333333333333333333333333333333333333333'
  )
  for pair in "${pairs[@]}"; do
    field=${pair%%=*}
    value=${pair#*=}
    output="$work_dir/root-forbidden-$field.json"
    jq --arg field "$field" --arg value "$value" '.inputs[$field] = $value' \
      "$fixture_dir/envelopes/root-valid.json" > "$output"
    python3 "$root_dir/tools/validate-envelope.py" "$output" >/dev/null 2>&1
    [[ $? -eq 1 ]] || return 1
  done
}

fixture_schema_downstream() {
  jq -e '.description | contains("retirement warning only after independent post-cutover verification of :latest succeeds") and contains("workflow, Dockerfile, deployment, and documentation references") and contains("Recovery is not a mitigation until A1")' \
    "$root_dir/contracts/publish-inputs.schema.json" >/dev/null
}

fixture_pin_network() {
  [[ "$(crane digest registry.access.redhat.com/ubi9/ubi-micro@sha256:35de56a9413112f1474e392ebc35e0cf6f0fb484c8e8877bbae59b513694b41f)" == \
      sha256:35de56a9413112f1474e392ebc35e0cf6f0fb484c8e8877bbae59b513694b41f ]]
  [[ "$(crane digest registry.access.redhat.com/ubi9/ubi-minimal@sha256:463cae32c6f6f5594b11a5c22de275016bd8545ce58a6373388e8b24f13fc15c)" == \
      sha256:463cae32c6f6f5594b11a5c22de275016bd8545ce58a6373388e8b24f13fc15c ]]
}

fixture_descriptor_valid() {
  INDEX_OUTPUT="$work_dir/descriptor-valid.index" "$root_dir/tools/index-build.sh" \
    "$fixture_dir/descriptors/amd64.json" "$fixture_dir/descriptors/arm64.json" >/dev/null
}

fixture_descriptor_fail() {
  local second=$1
  expect_exit 1 env INDEX_OUTPUT="$work_dir/descriptor-fail.index" "$root_dir/tools/index-build.sh" \
    "$fixture_dir/descriptors/amd64.json" "$fixture_dir/descriptors/$second" >/dev/null 2>&1
}

fixture_descriptor_missing() {
  expect_exit 1 env INDEX_OUTPUT="$work_dir/missing.index" "$root_dir/tools/index-build.sh" \
    "$fixture_dir/descriptors/amd64.json" "$fixture_dir/descriptors/amd64-second.json" >/dev/null 2>&1
}

fixture_index_vector() {
  INDEX_OUTPUT="$work_dir/index.json" "$root_dir/tools/index-build.sh" \
    "$fixture_dir/descriptors/amd64.json" "$fixture_dir/descriptors/arm64.json" > "$work_dir/index.digest"
  [[ "$(wc -c < "$work_dir/index.json")" -eq 491 ]]
  [[ "$(sha256sum "$work_dir/index.json" | cut -d' ' -f1)" == 240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b ]]
  [[ "$(tail -c 8 "$work_dir/index.json" | od -An -tx1 | tr -d ' \n')" == 6e7578227d7d5d7d ]]
  [[ "$(cat "$work_dir/index.digest")" == sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b ]]
}

fixture_index_repeat() {
  INDEX_OUTPUT="$work_dir/index-repeat.json" "$root_dir/tools/index-build.sh" \
    "$fixture_dir/descriptors/amd64.json" "$fixture_dir/descriptors/arm64.json" >/dev/null
  cmp "$work_dir/index.json" "$work_dir/index-repeat.json"
}

fixture_index_swapped() {
  expect_exit 1 env INDEX_OUTPUT="$work_dir/swapped.index" "$root_dir/tools/index-build.sh" \
    "$fixture_dir/descriptors/arm64.json" "$fixture_dir/descriptors/amd64.json" >/dev/null 2>&1
}

fixture_manifest_push() {
  REGISTRY_INSECURE=1 "$root_dir/tools/manifest-push.sh" localhost:5000/tmpl01a-fixture \
    sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    "$work_dir/index.json" application/vnd.oci.image.index.v1+json
}

fixture_manifest_corrupt() {
  cp "$work_dir/index.json" "$work_dir/index-corrupt.json"
  printf X | dd of="$work_dir/index-corrupt.json" bs=1 seek=20 conv=notrunc status=none
  if REGISTRY_INSECURE=1 "$root_dir/tools/manifest-push.sh" localhost:5000/tmpl01a-fixture \
    sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    "$work_dir/index-corrupt.json" application/vnd.oci.image.index.v1+json; then
    return 1
  fi
}

fixture_spdx_regenerate() {
  crane copy --insecure docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f \
    localhost:5000/tmpl01a-fixture:seed-amd64
  crane copy --insecure docker.io/library/busybox@sha256:bd44eb136a95dcc8dc58995e43abc40a413f2e8e3d4a2aae6bccbe94686acb05 \
    localhost:5000/tmpl01a-fixture:seed-arm64
  SYFT_REGISTRY_INSECURE_SKIP_TLS_VERIFY=true syft scan \
    registry:localhost:5000/tmpl01a-fixture@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f \
    -o spdx-json="$fixture_dir/spdx/spdx-amd64.json"
  SYFT_REGISTRY_INSECURE_SKIP_TLS_VERIFY=true syft scan \
    registry:localhost:5000/tmpl01a-fixture@sha256:bd44eb136a95dcc8dc58995e43abc40a413f2e8e3d4a2aae6bccbe94686acb05 \
    -o spdx-json="$fixture_dir/spdx/spdx-arm64.json"
  SYFT_REGISTRY_INSECURE_SKIP_TLS_VERIFY=true syft scan \
    registry:localhost:5000/tmpl01a-fixture@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f \
    -o spdx-json="$fixture_dir/spdx/spdx-amd64-rerun.json"
  SYFT_REGISTRY_INSECURE_SKIP_TLS_VERIFY=true syft scan \
    registry:localhost:5000/tmpl01a-fixture@sha256:bd44eb136a95dcc8dc58995e43abc40a413f2e8e3d4a2aae6bccbe94686acb05 \
    -o spdx-json="$fixture_dir/spdx/spdx-arm64-rerun.json"
  [[ "$(jq -r .documentNamespace "$fixture_dir/spdx/spdx-amd64.json")" != \
      "$(jq -r .documentNamespace "$fixture_dir/spdx/spdx-amd64-rerun.json")" ]]
  [[ "$(jq -r .creationInfo.created "$fixture_dir/spdx/spdx-amd64.json")" != \
      "$(jq -r .creationInfo.created "$fixture_dir/spdx/spdx-amd64-rerun.json")" ]]
}

merge_spdx() {
  local amd=$1 arm=$2 output=$3
  python3 "$root_dir/tools/spdx-merge.py" --created 2026-09-05T13:00:00Z \
    --index-digest sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    --source "linux/amd64,sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f,$amd" \
    --source "linux/arm64,sha256:bd44eb136a95dcc8dc58995e43abc40a413f2e8e3d4a2aae6bccbe94686acb05,$arm" > "$output"
}

fixture_spdx_repeat() {
  merge_spdx "$fixture_dir/spdx/spdx-amd64.json" "$fixture_dir/spdx/spdx-arm64.json" "$work_dir/merged.json"
  merge_spdx "$fixture_dir/spdx/spdx-amd64.json" "$fixture_dir/spdx/spdx-arm64.json" "$work_dir/merged-repeat.json"
  cmp "$work_dir/merged.json" "$work_dir/merged-repeat.json"
  [[ "$(sha256sum "$work_dir/merged.json" | cut -d' ' -f1)" == "$(cat "$fixture_dir/spdx/spdx-merged.sha256")" ]]
}

fixture_spdx_rescan() {
  merge_spdx "$fixture_dir/spdx/spdx-amd64-rerun.json" "$fixture_dir/spdx/spdx-arm64-rerun.json" "$work_dir/merged-rescan.json"
  cmp "$work_dir/merged.json" "$work_dir/merged-rescan.json"
}

fixture_spdx_validate() {
  PYTHONPATH="$tool_dir/pylib" python3 -m spdx_tools.spdx.clitools.pyspdxtools -i "$work_dir/merged.json"
}

fixture_spdx_naive() {
  jq -s '.[0] * {packages:(.[0].packages+.[1].packages),files:(.[0].files+.[1].files),relationships:(.[0].relationships+.[1].relationships)}' \
    "$fixture_dir/spdx/spdx-amd64.json" "$fixture_dir/spdx/spdx-arm64.json" > "$work_dir/naive.json"
  if PYTHONPATH="$tool_dir/pylib" python3 -m spdx_tools.spdx.clitools.pyspdxtools -i "$work_dir/naive.json"; then
    return 1
  fi
}

fixture_spdx_ids() {
  [[ -z "$(jq -r '[.packages[]?.SPDXID,.files[]?.SPDXID,.snippets[]?.SPDXID] | sort | group_by(.)[] | select(length>1) | .[0]' "$work_dir/merged.json")" ]]
}

fixture_spdx_roots() {
  [[ "$(jq '[.packages[] | select((.comment // "") | contains("TMPL01A child manifest"))] | length' "$work_dir/merged.json")" -eq 2 ]]
  [[ "$(jq '.documentDescribes | length' "$work_dir/merged.json")" -eq 2 ]]
}

fixture_spdx_size() { [[ "$(wc -c < "$work_dir/merged.json")" -lt 16777216 ]]; }

fixture_pkgset_busybox() {
  local arch=$1 dir="$work_dir/pkgset-busybox-$1"
  mkdir "$dir"
  (cd "$dir" && "$root_dir/tools/pkgset.sh" "$work_dir/merged.json" "$arch" > "hash")
  [[ ! -s "$dir/pkgset-${arch}.txt" ]]
  [[ "$(cat "$dir/hash")" == e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]]
}

fixture_pkgset_handcrafted() {
  local dir="$work_dir/pkgset-handcrafted"
  mkdir "$dir"
  (cd "$dir" && "$root_dir/tools/pkgset.sh" "$fixture_dir/pkgset/handcrafted.json" amd64 > "hash")
  cmp "$dir/pkgset-amd64.txt" "$fixture_dir/pkgset/handcrafted.expected"
  [[ "$(cat "$dir/hash")" == "$(cat "$fixture_dir/pkgset/handcrafted.sha256")" ]]
}

fixture_pkgset_fail() {
  local name=$1 dir="$work_dir/pkgset-$1"
  mkdir "$dir"
  printf 'preserve\n' > "$dir/pkgset-amd64.txt"
  (cd "$dir" && "$root_dir/tools/pkgset.sh" "$fixture_dir/pkgset/$name.json" amd64 >/dev/null 2>&1)
  [[ $? -eq 1 && "$(cat "$dir/pkgset-amd64.txt")" == preserve ]]
}

dockerfile_run() {
  python3 "$root_dir/tools/dockerfile-froms.py" "$@"
}

fixture_docker_root_pass() {
  local name=$1
  output=$(dockerfile_run --dockerfile "$fixture_dir/dockerfiles/$name.Dockerfile" --mode root --target runtime)
  jq -e \
    --arg base_image registry.access.redhat.com/ubi9/ubi-micro \
    --arg base_digest sha256:35de56a9413112f1474e392ebc35e0cf6f0fb484c8e8877bbae59b513694b41f \
    --arg builder_image registry.access.redhat.com/ubi9/ubi-minimal \
    --arg builder_digest sha256:463cae32c6f6f5594b11a5c22de275016bd8545ce58a6373388e8b24f13fc15c \
    '.ok == true and .build_args == {BASE_IMAGE:$base_image,BASE_DIGEST:$base_digest,BUILDER_IMAGE:$builder_image,BUILDER_DIGEST:$builder_digest}' <<<"$output" >/dev/null
}

fixture_docker_fail() {
  local name=$1 mode=${2:-root} expected=${3:-1}
  args=(--dockerfile "$fixture_dir/dockerfiles/$name.Dockerfile" --mode "$mode")
  if [[ "$mode" == root ]]; then args+=(--target runtime); fi
  dockerfile_run "${args[@]}" >/dev/null 2>&1
  [[ $? -eq "$expected" ]]
}

fixture_docker_normal_pass() {
  output=$(dockerfile_run --dockerfile "$fixture_dir/dockerfiles/conforming-normal.Dockerfile" --mode normal)
  jq -e '.ok == true and .needs_builder == true and ([.externals[] | select(.ref == "${BUILDER_IMAGE}@${BUILDER_DIGEST}")] | length) == 1' <<<"$output" >/dev/null
}

fixture_docker_wrong_target() {
  dockerfile_run --dockerfile "$fixture_dir/dockerfiles/conforming-root.Dockerfile" --mode root --target dev >/dev/null 2>&1
  [[ $? -eq 1 ]]
}

fixture_docker_no_target() {
  dockerfile_run --dockerfile "$fixture_dir/dockerfiles/conforming-root.Dockerfile" --mode root >/dev/null 2>&1
  [[ $? -eq 1 ]]
}

fixture_docker_policy_override() {
  dockerfile_run --dockerfile "$fixture_dir/dockerfiles/conforming-root.Dockerfile" --mode root --target runtime \
    --root-base "$work_dir/attacker-root.json" --builders "$work_dir/attacker-builders.json" >/dev/null 2>&1
  [[ $? -eq 2 ]]
}

fixture_docker_policy_mismatch() {
  local policy_tree="$work_dir/docker-policy-tree"
  mkdir -p "$policy_tree/tools" "$policy_tree/contracts"
  cp "$root_dir/tools/dockerfile-froms.py" "$policy_tree/tools/"
  cp "$root_dir/contracts/root-base.json" "$root_dir/contracts/builders.json" "$policy_tree/contracts/"
  jq '.base.digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    "$policy_tree/contracts/root-base.json" > "$policy_tree/contracts/root-base.changed"
  mv "$policy_tree/contracts/root-base.changed" "$policy_tree/contracts/root-base.json"
  python3 "$policy_tree/tools/dockerfile-froms.py" --dockerfile "$fixture_dir/dockerfiles/conforming-root.Dockerfile" \
    --mode root --target runtime >/dev/null
  [[ $? -eq 1 ]]
}

fixture_materials_pass() {
  local name=$1 mode=$2
  local args=(--provenance "$fixture_dir/provenance/$name.json" --mode "$mode")
  if [[ "$mode" == normal ]]; then
    args+=(--base-image ghcr.io/nwarila/base)
    args+=(--base-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
  fi
  output=$("$root_dir/tools/verify-build-materials.sh" "${args[@]}")
  [[ $? -eq 0 && -z "$output" ]]
}

fixture_materials_fail() {
  local name=$1 output
  output=$("$root_dir/tools/verify-build-materials.sh" \
    --provenance "$fixture_dir/provenance/$name.json" --mode root)
  [[ $? -eq 1 && -z "$output" ]]
}

fixture_registry_status() {
  local scenario=$1 bootstrap=$2 expected=$3
  output=$(REGISTRY_INSECURE=1 BOOTSTRAP="$bootstrap" "$root_dir/tools/registry-status.sh" \
    "127.0.0.1:5001/$scenario" latest)
  [[ $? -eq 0 && "$output" == "$expected" ]]
}

fixture_registry_200_reject() {
  local scenario=$1 output
  output=$(REGISTRY_INSECURE=1 BOOTSTRAP=false "$root_dir/tools/registry-status.sh" \
    "127.0.0.1:5001/$scenario" latest)
  [[ $? -eq 2 && -z "$output" ]]
}

verified_promote() {
  local promote_root=${1:-$root_dir}
  IMAGE="$PROMOTION_IMAGE" INDEX_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    CALLER_REPO=NWarila/example SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_ROLE=candidate RUN_ID="${PROMOTION_RUN_ID:-4242}" RUN_ATTEMPT=1 \
    PUBLISH_DATE="${PROMOTION_DATE:-20260905}" PROMOTE_STABLE="${PROMOTION_STABLE:-false}" DECISION=publish \
    "$promote_root/tools/verify-and-promote.sh"
}

make_gh_only() {
  GH_ONLY="$work_dir/gh-only-$1"
  mkdir "$GH_ONLY"
  ln -s "$fixture_dir/bin/gh" "$GH_ONLY/gh"
}

fixture_registry_reject() {
  local scenario=$1 state="$work_dir/probe-$1.state" spy="$work_dir/probe-$1.spy"
  printf '0\n' > "$state"
  : > "$spy"
  PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    REGISTRY_INSECURE=1 BOOTSTRAP=false CRANE_STUB_TAG_SPY="$spy" \
    CRANE_STUB_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    PROMOTION_IMAGE="127.0.0.1:5001/$scenario" PROMOTION_RUN_ID=1 verified_promote >/dev/null
  [[ $? -eq 2 && ! -s "$spy" && "$(cat "$state")" -eq 4 ]]
}

fixture_registry_transport() {
  local state="$work_dir/probe-transport.state" spy="$work_dir/probe-transport.spy"
  printf '0\n' > "$state"
  : > "$spy"
  PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    REGISTRY_INSECURE=1 BOOTSTRAP=false CRANE_STUB_TAG_SPY="$spy" \
    CRANE_STUB_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    PROMOTION_IMAGE=127.0.0.1:59999/repo PROMOTION_RUN_ID=1 verified_promote >/dev/null
  [[ $? -eq 2 && ! -s "$spy" ]]
}

fixture_registry_missing_auth() {
  output=$(env -u REGISTRY_USER -u REGISTRY_TOKEN REGISTRY_INSECURE=0 \
    "$root_dir/tools/registry-status.sh" ghcr.io/nwarila/example latest)
  [[ $? -eq 2 && -z "$output" ]]
}

fixture_promote_nonnumeric_run_id() {
  local state="$work_dir/nonnumeric-run.state" spy="$work_dir/nonnumeric-run.spy"
  printf '0\n' > "$state"
  : > "$spy"
  PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    CRANE_STUB_TAG_SPY="$spy" \
    IMAGE=ghcr.io/nwarila/example \
    INDEX_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    CALLER_REPO=NWarila/example \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 SIGNER_ROLE=candidate \
    RUN_ID=not-a-number RUN_ATTEMPT=1 PUBLISH_DATE=20260905 PROMOTE_STABLE=false DECISION=publish \
    "$root_dir/tools/verify-and-promote.sh" >/dev/null
  [[ $? -eq 6 && ! -s "$spy" && "$(cat "$state")" -eq 4 ]]
}

fixture_promotion_removed() {
  [[ ! -e "$source_root/tools/promote.sh" && ! -e "$root_dir/tools/promote.sh" ]]
}

fixture_promotion_direct_rejected() {
  local spy="$work_dir/direct-promote.spy"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" "$root_dir/tools/promote.sh" example.invalid/repo \
    sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa latest mutable >/dev/null 2>&1
  [[ $? -eq 127 && ! -s "$spy" ]]
}

fixture_promote_digest_probe_error() {
  local state="$work_dir/probe-digest.state" spy="$work_dir/probe-digest.spy"
  printf '0\n' > "$state"
  : > "$spy"
  PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    REGISTRY_INSECURE=1 BOOTSTRAP=false CRANE_STUB_TAG_SPY="$spy" CRANE_STUB_DIGEST_FAIL=1 \
    PROMOTION_IMAGE=127.0.0.1:5001/exists PROMOTION_RUN_ID=1 verified_promote >/dev/null
  [[ $? -eq 2 && ! -s "$spy" ]]
}

fixture_promote_absent() {
  local state="$work_dir/promote-absent.state"
  make_gh_only promote-absent
  printf '0\n' > "$state"
  output=$(PATH="$GH_ONLY:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    REGISTRY_INSECURE=1 BOOTSTRAP=false PROMOTION_IMAGE=localhost:5000/tmpl01a-fixture verified_promote)
  [[ "$output" == '{"decision":"publish","tags-written":["build-4242-1","20260905","latest"]}' ]]
}

fixture_promote_equal() {
  local state="$work_dir/promote-equal.state"
  make_gh_only promote-equal
  printf '0\n' > "$state"
  PATH="$GH_ONLY:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    REGISTRY_INSECURE=1 BOOTSTRAP=false PROMOTION_IMAGE=localhost:5000/tmpl01a-fixture verified_promote >/dev/null
}

fixture_promote_collision() {
  local state="$work_dir/promote-collision.state"
  make_gh_only promote-collision
  printf '0\n' > "$state"
  crane tag --insecure localhost:5000/tmpl01a-fixture@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f build-4343-1 >/dev/null
  PATH="$GH_ONLY:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    REGISTRY_INSECURE=1 BOOTSTRAP=false PROMOTION_IMAGE=localhost:5000/tmpl01a-fixture \
    PROMOTION_RUN_ID=4343 verified_promote >/dev/null
  [[ $? -eq 3 ]] || return 1
  [[ "$(crane digest --insecure localhost:5000/tmpl01a-fixture:build-4343-1)" == sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f ]]
}

fixture_promote_mutable() {
  local state="$work_dir/promote-mutable.state"
  make_gh_only promote-mutable
  printf '0\n' > "$state"
  crane tag --insecure localhost:5000/tmpl01a-fixture@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f 20260906 >/dev/null
  PATH="$GH_ONLY:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    REGISTRY_INSECURE=1 PROMOTION_IMAGE=localhost:5000/tmpl01a-fixture PROMOTION_RUN_ID=4444 \
    PROMOTION_DATE=20260906 verified_promote >/dev/null
  [[ "$(crane digest --insecure localhost:5000/tmpl01a-fixture:20260906)" == sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b ]]
}

fixture_promote_mismatch() {
  local state="$work_dir/mismatch.state" spy="$work_dir/mismatch.spy"
  printf '0\n' > "$state"
  : > "$spy"
  PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    REGISTRY_INSECURE=1 BOOTSTRAP=false CRANE_STUB_TAG_SPY="$spy" \
    CRANE_STUB_DIGEST=sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f \
    PROMOTION_IMAGE=127.0.0.1:5001/manifest-unknown PROMOTION_RUN_ID=7 verified_promote >/dev/null
  rc=$?
  [[ "$rc" -eq 4 && -s "$spy" ]]
}

fixture_verify() {
  local mode=$1 expected=$2 state="$work_dir/verify-$1.state" log="$work_dir/verify-$1.log"
  printf '0\n' > "$state"
  : > "$log"
  PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_MODE="$mode" GH_STUB_STATE="$state" GH_STUB_LOG="$log" \
    INDEX_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    IMAGE=ghcr.io/nwarila/example CALLER_REPO=NWarila/example \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 \
    "$root_dir/tools/verify-attestations.sh" >/dev/null
  rc=$?
  if [[ "$rc" -ne "$expected" ]]; then
    printf 'verify %s: rc=%s expected=%s calls=%s\n' "$mode" "$rc" "$expected" "$(cat "$state")" >&2
  fi
  [[ "$rc" -eq "$expected" ]]
  if [[ "$expected" -eq 0 ]]; then [[ "$(wc -l < "$log")" -eq 4 ]]; fi
}

fixture_verify_fail_position() {
  local position=$1 state="$work_dir/fail-$1.state" spy="$work_dir/fail-$1.spy"
  printf '0\n' > "$state"
  : > "$spy"
  PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_MODE="fail-$position" GH_STUB_STATE="$state" \
    CRANE_STUB_TAG_SPY="$spy" CRANE_STUB_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    IMAGE=ghcr.io/nwarila/example INDEX_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    CALLER_REPO=NWarila/example SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_ROLE=candidate RUN_ID=1 RUN_ATTEMPT=1 PUBLISH_DATE=20260905 PROMOTE_STABLE=false DECISION=publish \
    "$root_dir/tools/verify-and-promote.sh" >/dev/null
  [[ $? -ne 0 && ! -s "$spy" ]]
}

fixture_signer() {
  local role=$1 digest=$2 policy=$3 expected=$4 workflow=${5:-NWarila/ubi9-application-template/.github/workflows/publish.yaml}
  local policy_tree="$work_dir/signer-${role}-${digest}-${policy}" policy_sha
  install -d -m 0755 "$policy_tree" "$policy_tree/contracts"
  cp -a "$root_dir/tools" "$policy_tree/"
  install -m 0644 "$fixture_dir/$policy" "$policy_tree/contracts/signers.json"
  policy_sha=$(sha256sum "$policy_tree/contracts/signers.json"); policy_sha=${policy_sha%% *}
  sed -i -E "s/^readonly SIGNERS_SHA256=.*/readonly SIGNERS_SHA256=$policy_sha/" \
    "$policy_tree/tools/check-signer.sh"
  SIGNER_ROLE="$role" SIGNER_DIGEST="$digest" TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_WORKFLOW="$workflow" "$policy_tree/tools/check-signer.sh"
  [[ $? -eq "$expected" ]]
}

fixture_signer_env_override() {
  SIGNER_ROLE=recovery SIGNER_DIGEST=2222222222222222222222222222222222222222 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNERS_FILE="$fixture_dir/signers-allowed.json" "$root_dir/tools/check-signer.sh"
  [[ $? -eq 6 ]]
}

fixture_signer_premutation() {
  local state="$work_dir/signer-pre.state" spy="$work_dir/signer-pre.spy"
  printf '0\n' > "$state"
  : > "$spy"
  PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" CRANE_STUB_TAG_SPY="$spy" \
    IMAGE=ghcr.io/nwarila/example INDEX_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    CALLER_REPO=NWarila/example SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNER_DIGEST=2222222222222222222222222222222222222222 TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_ROLE=recovery SIGNERS_FILE="$fixture_dir/signers-allowed.json" RUN_ID=2 RUN_ATTEMPT=1 \
    PUBLISH_DATE=20260905 PROMOTE_STABLE=false DECISION=recovered "$root_dir/tools/verify-and-promote.sh" >/dev/null
  [[ $? -eq 6 && ! -s "$spy" && "$(cat "$state")" -eq 0 ]]
}

fixture_signer_bad_env() {
  SIGNER_WORKFLOW='' SIGNER_DIGEST=1111111111111111111111111111111111111111 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 SIGNER_ROLE=current \
    "$root_dir/tools/check-signer.sh"
  [[ $? -eq 6 ]]
}

fixture_signer_symlink_escape() {
  local policy_tree="$work_dir/signer-symlink-tree"
  local outside="$work_dir/outside-signers.json" spy="$work_dir/symlink-jq.spy"
  install -d -m 0755 "$policy_tree" "$policy_tree/contracts"
  cp -a "$root_dir/tools" "$policy_tree/"
  cp "$fixture_dir/signers-allowed-out-of-tree.json" "$outside"
  ln -s "$outside" "$policy_tree/contracts/signers.json"
  : > "$spy"
  PATH="$fixture_dir/signer-bin:$PATH" JQ_STUB_SPY="$spy" \
    SIGNER_ROLE=current SIGNER_DIGEST=2222222222222222222222222222222222222222 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    "$policy_tree/tools/check-signer.sh"
  [[ $? -eq 6 && ! -s "$spy" ]]
}

copy_trust_case() {
  local name=$1
  case_root="$work_dir/trust-$name"
  install -d -m 0755 "$case_root"
  cp -a "$root_dir/tools" "$case_root/"
  cp -a "$root_dir/contracts" "$case_root/"
}

fixture_hostile_shell_runtime() {
  local name=$1 rc
  local hostile="$work_dir/hostile-$name" spy="$work_dir/hostile-$name.spy"
  local tag_spy="$work_dir/hostile-$name.tags"
  copy_trust_case "hostile-$name"
  mkdir "$hostile"
  cp "$fixture_dir/hostile-bin/$name" "$hostile/$name"
  install -m 0555 "$fixture_dir/hostile-bin/$name" "$case_root/tools/.tmpl01a-runtime/$name"
  : > "$spy"
  : > "$tag_spy"
  if PATH="$hostile:$PATH" HOSTILE_RUNTIME_SPY="$spy" CRANE_STUB_TAG_SPY="$tag_spy" \
    PROMOTION_IMAGE=ghcr.io/nwarila/example \
    verified_promote "$case_root" >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" -ne 6 || -s "$spy" || -s "$tag_spy" ]]; then
    printf 'hostile %s: rc=%s runtime-spy=%s tag-spy=%s\n' "$name" "$rc" \
      "$(wc -c < "$spy")" "$(wc -c < "$tag_spy")" >&2
    return 1
  fi
}

fixture_hostile_python_runtime() {
  local rc hostile="$work_dir/hostile-python3" spy="$work_dir/hostile-python3.spy"
  local tag_spy="$work_dir/hostile-python3.tags"
  copy_trust_case hostile-python3
  mkdir "$hostile"
  cp "$fixture_dir/hostile-bin/python3" "$hostile/python3"
  install -m 0555 "$fixture_dir/hostile-bin/python3" "$case_root/tools/.tmpl01a-runtime/python3"
  : > "$spy"
  : > "$tag_spy"
  PATH="$hostile:$PATH" HOSTILE_RUNTIME_SPY="$spy" CRANE_STUB_TAG_SPY="$tag_spy" \
    "$case_root/tools/verify-build-materials.sh" \
      --provenance "$fixture_dir/provenance/extra-alpine.json" --mode root >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 1 && ! -s "$spy" && ! -s "$tag_spy" ]]
}

fixture_hostile_pythonpath() {
  local rc spy="$work_dir/hostile-pythonpath.spy" tag_spy="$work_dir/hostile-pythonpath.tags"
  : > "$spy"
  : > "$tag_spy"
  PYTHONPATH="$fixture_dir/pythonpath" HOSTILE_RUNTIME_SPY="$spy" CRANE_STUB_TAG_SPY="$tag_spy" \
    "$root_dir/tools/verify-build-materials.sh" \
      --provenance "$fixture_dir/provenance/extra-alpine.json" --mode root >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 1 && ! -s "$spy" && ! -s "$tag_spy" ]]
}

fixture_hardlink_check_signer() {
  local rc outside="$work_dir/hardlink-check-signer.sh" spy="$work_dir/hardlink-check-signer.tags"
  copy_trust_case hardlink-check-signer
  ln "$case_root/tools/check-signer.sh" "$outside"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" SIGNER_ROLE=current \
    SIGNER_DIGEST=2222222222222222222222222222222222222222 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    "$outside" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 6 && ! -s "$spy" ]]
}

fixture_hardlink_verify_attestations() {
  local rc outside="$work_dir/hardlink-verify-attestations.sh" spy="$work_dir/hardlink-verify-attestations.tags"
  copy_trust_case hardlink-verify-attestations
  ln "$case_root/tools/verify-attestations.sh" "$outside"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" IMAGE=ghcr.io/nwarila/example \
    INDEX_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    CALLER_REPO=NWarila/example \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 \
    "$outside" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 6 && ! -s "$spy" ]]
}

fixture_hardlink_verify_and_promote() {
  local rc outside="$work_dir/hardlink-verify-and-promote.sh" spy="$work_dir/hardlink-verify-and-promote.tags"
  copy_trust_case hardlink-verify-and-promote
  ln "$case_root/tools/verify-and-promote.sh" "$outside"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" IMAGE=ghcr.io/nwarila/example \
    INDEX_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    CALLER_REPO=NWarila/example \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 SIGNER_ROLE=candidate \
    RUN_ID=1 RUN_ATTEMPT=1 PUBLISH_DATE=20260905 PROMOTE_STABLE=false DECISION=publish \
    "$outside" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 6 && ! -s "$spy" ]]
}

fixture_hardlink_materials_tool() {
  local rc outside="$work_dir/hardlink-verify-build-materials.py" spy="$work_dir/hardlink-materials-tool.tags"
  copy_trust_case hardlink-materials-tool
  ln "$case_root/tools/verify-build-materials.py" "$outside"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" "$case_root/tools/.tmpl01a-runtime/python3" -I "$outside" \
    --provenance "$fixture_dir/provenance/conforming-root.json" --mode root >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 1 && ! -s "$spy" ]]
}

fixture_hardlink_signers_policy() {
  local rc outside="$work_dir/hardlink-signers.json" spy="$work_dir/hardlink-signers.tags"
  copy_trust_case hardlink-signers
  cp "$fixture_dir/signers-allowed-out-of-tree.json" "$outside"
  rm "$case_root/contracts/signers.json"
  ln "$outside" "$case_root/contracts/signers.json"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" SIGNER_ROLE=current \
    SIGNER_DIGEST=2222222222222222222222222222222222222222 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    "$case_root/tools/check-signer.sh" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 6 && ! -s "$spy" ]]
}

fixture_hardlink_root_base_policy() {
  local rc outside="$work_dir/hardlink-root-base.json" spy="$work_dir/hardlink-root-base.tags"
  copy_trust_case hardlink-root-base
  cp "$fixture_dir/root-base-mirror.json" "$outside"
  rm "$case_root/contracts/root-base.json"
  ln "$outside" "$case_root/contracts/root-base.json"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" "$case_root/tools/verify-build-materials.sh" \
    --provenance "$fixture_dir/provenance/conforming-root-mirror.json" --mode root >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 1 && ! -s "$spy" ]]
}

fixture_hardlink_builders_policy() {
  local rc outside="$work_dir/hardlink-builders.json" spy="$work_dir/hardlink-builders.tags"
  copy_trust_case hardlink-builders
  cp "$case_root/contracts/builders.json" "$outside"
  rm "$case_root/contracts/builders.json"
  ln "$outside" "$case_root/contracts/builders.json"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" "$case_root/tools/verify-build-materials.sh" \
    --provenance "$fixture_dir/provenance/conforming-normal.json" --mode normal \
    --base-image ghcr.io/nwarila/base \
    --base-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 1 && ! -s "$spy" ]]
}

fixture_trust_directory_symlink() {
  local linked_root="$work_dir/trust-directory-link" spy="$work_dir/trust-directory-link.tags"
  ln -s "$root_dir" "$linked_root"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" SIGNER_ROLE=candidate \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    "$linked_root/tools/check-signer.sh" >/dev/null
  CRANE_STUB_TAG_SPY="$spy" "$linked_root/tools/verify-build-materials.sh" \
    --provenance "$fixture_dir/provenance/conforming-root.json" --mode root >/dev/null
  [[ ! -s "$spy" ]]
}

fixture_open_once_runtime_swap() {
  local rc state="$work_dir/open-once-runtime.state" log="$work_dir/open-once-runtime.log"
  local fd_log="$work_dir/open-once-runtime.fd-log" marker="$work_dir/open-once-runtime.marker"
  local replacement="$work_dir/open-once-runtime.replacement" hostile_spy="$work_dir/open-once-runtime.hostile"
  copy_trust_case open-once-runtime-swap
  printf '0\n' > "$state"
  : > "$log"
  : > "$fd_log"
  : > "$hostile_spy"
  install -m 0555 "$fixture_dir/hostile-bin/gh" "$replacement"
  GH_STUB_MODE=success GH_STUB_STATE="$state" GH_STUB_LOG="$log" GH_STUB_FD_LOG="$fd_log" \
    GH_STUB_SWAP_TARGET="$case_root/tools/.tmpl01a-runtime/gh" \
    GH_STUB_SWAP_REPLACEMENT="$replacement" GH_STUB_SWAP_MARKER="$marker" \
    HOSTILE_RUNTIME_SPY="$hostile_spy" \
    INDEX_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    IMAGE=ghcr.io/nwarila/example CALLER_REPO=NWarila/example \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 \
    "$case_root/tools/verify-attestations.sh" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -ne 0 || "$(cat "$state")" -ne 4 || "$(wc -l < "$log")" -ne 4 ]]; then
    printf 'open-once runtime: rc=%s calls=%s log=%s fd-log=%s hostile=%s\n' "$rc" \
      "$(cat "$state")" "$(wc -l < "$log")" "$(wc -l < "$fd_log")" "$(wc -c < "$hostile_spy")" >&2
    return 1
  fi
  [[ "$(grep -Ec '^/proc/[0-9]+/fd/[0-9]+$' "$fd_log")" -eq 4 ]] || return 1
  [[ -e "$marker" && ! -e "$replacement" && ! -s "$hostile_spy" ]]
}

fixture_signer_single_snapshot() {
  local rc policy_tree="$work_dir/signer-single-snapshot" policy_sha jq_sha
  local log="$work_dir/signer-single-snapshot.log" marker="$work_dir/signer-single-snapshot.marker"
  local replacement="$work_dir/signer-single-snapshot.replacement" spy="$work_dir/signer-single-snapshot.tags"
  install -d -m 0755 "$policy_tree" "$policy_tree/contracts"
  cp -a "$root_dir/tools" "$policy_tree/"
  install -m 0644 "$fixture_dir/signers-allowed.json" "$policy_tree/contracts/signers.json"
  install -m 0644 "$fixture_dir/signers-revoked.json" "$replacement"
  install -m 0555 "$fixture_dir/trusted-runtime/jq-snapshot" \
    "$policy_tree/tools/.tmpl01a-runtime/jq"
  policy_sha=$(sha256sum "$policy_tree/contracts/signers.json"); policy_sha=${policy_sha%% *}
  jq_sha=$(sha256sum "$policy_tree/tools/.tmpl01a-runtime/jq"); jq_sha=${jq_sha%% *}
  sed -i -E "s/^readonly SIGNERS_SHA256=.*/readonly SIGNERS_SHA256=$policy_sha/" \
    "$policy_tree/tools/check-signer.sh"
  sed -i -E "s/^    TRUST_JQ_SHA256=.*/    TRUST_JQ_SHA256=$jq_sha/" \
    "$policy_tree/tools/check-signer.sh"
  : > "$log"
  : > "$spy"
  JQ_SNAPSHOT_LOG="$log" JQ_SNAPSHOT_MARKER="$marker" \
    JQ_SNAPSHOT_REPLACEMENT="$replacement" JQ_SNAPSHOT_TARGET="$policy_tree/contracts/signers.json" \
    CRANE_STUB_TAG_SPY="$spy" SIGNER_ROLE=current \
    SIGNER_DIGEST=2222222222222222222222222222222222222222 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    "$policy_tree/tools/check-signer.sh" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 0 && "$(wc -l < "$log")" -eq 1 && -e "$marker" && ! -e "$replacement" ]] || return 1
  [[ "$(cat "$log")" == /proc/*/fd/* && ! -s "$spy" ]]
}

fixture_group_writable_trust_file() {
  local rc spy="$work_dir/group-writable-file.tags"
  copy_trust_case group-writable-file
  chmod 0664 "$case_root/contracts/signers.json"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" SIGNER_ROLE=candidate \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 \
    TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    "$case_root/tools/check-signer.sh" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 6 && ! -s "$spy" ]]
}

fixture_group_writable_parent_dir() {
  local rc spy="$work_dir/group-writable-parent.tags"
  copy_trust_case group-writable-parent
  chmod 0775 "$case_root/contracts"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" "$case_root/tools/verify-build-materials.sh" \
    --provenance "$fixture_dir/provenance/conforming-root.json" --mode root >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 1 && ! -s "$spy" ]]
}

fixture_world_writable_runtime_dir() {
  local rc spy="$work_dir/world-writable-runtime.tags"
  copy_trust_case world-writable-runtime
  chmod 0777 "$case_root/tools/.tmpl01a-runtime"
  : > "$spy"
  CRANE_STUB_TAG_SPY="$spy" PROMOTION_IMAGE=ghcr.io/nwarila/example \
    verified_promote "$case_root" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq 6 && ! -s "$spy" ]]
}

fixture_recovery_success() {
  local state="$work_dir/recovery.state" gh_only="$work_dir/gh-only"
  mkdir "$gh_only"
  ln -s "$fixture_dir/bin/gh" "$gh_only/gh"
  printf '0\n' > "$state"
  output=$(PATH="$gh_only:$tool_dir:$PATH" GH_STUB_MODE=success GH_STUB_STATE="$state" \
    REGISTRY_INSECURE=1 BOOTSTRAP=false IMAGE=localhost:5000/tmpl01a-fixture \
    INDEX_DIGEST=sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b \
    CALLER_REPO=NWarila/example SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    SIGNER_DIGEST=1111111111111111111111111111111111111111 TEMPLATE_REF=1111111111111111111111111111111111111111 \
    SIGNER_ROLE=recovery RUN_ID=9000 RUN_ATTEMPT=2 PUBLISH_DATE=20260905 PROMOTE_STABLE=true DECISION=recovered \
    "$root_dir/tools/verify-and-promote.sh")
  [[ "$output" == '{"decision":"recovered","tags-written":["build-9000-2","20260905","stable","latest"]}' ]]
  [[ "$(cat "$state")" -eq 4 ]]
  for tag in build-9000-2 20260905 stable latest; do
    [[ "$(crane digest --insecure "localhost:5000/tmpl01a-fixture:$tag")" == sha256:240503f853cc81f3a30a7a6661a6effe236b9145bcccbafe76242b15e9cdbe0b ]]
  done
}

fixture_tags() {
  local variant=$1
  local tags="$work_dir/tags-$variant" map="$work_dir/map-$variant" ghlog="$work_dir/gh-$variant.log" cranelog="$work_dir/crane-$variant.log"
  : > "$ghlog"; : > "$cranelog"
  case "$variant" in
    match|duplicate|user-route)
      printf 'z\na\nz\n' > "$tags"
      printf 'ghcr.io/nwarila/img:a\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nghcr.io/nwarila/img:z\tsha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$map"
      output=$(PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_TAGS_FILE="$tags" GH_STUB_LOG="$ghlog" \
        CRANE_STUB_DIGEST_MAP="$map" CRANE_STUB_LOG="$cranelog" "$root_dir/tools/tags-resolving-to.sh" \
        NWarila User img sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
      rc=$?
      [[ "$rc" -eq 1 ]]
      [[ "$output" == $'a\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nz\tsha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]]
      [[ "$(grep -c 'digest ghcr.io/nwarila/img:z' "$cranelog")" -eq 1 ]]
      if [[ "$variant" == user-route ]]; then grep -q '/users/NWarila/packages' "$ghlog"; fi
      ;;
    none)
      printf 'a\n' > "$tags"
      printf 'ghcr.io/nwarila/img:a\tsha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$map"
      if ! PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_TAGS_FILE="$tags" CRANE_STUB_DIGEST_MAP="$map" \
        "$root_dir/tools/tags-resolving-to.sh" NWarila User img sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null; then
        return 1
      fi
      ;;
    empty)
      printf '\n' > "$tags"; : > "$map"
      PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_TAGS_FILE="$tags" CRANE_STUB_DIGEST_MAP="$map" \
        "$root_dir/tools/tags-resolving-to.sh" NWarila User img sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null
      [[ $? -eq 2 ]]
      ;;
    owner-type)
      PATH="$fixture_dir/bin:$tool_dir:$PATH" "$root_dir/tools/tags-resolving-to.sh" NWarila Team img \
        sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null
      [[ $? -eq 2 ]]
      ;;
    org-route)
      : > "$tags"; : > "$map"
      if ! PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_TAGS_FILE="$tags" GH_STUB_LOG="$ghlog" CRANE_STUB_DIGEST_MAP="$map" \
        "$root_dir/tools/tags-resolving-to.sh" NWarila Organization img sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null; then
        return 1
      fi
      grep -q '/orgs/NWarila/packages' "$ghlog"
      ;;
    api-fail)
      PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_API_FAIL=1 "$root_dir/tools/tags-resolving-to.sh" NWarila User img \
        sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null
      [[ $? -eq 2 ]]
      ;;
    digest-fail)
      printf 'a\n' > "$tags"
      PATH="$fixture_dir/bin:$tool_dir:$PATH" GH_STUB_TAGS_FILE="$tags" CRANE_STUB_DIGEST_FAIL=1 \
        "$root_dir/tools/tags-resolving-to.sh" NWarila User img sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null
      [[ $? -eq 2 ]]
      ;;
  esac
}

fixture_decide_expect() {
  local scenario=$1 candidate=$2 git_sha=$3 base_digest=$4 force=$5 mode=$6 index=$7 expected=$8
  local state="$work_dir/decide-${scenario}-${candidate}.state"
  printf '0\n' > "$state"
  output=$(PATH="$fixture_dir/bin:$tool_dir:$PATH" REGISTRY_INSECURE=1 \
    IMAGE="127.0.0.1:5001/$scenario" INDEX_DIGEST=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
    CANDIDATE_SBOM="$fixture_dir/decide/$candidate" GIT_SHA="$git_sha" BASE_DIGEST="$base_digest" \
    CALLER_REPO=NWarila/example SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    CURRENT_SIGNER_DIGEST='' TEMPLATE_REF=1111111111111111111111111111111111111111 FORCE="$force" BOOTSTRAP=false \
    SIGNERS_FILE="$root_dir/contracts/signers.json" GH_STUB_MODE="$mode" GH_STUB_STATE="$state" \
    GH_STUB_SPDX_FILE="$fixture_dir/decide/current-sbom.json" \
    CRANE_STUB_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
    CRANE_STUB_INDEX="$fixture_dir/decide/$index" CRANE_STUB_CONFIG="$fixture_dir/decide/current-config.json" \
    "$root_dir/tools/decide.sh")
  [[ $? -eq 0 && "$output" == "$expected" ]]
}

fixture_decide_exit() {
  local mode=$1 index=$2 expected=$3 state="$work_dir/decide-exit-$1-$2.state"
  printf '0\n' > "$state"
  PATH="$fixture_dir/bin:$tool_dir:$PATH" REGISTRY_INSECURE=1 IMAGE=127.0.0.1:5001/exists \
    INDEX_DIGEST=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
    CANDIDATE_SBOM="$fixture_dir/decide/candidate-same.json" GIT_SHA=1111111111111111111111111111111111111111 \
    BASE_DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
    CALLER_REPO=NWarila/example SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    CURRENT_SIGNER_DIGEST='' TEMPLATE_REF=1111111111111111111111111111111111111111 FORCE=false BOOTSTRAP=false \
    SIGNERS_FILE="$root_dir/contracts/signers.json" GH_STUB_MODE="$mode" GH_STUB_STATE="$state" \
    GH_STUB_SPDX_FILE="$fixture_dir/decide/current-sbom.json" \
    CRANE_STUB_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
    CRANE_STUB_INDEX="$fixture_dir/decide/$index" CRANE_STUB_CONFIG="$fixture_dir/decide/current-config.json" \
    "$root_dir/tools/decide.sh" >/dev/null
  [[ $? -eq "$expected" ]]
}

fixture_decide_registry_error() {
  PATH="$fixture_dir/bin:$tool_dir:$PATH" REGISTRY_INSECURE=1 IMAGE=127.0.0.1:5001/unavailable \
    INDEX_DIGEST=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
    CANDIDATE_SBOM="$fixture_dir/decide/candidate-same.json" GIT_SHA=1111111111111111111111111111111111111111 \
    BASE_DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
    CALLER_REPO=NWarila/example SIGNER_WORKFLOW=NWarila/ubi9-application-template/.github/workflows/publish.yaml \
    CURRENT_SIGNER_DIGEST='' TEMPLATE_REF=1111111111111111111111111111111111111111 FORCE=false BOOTSTRAP=false \
    SIGNERS_FILE="$root_dir/contracts/signers.json" "$root_dir/tools/decide.sh" >/dev/null
  [[ $? -eq 2 ]]
}

fixture_fault_hook() {
  output=$("$root_dir/tests/fault-after-attest.sh" 2>&1)
  [[ $? -eq 1 && "$output" == 'TMPL01A Gate 1 forced fault' ]]
}

fixture_static_all() {
  bash -n "$root_dir"/tools/*.sh "$root_dir"/tests/*.sh "$fixture_dir"/bin/* "$fixture_dir"/signer-bin/* \
    "$fixture_dir"/hostile-bin/* "$fixture_dir"/trusted-runtime/*
  shellcheck --shell=bash "$root_dir"/tools/*.sh "$root_dir"/tests/*.sh "$fixture_dir"/bin/* \
    "$fixture_dir"/signer-bin/* "$fixture_dir"/hostile-bin/* "$fixture_dir"/trusted-runtime/*
  PYTHONPYCACHEPREFIX="$work_dir/pycache" python3 -m py_compile "$root_dir"/tools/*.py "$fixture_dir"/*.py \
    "$fixture_dir"/pythonpath/*.py
  [[ "$(sha256sum "$root_dir/tools/spdx-merge.py" | cut -d' ' -f1)" == 026ba8fb000dc5b611d8b324e38b75738724ba2722dd2f725f3ac29c5df1cf0a ]]
  [[ -f "$root_dir/contracts/signers.json" && ! -L "$root_dir/contracts/signers.json" ]]
  local trust_path
  for trust_path in \
    "$root_dir/tools/check-signer.sh" \
    "$root_dir/tools/verify-attestations.sh" \
    "$root_dir/tools/verify-and-promote.sh" \
    "$root_dir/tools/verify-build-materials.sh" \
    "$root_dir/tools/verify-build-materials.py" \
    "$root_dir/contracts/signers.json" \
    "$root_dir/contracts/root-base.json" \
    "$root_dir/contracts/builders.json"; do
    [[ -f "$trust_path" && ! -L "$trust_path" && "$(stat -Lc '%h' "$trust_path")" == 1 ]] || return 1
    (( (8#$(stat -Lc '%a' "$trust_path") & 0022) == 0 )) || return 1
  done
  local trust_dir
  for trust_dir in \
    "$root_dir" \
    "$root_dir/tools" \
    "$root_dir/tools/.tmpl01a-runtime" \
    "$root_dir/contracts"; do
    [[ -d "$trust_dir" && ! -L "$trust_dir" ]] || return 1
    (( (8#$(stat -Lc '%a' "$trust_dir") & 0022) == 0 )) || return 1
  done
  for trust_path in "$root_dir/tools/.tmpl01a-runtime"/{bash,jq,python3,gh,crane}; do
    [[ -f "$trust_path" && ! -L "$trust_path" && "$(stat -Lc '%h' "$trust_path")" == 1 ]] || return 1
    (( (8#$(stat -Lc '%a' "$trust_path") & 0022) == 0 )) || return 1
  done
  python3 - "$root_dir" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
hits = []
for directory in (root / "contracts", root / "tools"):
    for path in directory.rglob("*"):
        if not path.is_file():
            continue
        if ".tmpl01a-runtime" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")
        for pattern, kind in (
            (r'"\$TRUST_CRANE"\s+tag\b', "trusted crane tag"),
            (r"\boras\s+tag\b", "oras tag"),
        ):
            if re.search(pattern, text, re.IGNORECASE):
                hits.append((path.relative_to(root).as_posix(), kind))
        if re.search(r"\bPUT\b", text, re.IGNORECASE) and "/manifests/" in text:
            hits.append((path.relative_to(root).as_posix(), "manifest PUT"))
if hits != [("tools/verify-and-promote.sh", "trusted crane tag")]:
    raise SystemExit(f"unexpected tag-writing commands: {hits}")
PY
}

check pinned-tools fixture_pinned_tools
configure_fixture_runtime || exit 6
export TMPL01A_REAL_CRANE="$tool_dir/crane"
export PATH="$tool_dir:$PATH"
check pins-literal fixture_pin_literals
check schema-json fixture_schema_json
check schema-inputs fixture_schema_inputs
check schema-root-valid fixture_schema_accept root-valid
check schema-normal-valid fixture_schema_accept normal-valid
check schema-promote-only fixture_schema_accept promote-only-valid
check schema-root-forbidden fixture_schema_reject root-forbidden-overrides
check schema-root-pull-request fixture_schema_reject root-pull-request
check schema-root-homoglyph fixture_schema_reject root-homoglyph
check schema-context-extra-property fixture_schema_reject root-context-extra-property
check schema-root-extra-property fixture_schema_reject root-extra-property
check schema-root-forbidden-each fixture_schema_root_forbidden_each
check schema-downstream-warning fixture_schema_downstream
check pins-network fixture_pin_network

registry_data="$work_dir/registry-data"
mkdir "$registry_data"
sed "s#/tmp/tmpl01a-registry-placeholder#$registry_data#" "$fixture_dir/registry-config.yml" > "$work_dir/registry.yml"
"$tool_dir/registry" serve "$work_dir/registry.yml" >"$work_dir/registry.log" 2>&1 &
registry_pid=$!
python3 "$fixture_dir/mock-registry.py" --port 5001 >"$work_dir/mock.log" 2>&1 &
mock_pid=$!
for _ in {1..50}; do curl -fsS http://127.0.0.1:5000/v2/ >/dev/null 2>&1 && break; sleep 0.1; done
for _ in {1..50}; do curl -sS http://127.0.0.1:5001/v2/exists/manifests/latest >/dev/null 2>&1 && break; sleep 0.1; done
check local-registry-ready curl -fsS http://127.0.0.1:5000/v2/
check mock-registry-ready fixture_registry_status exists false $'exists\t-'

check descriptor-valid fixture_descriptor_valid
check descriptor-variant fixture_descriptor_fail arm64-variant.json
check descriptor-nested fixture_descriptor_fail arm64-nested-index.json
check descriptor-stale fixture_descriptor_fail arm64-stale.json
check descriptor-missing fixture_descriptor_missing
check descriptor-duplicate fixture_descriptor_missing
check index-vector fixture_index_vector
check index-repeat fixture_index_repeat
check index-swapped fixture_index_swapped
check spdx-regenerate fixture_spdx_regenerate
check manifest-push fixture_manifest_push
check manifest-corrupt fixture_manifest_corrupt
check spdx-repeat fixture_spdx_repeat
check spdx-rescan fixture_spdx_rescan
check spdx-validate fixture_spdx_validate
check spdx-naive fixture_spdx_naive
check spdx-ids fixture_spdx_ids
check spdx-roots fixture_spdx_roots
check spdx-size fixture_spdx_size
check pkgset-busybox-amd64 fixture_pkgset_busybox amd64
check pkgset-busybox-arm64 fixture_pkgset_busybox arm64
check pkgset-handcrafted fixture_pkgset_handcrafted
check pkgset-two fixture_pkgset_fail two-rpm
check pkgset-malformed fixture_pkgset_fail malformed-rpm
check pkgset-tab fixture_pkgset_fail control-tab
check pkgset-lf fixture_pkgset_fail control-lf
check pkgset-cr fixture_pkgset_fail control-cr
check pkgset-del fixture_pkgset_fail control-del
check pkgset-percent-00 fixture_pkgset_fail percent-00
check pkgset-percent-0a fixture_pkgset_fail percent-0a
check pkgset-malformed-percent fixture_pkgset_fail malformed-percent
check pkgset-missing-root fixture_pkgset_fail missing-root
check pkgset-unknown-root fixture_pkgset_fail unknown-root
check pkgset-duplicate-root fixture_pkgset_fail duplicate-root
check pkgset-percent-slash fixture_pkgset_fail percent-slash
check pkgset-multiple-at fixture_pkgset_fail multiple-at
check pkgset-dual-arch-root fixture_pkgset_fail dual-arch-root
check pkgset-percent-at fixture_pkgset_fail percent-at
check pkgset-percent-question fixture_pkgset_fail percent-question
check pkgset-percent-hash fixture_pkgset_fail percent-hash
check pkgset-zero-at fixture_pkgset_fail zero-at
check pkgset-empty-version fixture_pkgset_fail empty-version
check pkgset-malformed-qualifier fixture_pkgset_fail malformed-qualifier

check dockerfile-conforming-root fixture_docker_root_pass conforming-root
check dockerfile-continuation fixture_docker_root_pass continuation
check dockerfile-conforming-normal fixture_docker_normal_pass
check dockerfile-live-base fixture_docker_fail live-base-8e9043a
check dockerfile-comment-smuggle fixture_docker_fail comment-smuggle
check dockerfile-arg-default fixture_docker_fail arg-default
check dockerfile-unbraced fixture_docker_fail unbraced
check dockerfile-scratch fixture_docker_fail scratch
check dockerfile-builder-only-root fixture_docker_fail builder-only-root
check dockerfile-base-only-root fixture_docker_fail base-only-root
check dockerfile-duplicate-arg fixture_docker_fail duplicate-arg root 6
check dockerfile-default-shadow fixture_docker_fail default-shadowed-arg root 6
check dockerfile-duplicate-alias fixture_docker_fail duplicate-alias root 6
check dockerfile-second-builder fixture_docker_fail second-normal-builder normal 1
check dockerfile-alternate-escape fixture_docker_fail alternate-escape root 6
check dockerfile-heredoc fixture_docker_fail heredoc root 6
check dockerfile-unsupported-flag fixture_docker_fail unsupported-from-flag root 6
check dockerfile-trailing-tokens fixture_docker_fail trailing-tokens root 6
check dockerfile-case-smuggle fixture_docker_fail case-smuggle
check dockerfile-external-copy fixture_docker_fail external-copy
check dockerfile-external-run-mount fixture_docker_fail external-run-mount
check dockerfile-parser-directive fixture_docker_fail parser-directive root 6
check dockerfile-indirect-arg fixture_docker_fail indirect-arg
check dockerfile-platform-unapproved fixture_docker_fail platform-unapproved
check dockerfile-mixed-case-copy fixture_docker_fail mixed-case-copy
check dockerfile-mixed-case-run-mount fixture_docker_fail mixed-case-run-mount
check dockerfile-heredoc-copy fixture_docker_fail heredoc-copy root 6
check dockerfile-onbuild fixture_docker_fail onbuild-from root 6
check dockerfile-wrong-target fixture_docker_wrong_target
check dockerfile-no-target fixture_docker_no_target
check dockerfile-policy-override fixture_docker_policy_override
check dockerfile-policy-mismatch fixture_docker_policy_mismatch

check materials-conforming-root fixture_materials_pass conforming-root root
check materials-conforming-normal fixture_materials_pass conforming-normal normal
check materials-extra-alpine fixture_materials_fail extra-alpine
check materials-missing-digest fixture_materials_fail missing-digest
check materials-different-digest fixture_materials_fail different-digest
check materials-syntax-frontend fixture_materials_fail syntax-frontend
check runtime-path-fake-bash fixture_hostile_shell_runtime bash
check runtime-path-fake-jq fixture_hostile_shell_runtime jq
check runtime-path-fake-gh fixture_hostile_shell_runtime gh
check runtime-path-fake-crane fixture_hostile_shell_runtime crane
check runtime-path-fake-python3 fixture_hostile_python_runtime
check runtime-pythonpath-json fixture_hostile_pythonpath
check trust-hardlink-check-signer fixture_hardlink_check_signer
check trust-hardlink-verify-attestations fixture_hardlink_verify_attestations
check trust-hardlink-verify-and-promote fixture_hardlink_verify_and_promote
check trust-hardlink-materials-tool fixture_hardlink_materials_tool
check trust-hardlink-signers-policy fixture_hardlink_signers_policy
check trust-hardlink-root-base-policy fixture_hardlink_root_base_policy
check trust-hardlink-builders-policy fixture_hardlink_builders_policy
check trust-directory-symlink fixture_trust_directory_symlink
check trust-open-once-runtime-swap fixture_open_once_runtime_swap
check signer-single-snapshot fixture_signer_single_snapshot
check trust-mode-group-file fixture_group_writable_trust_file
check trust-mode-group-parent fixture_group_writable_parent_dir
check trust-mode-world-runtime fixture_world_writable_runtime_dir

check registry-valid-manifest fixture_registry_status valid-manifest false $'exists\t-'
check registry-valid-index fixture_registry_status valid-index false $'exists\t-'
check registry-200-empty fixture_registry_200_reject 200-empty
check registry-200-html fixture_registry_200_reject 200-html
check registry-200-malformed fixture_registry_200_reject 200-malformed-json
check registry-200-error-envelope fixture_registry_200_reject 200-error-envelope
check registry-200-wrong-media fixture_registry_200_reject 200-wrong-media-type
check registry-text-plain fixture_registry_200_reject text-plain
check registry-schema-version-1 fixture_registry_200_reject schema-version-1
check registry-redirect fixture_registry_200_reject redirect
check registry-malformed-chunk fixture_registry_200_reject malformed-chunk
check registry-missing-content-type fixture_registry_200_reject missing-content-type
check registry-duplicate-content-type fixture_registry_200_reject duplicate-content-type
check registry-malformed-content-type fixture_registry_200_reject malformed-content-type
check registry-conflicting-content-type fixture_registry_200_reject conflicting-content-type
check registry-manifest fixture_registry_status manifest-unknown false $'first-publish\tMANIFEST_UNKNOWN'
check registry-name-bootstrap fixture_registry_status name-unknown true $'first-publish\tNAME_UNKNOWN'
check registry-name-denied fixture_registry_reject name-unknown
check registry-401 fixture_registry_reject unauthorized
check registry-403 fixture_registry_reject denied
check registry-429 fixture_registry_reject rate-limited
check registry-503 fixture_registry_reject unavailable
check registry-malformed fixture_registry_reject malformed-json
check registry-two-errors fixture_registry_reject two-errors
check registry-wrong-code fixture_registry_reject wrong-code
check registry-transport fixture_registry_transport
check registry-missing-auth fixture_registry_missing_auth
check promotion-removed fixture_promotion_removed
check promotion-direct-rejected fixture_promotion_direct_rejected
check promotion-malformed-200-premutation fixture_registry_reject 200-html
check promote-probe-digest-error fixture_promote_digest_probe_error
check promote-absent fixture_promote_absent
check promote-equal fixture_promote_equal
check promote-collision fixture_promote_collision
check promote-mutable fixture_promote_mutable
check promote-mismatch fixture_promote_mismatch
check promote-nonnumeric-run-id fixture_promote_nonnumeric_run_id

check verify-success fixture_verify success 0
check verify-empty fixture_verify empty 1
check verify-mismatch fixture_verify mismatch 1
check verify-fail-1 fixture_verify_fail_position 1
check verify-fail-2 fixture_verify_fail_position 2
check verify-fail-3 fixture_verify_fail_position 3
check verify-fail-4 fixture_verify_fail_position 4
check signer-candidate fixture_signer candidate 1111111111111111111111111111111111111111 signers-revoked.json 0
check signer-candidate-bad fixture_signer candidate 2222222222222222222222222222222222222222 signers-allowed.json 6
check signer-allowed-old fixture_signer current 2222222222222222222222222222222222222222 signers-allowed.json 0
check signer-unknown-old fixture_signer current 3333333333333333333333333333333333333333 signers-allowed.json 6
check signer-revoked-old fixture_signer current 2222222222222222222222222222222222222222 signers-revoked.json 6
check signer-wrong-workflow fixture_signer recovery 2222222222222222222222222222222222222222 signers-wrong-workflow.json 6
check signer-env-override fixture_signer_env_override
check signer-duplicate-policy fixture_signer current 2222222222222222222222222222222222222222 signers-duplicate.json 6
check signer-redundant-template fixture_signer current 1111111111111111111111111111111111111111 signers-redundant-template.json 6
check signer-extra-key fixture_signer current 1111111111111111111111111111111111111111 signers-extra-key.json 6
check signer-bad-workflow-policy fixture_signer current 1111111111111111111111111111111111111111 signers-bad-workflow.json 6
check signer-bad-active fixture_signer current 1111111111111111111111111111111111111111 signers-bad-active.json 6
check signer-bad-digest fixture_signer current 1111111111111111111111111111111111111111 signers-bad-digest.json 6
check signer-uppercase-digest fixture_signer current 1111111111111111111111111111111111111111 signers-uppercase-digest.json 6
check signer-symlink-escape fixture_signer_symlink_escape
check signer-before-mutation fixture_signer_premutation
check signer-bad-env fixture_signer_bad_env
check recovery-success fixture_recovery_success

check tags-match fixture_tags match
check tags-none fixture_tags none
check tags-duplicate fixture_tags duplicate
check tags-empty fixture_tags empty
check tags-owner-type fixture_tags owner-type
check tags-user-route fixture_tags user-route
check tags-org-route fixture_tags org-route
check tags-api-fail fixture_tags api-fail
check tags-digest-fail fixture_tags digest-fail

check decide-first-publish fixture_decide_expect manifest-unknown candidate-same.json \
  1111111111111111111111111111111111111111 sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  false decide current-index.json '{"decision":"publish","reasons":["first-publish"]}'
check decide-unchanged fixture_decide_expect exists candidate-same.json \
  1111111111111111111111111111111111111111 sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  false decide current-index.json '{"decision":"unchanged","reasons":[]}'
check decide-revision fixture_decide_expect exists candidate-same.json \
  2222222222222222222222222222222222222222 sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  false decide current-index.json '{"decision":"publish","reasons":["revision"]}'
check decide-base fixture_decide_expect exists candidate-same.json \
  1111111111111111111111111111111111111111 sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  false decide current-index.json '{"decision":"publish","reasons":["base"]}'
check decide-pkgset-amd64 fixture_decide_expect exists candidate-amd64-changed.json \
  1111111111111111111111111111111111111111 sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  false decide current-index.json '{"decision":"publish","reasons":["pkgset-amd64"]}'
check decide-force fixture_decide_expect exists candidate-same.json \
  1111111111111111111111111111111111111111 sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  true decide current-index.json '{"decision":"publish","reasons":["force"]}'
check decide-combined-order fixture_decide_expect exists candidate-both-changed.json \
  2222222222222222222222222222222222222222 sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  true decide current-index.json '{"decision":"publish","reasons":["force","revision","base","pkgset-amd64","pkgset-arm64"]}'
check decide-verify-failure fixture_decide_exit fail-1 current-index.json 3
check decide-duplicate-attestation fixture_decide_exit decide-duplicate current-index.json 5
check decide-missing-child fixture_decide_exit decide missing-amd64-index.json 5
check decide-duplicate-child fixture_decide_exit decide duplicate-amd64-index.json 5
check decide-overwrite-regression fixture_decide_expect exists candidate-amd64-changed.json \
  1111111111111111111111111111111111111111 sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  false decide current-index.json '{"decision":"publish","reasons":["pkgset-amd64"]}'
check decide-registry-error fixture_decide_registry_error
check fault-hook fixture_fault_hook
check static-all fixture_static_all

printf 'TOTAL %s/%s\n' "$pass" "$total"
[[ "$pass" -eq "$total" ]]
