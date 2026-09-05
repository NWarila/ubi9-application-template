#!/usr/bin/env python3
import argparse
import json
import re
import shlex
import sys
from pathlib import Path


CONTRACT_ARGS = ("BASE_IMAGE", "BASE_DIGEST", "BUILDER_IMAGE", "BUILDER_DIGEST")
BASE_REF = "${BASE_IMAGE}@${BASE_DIGEST}"
BUILDER_REF = "${BUILDER_IMAGE}@${BUILDER_DIGEST}"
CANONICAL_PINS = {
    "BASE_IMAGE": "registry.access.redhat.com/ubi9/ubi-micro",
    "BASE_DIGEST": "sha256:35de56a9413112f1474e392ebc35e0cf6f0fb484c8e8877bbae59b513694b41f",
    "BUILDER_IMAGE": "registry.access.redhat.com/ubi9/ubi-minimal",
    "BUILDER_DIGEST": "sha256:463cae32c6f6f5594b11a5c22de275016bd8545ce58a6373388e8b24f13fc15c",
}
CANONICAL_BUILD_ARGS = {
    "BASE_IMAGE": "base.image",
    "BASE_DIGEST": "base.digest",
    "BUILDER_IMAGE": "builder.image",
    "BUILDER_DIGEST": "builder.digest",
}


class ParseFailure(Exception):
    pass


def logical_lines(text):
    pending = ""
    start = None
    for number, physical in enumerate(text.splitlines(), 1):
        stripped = physical.strip()
        if re.match(r"^#\s*[A-Za-z][A-Za-z0-9_-]*\s*=", stripped):
            raise ParseFailure(f"line {number}: parser directives are forbidden")
        if re.match(r"^\s*#", physical) or not stripped:
            if pending:
                continue
            continue
        if "<<" in physical:
            raise ParseFailure(f"line {number}: heredoc syntax is unsupported")
        if start is None:
            start = number
        right = physical.rstrip()
        if right.endswith("\\"):
            pending += right[:-1].strip() + " "
            continue
        logical = (pending + stripped).strip()
        pending = ""
        yield start, logical
        start = None
    if pending:
        raise ParseFailure(f"line {start}: unterminated continuation")


def split_tokens(rest, line):
    try:
        return shlex.split(rest, posix=True)
    except ValueError as exc:
        raise ParseFailure(f"line {line}: malformed quoting: {exc}") from exc


def option(token):
    """Return a Dockerfile option name and value with only the name folded."""
    if not token.startswith("--"):
        return None, None
    body = token[2:]
    if "=" not in body:
        return body.casefold(), None
    name, value = body.split("=", 1)
    return name.casefold(), value


def copy_source(rest, line):
    sources = []
    for token in split_tokens(rest, line):
        name, value = option(token)
        if name != "from":
            continue
        if value is None or value == "":
            raise ParseFailure(f"line {line}: malformed --from flag")
        sources.append(value)
    if len(sources) > 1:
        raise ParseFailure(f"line {line}: multiple --from flags")
    return sources


def mount_sources(rest, line):
    sources = []
    for token in split_tokens(rest, line):
        name, value = option(token)
        if name != "mount":
            continue
        if value is None or value == "":
            raise ParseFailure(f"line {line}: malformed --mount flag")
        fields = value.split(",")
        from_fields = []
        for field in fields:
            if "=" not in field:
                continue
            field_name, field_value = field.split("=", 1)
            if field_name.casefold() == "from":
                from_fields.append(field_value)
        if len(from_fields) > 1 or any(not source for source in from_fields):
            raise ParseFailure(f"line {line}: malformed mount from source")
        sources.extend(from_fields)
    return sources


def is_internal(ref, aliases, stage_count):
    lowered = ref.lower()
    if lowered in aliases:
        return True
    if ref.isdigit() and int(ref) < stage_count:
        return True
    if ref.count("${TARGETARCH}") == 1:
        return all(ref.replace("${TARGETARCH}", arch).lower() in aliases
                   for arch in ("amd64", "arm64"))
    return False


