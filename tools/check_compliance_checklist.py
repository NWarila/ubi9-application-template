#!/usr/bin/env python3
"""Validate the STIG applicability checklist is complete and closed."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STIG_CHECKLIST = ROOT / "docs/compliance/rhel-9-stig-v2r8-applicability.md"
CIS_CHECKLIST = ROOT / "docs/compliance/cis-docker-image-applicability.md"

EXPECTED_RULE_COUNT = 446
EXPECTED_SOURCE_HASH = "418855970157b31e4026a6ca7075fc1e723f40f30ef4554affbd3cafff0cc518"
EXPECTED_RELEASE_METADATA = "Release: 8 Benchmark Date: 01 Apr 2026"
ALLOWED_DECISIONS = {
    "APPROVED_IMAGE_CONTROL",
    "APPROVED_COMPENSATING_CONTROL",
    "DISPROVED_UBI_MICRO_ABSENT",
    "DISPROVED_DEPLOYMENT_CONTROL",
}
CIS_ALLOWED_DECISIONS = {
    "SATISFIED_IMAGE_CONTROL",
    "SATISFIED_REPO_CONTROL",
    "SATISFIED_REPLACEMENT",
    "DEPLOYMENT_SPECIFIC",
}
CIS_EXPECTED_CONTROLS = {f"CIS-Docker-4.{index}" for index in range(1, 13)}
FORBIDDEN_TOKENS = {
    "BLOCKED",
    "DEFERRED",
    "FIX" + "ME",
    "FOLLOW_UP",
    "PENDING",
    "TBD",
    "TO" + "DO",
}
ROW_RE = re.compile(
    r"^\| (?P<vid>V-\d{6}) \| (?P<stig_id>RHEL-09-\d{6}) \| "
    r"(?P<severity>LOW|MEDIUM|HIGH) \| .+ \| `(?P<decision>[A-Z_]+)` \| .+ \|$"
)
CIS_ROW_RE = re.compile(
    r"^\| (?P<control>CIS-Docker-4\.\d{1,2}) \| [^|]+ \| .+ \| "
    r"`(?P<decision>[A-Z_]+)` \| .+ \|$"
)


def fail(message: str) -> int:
    print(f"compliance checklist failed: {message}", file=sys.stderr)
    return 1


def main() -> int:
    if not STIG_CHECKLIST.is_file():
        return fail(f"missing {STIG_CHECKLIST.relative_to(ROOT)}")
    if not CIS_CHECKLIST.is_file():
        return fail(f"missing {CIS_CHECKLIST.relative_to(ROOT)}")

    text = STIG_CHECKLIST.read_text(encoding="utf-8")
    required_fragments = [
        "Red Hat Enterprise Linux 9 Security Technical Implementation Guide",
        EXPECTED_RELEASE_METADATA,
        EXPECTED_SOURCE_HASH,
        f"Parsed XCCDF rules: {EXPECTED_RULE_COUNT}",
        "NIST NCP record: https://ncp.nist.gov/checklist/1072",
        "DISA source zip: https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_RHEL_9_V2R8_STIG.zip",
    ]
    missing = [fragment for fragment in required_fragments if fragment not in text]
    if missing:
        return fail("missing source metadata: " + ", ".join(missing))

    if EXPECTED_SOURCE_HASH.lower() not in text.lower():
        return fail("source hash not present (case-insensitive)")

    forbidden = sorted(token for token in FORBIDDEN_TOKENS if re.search(rf"\b{token}\b", text))
    if forbidden:
        return fail("open or placeholder decision tokens present: " + ", ".join(forbidden))

    rows = []
    malformed = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not re.match(r"^\| V-\d", line):
            continue
        match = ROW_RE.match(line)
        if match is None:
            malformed.append(f"line {line_number}: {line}")
            continue
        rows.append(match.groupdict())

    if malformed:
        return fail("malformed checklist rows:\n" + "\n".join(malformed[:10]))
    if len(rows) != EXPECTED_RULE_COUNT:
        return fail(f"expected {EXPECTED_RULE_COUNT} rule rows, found {len(rows)}")

    duplicate_vids = sorted({row["vid"] for row in rows if [item["vid"] for item in rows].count(row["vid"]) > 1})
    if duplicate_vids:
        return fail("duplicate V-IDs: " + ", ".join(duplicate_vids))

    bad_decisions = sorted({row["decision"] for row in rows} - ALLOWED_DECISIONS)
    if bad_decisions:
        return fail("unknown decision values: " + ", ".join(bad_decisions))

    decisions = {row["decision"] for row in rows}
    missing_decisions = sorted(ALLOWED_DECISIONS - decisions)
    if missing_decisions:
        return fail("decision values not represented: " + ", ".join(missing_decisions))

    cis_text = CIS_CHECKLIST.read_text(encoding="utf-8")
    cis_required_fragments = [
        "Current CIS Docker Benchmark version observed: Docker 1.8.0",
        "https://www.cisecurity.org/benchmark/docker",
        "https://docs.docker.com/dhi/core-concepts/cis/",
        "https://docs.anchore.com/current/docs/compliance_management/policy_packs/cis/",
        "https://wazuh.com/blog/scanning-docker-infrastructure-against-cis-benchmark/",
    ]
    missing = [fragment for fragment in cis_required_fragments if fragment not in cis_text]
    if missing:
        return fail("missing CIS source metadata: " + ", ".join(missing))

    forbidden = sorted(token for token in FORBIDDEN_TOKENS if re.search(rf"\b{token}\b", cis_text))
    if forbidden:
        return fail("open or placeholder CIS decision tokens present: " + ", ".join(forbidden))

    cis_rows = []
    cis_malformed = []
    for line_number, line in enumerate(cis_text.splitlines(), start=1):
        if not re.match(r"^\| CIS-Docker-4\.", line):
            continue
        match = CIS_ROW_RE.match(line)
        if match is None:
            cis_malformed.append(f"line {line_number}: {line}")
            continue
        cis_rows.append(match.groupdict())

    if cis_malformed:
        return fail("malformed CIS rows:\n" + "\n".join(cis_malformed[:10]))

    cis_controls = {row["control"] for row in cis_rows}
    missing_controls = sorted(CIS_EXPECTED_CONTROLS - cis_controls)
    extra_controls = sorted(cis_controls - CIS_EXPECTED_CONTROLS)
    if missing_controls or extra_controls:
        return fail(
            "unexpected CIS control set: "
            + f"missing={', '.join(missing_controls) or '-'}; "
            + f"extra={', '.join(extra_controls) or '-'}"
        )

    bad_cis_decisions = sorted({row["decision"] for row in cis_rows} - CIS_ALLOWED_DECISIONS)
    if bad_cis_decisions:
        return fail("unknown CIS decision values: " + ", ".join(bad_cis_decisions))

    print(f"compliance checklist ok: {len(rows)} closed STIG decisions, {len(cis_rows)} closed CIS decisions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
