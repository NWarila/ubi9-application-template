#!/usr/bin/env python3
import argparse
import copy
import json
import re
import sys


def rewrite_string(value, arch):
    if value == "SPDXRef-DOCUMENT":
        return value
    if value.startswith("SPDXRef-"):
        return f"SPDXRef-{arch}-{value.removeprefix('SPDXRef-')}"
    return re.sub(
        r"(?<![A-Za-z0-9.-])LicenseRef-([A-Za-z0-9.-]+)",
        lambda match: f"LicenseRef-{arch}-{match.group(1)}",
        value,
    )


def rewrite(value, arch):
    if isinstance(value, str):
        return rewrite_string(value, arch)
    if isinstance(value, list):
        return [rewrite(item, arch) for item in value]
    if isinstance(value, dict):
        return {key: rewrite(item, arch) for key, item in value.items()}
    return value


parser = argparse.ArgumentParser()
parser.add_argument("--created", required=True)
parser.add_argument("--index-digest", required=True)
parser.add_argument("--source", action="append", required=True,
                    help="platform,digest,path")
args = parser.parse_args()

if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.index_digest):
    raise SystemExit("invalid index digest")

sources = []
for spec in args.source:
    platform, digest, path = spec.split(",", 2)
    if platform not in ("linux/amd64", "linux/arm64"):
        raise SystemExit(f"unsupported platform: {platform}")
    with open(path, encoding="utf-8") as stream:
        sources.append((platform, digest, json.load(stream)))
if [source[0] for source in sources] != ["linux/amd64", "linux/arm64"]:
    raise SystemExit("sources must be exactly linux/amd64 then linux/arm64")

merged = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": f"TMPL01A multi-platform SBOM {args.index_digest}",
    "documentNamespace": (
        "https://github.com/NWarila/ubi9-application-template/spdx/tmpl01a/"
        + args.index_digest.replace(":", "-")
    ),
    "creationInfo": {
        "licenseListVersion": "3.28",
        "creators": ["Organization: Anchore, Inc", "Tool: syft-1.51.1",
                     "Tool: tmpl01a-spdx-merge-1"],
        "created": args.created,
    },
    "documentDescribes": [],
    "packages": [],
    "files": [],
    "relationships": [],
}

for platform, digest, document in sources:
    if document.get("spdxVersion") != "SPDX-2.3":
        raise SystemExit(f"unexpected SPDX version for {platform}")
    arch = platform.split("/", 1)[1]
    roots = [rel["relatedSpdxElement"] for rel in document["relationships"]
             if rel["spdxElementId"] == "SPDXRef-DOCUMENT"
             and rel["relationshipType"] == "DESCRIBES"]
    root_versions = [pkg.get("versionInfo") for pkg in document["packages"]
                     if pkg["SPDXID"] in roots]
    if roots == [] or root_versions != [digest]:
        raise SystemExit(f"root package does not bind {platform} to {digest}")
    rewritten = rewrite(copy.deepcopy(document), arch)
    rewritten_roots = [rewrite_string(root, arch) for root in roots]
    merged["documentDescribes"].extend(rewritten_roots)
    for package in rewritten.get("packages", []):
        if package["SPDXID"] in rewritten_roots:
            marker = f"TMPL01A child manifest digest={digest} platform={platform}"
            package["comment"] = "\n".join(filter(None, [package.get("comment"), marker]))
        merged["packages"].append(package)
    for key in ("files", "relationships"):
        merged[key].extend(rewritten.get(key, []))
    for key in ("snippets", "hasExtractedLicensingInfos"):
        if key in rewritten:
            merged.setdefault(key, []).extend(rewritten[key])

merged["documentDescribes"].sort()
for key, id_key in (("packages", "SPDXID"), ("files", "SPDXID"),
                    ("snippets", "SPDXID"),
                    ("hasExtractedLicensingInfos", "licenseId")):
    if key in merged:
        merged[key].sort(key=lambda item: item[id_key])
merged["relationships"].sort(key=lambda item: json.dumps(item, sort_keys=True))
sys.stdout.write(json.dumps(merged, ensure_ascii=False, separators=(",", ":"),
                            sort_keys=True))