def parse_dockerfile(text):
    global_phase = True
    args_seen = {name: [] for name in CONTRACT_ARGS}
    aliases = []
    alias_set = set()
    external_edges = []
    stage_count = 0
    for line, logical in logical_lines(text):
        match = re.match(r"^([^\s]+)(?:\s+(.*))?$", logical)
        if not match:
            raise ParseFailure(f"line {line}: malformed instruction")
        instruction = match.group(1).upper()
        rest = match.group(2) or ""
        if instruction == "ONBUILD":
            raise ParseFailure(f"line {line}: ONBUILD is unsupported")
        if instruction == "ARG":
            arg_match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)(?:=(.*))?", rest)
            if not arg_match:
                raise ParseFailure(f"line {line}: malformed ARG")
            name = arg_match.group(1)
            if name in CONTRACT_ARGS:
                args_seen[name].append({
                    "line": line,
                    "global": global_phase,
                    "has_default": arg_match.group(2) is not None,
                })
            continue
        if instruction == "FROM":
            global_phase = False
            tokens = split_tokens(rest, line)
            if not tokens:
                raise ParseFailure(f"line {line}: FROM has no reference")
            flag_name, flag_value = option(tokens[0])
            if flag_name is not None:
                if flag_name != "platform" or flag_value is None or not re.fullmatch(r"[^\s=]+", flag_value):
                    raise ParseFailure(f"line {line}: unsupported FROM flag")
                tokens = tokens[1:]
            if len(tokens) == 1:
                ref = tokens[0]
                alias = None
            elif len(tokens) == 3 and tokens[1].upper() == "AS" and re.fullmatch(r"[A-Za-z0-9_.-]+", tokens[2]):
                ref = tokens[0]
                alias = tokens[2]
            else:
                raise ParseFailure(f"line {line}: malformed FROM or trailing tokens")
            if "#" in ref:
                raise ParseFailure(f"line {line}: malformed FROM reference")
            if not is_internal(ref, alias_set, stage_count):
                external_edges.append({"kind": "FROM", "line": line, "ref": ref})
            if alias is not None:
                normalized = alias.lower()
                if normalized in alias_set:
                    raise ParseFailure(f"line {line}: duplicate alias {alias}")
                alias_set.add(normalized)
                aliases.append(alias)
            stage_count += 1
            continue
        if instruction in ("COPY", "ADD"):
            refs = copy_source(rest, line)
        elif instruction == "RUN":
            refs = mount_sources(rest, line)
        else:
            refs = []
        for ref in refs:
            if not is_internal(ref, alias_set, stage_count):
                external_edges.append({"kind": instruction, "line": line, "ref": ref})
    if stage_count == 0:
        raise ParseFailure("Dockerfile has no FROM")
    for name, declarations in args_seen.items():
        if len(declarations) > 1:
            raise ParseFailure(f"duplicate contract ARG {name}")
    return args_seen, aliases, external_edges


def load_policy():
    contract_dir = Path(__file__).resolve().parent.parent / "contracts"
    with (contract_dir / "root-base.json").open(encoding="utf-8") as stream:
        root_base = json.load(stream)
    with (contract_dir / "builders.json").open(encoding="utf-8") as stream:
        builders = json.load(stream)
    resolved = {
        "BASE_IMAGE": root_base.get("base", {}).get("image"),
        "BASE_DIGEST": root_base.get("base", {}).get("digest"),
        "BUILDER_IMAGE": root_base.get("builder", {}).get("image"),
        "BUILDER_DIGEST": root_base.get("builder", {}).get("digest"),
    }
    errors = []
    if resolved != CANONICAL_PINS:
        errors.append("root-base.json canonical pins mismatch")
    if root_base.get("build_args") != CANONICAL_BUILD_ARGS:
        errors.append("root-base.json build_args mismatch")
    if root_base.get("target") != "runtime":
        errors.append("root-base.json target mismatch")
    if builders != {"builders": [{"image": CANONICAL_PINS["BUILDER_IMAGE"],
                                   "digest": CANONICAL_PINS["BUILDER_DIGEST"]}]}:
        errors.append("builders.json canonical allowlist mismatch")
    return root_base, resolved, errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dockerfile", required=True)
    parser.add_argument("--mode", required=True, choices=("root", "normal"))
    parser.add_argument("--target")
    args = parser.parse_args()

    try:
        with open(args.dockerfile, encoding="utf-8") as stream:
            text = stream.read()
        root_base, resolved, errors = load_policy()
        args_seen, aliases, externals = parse_dockerfile(text)
    except ParseFailure as exc:
        print(str(exc), file=sys.stderr)
        return 6
    except (UnicodeError, OSError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 6

    counts = {BASE_REF: 0, BUILDER_REF: 0}
    for item in externals:
        ref = item["ref"]
        if ref not in counts:
            errors.append(f"line {item['line']}: unapproved external ref {ref}")
        else:
            counts[ref] += 1

    used_args = set()
    for ref in (BASE_REF, BUILDER_REF):
        if counts[ref]:
            used_args.update(re.findall(r"\$\{([A-Z_]+)\}", ref))
    for name in sorted(used_args):
        declarations = args_seen[name]
        if len(declarations) != 1 or not declarations[0]["global"] or declarations[0]["has_default"]:
            errors.append(f"{name} must be declared exactly once, globally, and without a default")

    if args.target is not None and args.target.lower() not in {alias.lower() for alias in aliases}:
        errors.append(f"target {args.target} is not a defined alias")
    if args.mode == "root":
        if args.target is None:
            errors.append("root mode requires --target")
        elif args.target != root_base.get("target"):
            errors.append(f"root target must equal {root_base.get('target')}")
        for name in CONTRACT_ARGS:
            declarations = args_seen[name]
            if len(declarations) != 1 or not declarations[0]["global"] or declarations[0]["has_default"]:
                message = f"{name} must be declared exactly once, globally, and without a default"
                if message not in errors:
                    errors.append(message)
        if counts[BASE_REF] < 1:
            errors.append("root mode requires at least one approved base reference")
        if counts[BUILDER_REF] < 1:
            errors.append("root mode requires at least one approved builder reference")
    elif counts[BUILDER_REF] != 1:
        errors.append("normal mode requires exactly one external builder reference")

    result = {
        "externals": externals,
        "aliases": aliases,
        "needs_builder": counts[BUILDER_REF] > 0,
        "build_args": resolved,
        "ok": not errors,
        "errors": errors,
    }
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
