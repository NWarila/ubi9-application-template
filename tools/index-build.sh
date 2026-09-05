#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: index-build.sh AMD64_DESCRIPTOR ARM64_DESCRIPTOR" >&2
  exit 6
fi
amd_file=$1
arm_file=$2
output=${INDEX_OUTPUT:-index.json}

validate_descriptor() {
  jq -e '
    type == "object" and
    (keys | sort) == (["digest","mediaType","platform","run_attempt","run_id","size"] | sort) and
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    (.size | type == "number" and . >= 1 and floor == .) and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.platform | type == "object") and
    (.platform | keys | sort) == (["architecture","os"] | sort) and
    .platform.os == "linux" and
    (.platform.architecture == "amd64" or .platform.architecture == "arm64") and
    (.run_id | type == "string" and test("^[0-9]+$")) and
    (.run_attempt | type == "string" and test("^[0-9]+$"))
  ' "$1" >/dev/null
}

validate_descriptor "$amd_file" || exit 1
validate_descriptor "$arm_file" || exit 1
[[ "$(jq -r '.platform.architecture' "$amd_file")" == amd64 ]] || exit 1
[[ "$(jq -r '.platform.architecture' "$arm_file")" == arm64 ]] || exit 1
[[ "$(jq -r '.run_id + "\t" + .run_attempt' "$amd_file")" == \
   "$(jq -r '.run_id + "\t" + .run_attempt' "$arm_file")" ]] || exit 1

AMD_DIGEST=$(jq -r .digest "$amd_file")
ARM_DIGEST=$(jq -r .digest "$arm_file")
AMD_SIZE=$(jq -r .size "$amd_file")
ARM_SIZE=$(jq -r .size "$arm_file")
jq -jcn --arg amd "$AMD_DIGEST" --arg arm "$ARM_DIGEST" --argjson amds "$AMD_SIZE" --argjson arms "$ARM_SIZE" \
 '{schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",manifests:[
   {mediaType:"application/vnd.oci.image.manifest.v1+json",size:$amds,digest:$amd,platform:{architecture:"amd64",os:"linux"}},
   {mediaType:"application/vnd.oci.image.manifest.v1+json",size:$arms,digest:$arm,platform:{architecture:"arm64",os:"linux"}}]}' > "$output"
printf 'sha256:%s\n' "$(sha256sum "$output" | cut -d' ' -f1)"
