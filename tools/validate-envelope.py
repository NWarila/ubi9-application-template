#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path


class SchemaError(Exception):
    pass


def resolve_ref(root, reference):
    if not reference.startswith("#/"):
        raise SchemaError(f"unsupported schema reference: {reference}")
    value = root
    for token in reference[2:].split("/"):
        value = value[token.replace("~1", "/").replace("~0", "~")]
    return value


def is_type(value, expected):
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "boolean": isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "null": value is None,
    }.get(expected, False)


def validate(value, schema, root, path="$"):
    errors = []
    if "$ref" in schema:
        return validate(value, resolve_ref(root, schema["$ref"]), root, path)
    expected_type = schema.get("type")
    if expected_type is not None:
        choices = expected_type if isinstance(expected_type, list) else [expected_type]
        if not any(is_type(value, choice) for choice in choices):
            return [f"{path}: wrong type"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: value is not the required constant")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: value is not in the allowed set")
    if isinstance(value, dict):
        required = schema.get("required", [])
        errors.extend(f"{path}: missing {name}" for name in required if name not in value)
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            errors.extend(f"{path}: unexpected {name}" for name in value if name not in properties)
        for name, subschema in properties.items():
            if name in value:
                errors.extend(validate(value[name], subschema, root, f"{path}.{name}"))
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path}: too few items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path}: too many items")
        if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            errors.append(f"{path}: items are not unique")
        if isinstance(schema.get("items"), dict):
            for index, item in enumerate(value):
                errors.extend(validate(item, schema["items"], root, f"{path}[{index}]"))
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: string is too short")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: string is too long")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            errors.append(f"{path}: string does not match pattern")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: number is below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: number is above maximum")
        if "multipleOf" in schema and value % schema["multipleOf"] != 0:
            errors.append(f"{path}: number is not a multiple")
    for subschema in schema.get("allOf", []):
        errors.extend(validate(value, subschema, root, path))
    if "anyOf" in schema and not any(not validate(value, item, root, path) for item in schema["anyOf"]):
        errors.append(f"{path}: no anyOf branch matched")
    if "oneOf" in schema and sum(not validate(value, item, root, path) for item in schema["oneOf"]) != 1:
        errors.append(f"{path}: exactly one oneOf branch must match")
    if "not" in schema and not validate(value, schema["not"], root, path):
        errors.append(f"{path}: forbidden schema matched")
    if "if" in schema:
        branch = "then" if not validate(value, schema["if"], root, path) else "else"
        if branch in schema:
            errors.extend(validate(value, schema[branch], root, path))
    return errors


def main():
    if len(sys.argv) != 2:
        print("usage: validate-envelope.py ENVELOPE.json", file=sys.stderr)
        return 6
    schema_path = Path(__file__).resolve().parent.parent / "contracts" / "publish-inputs.schema.json"
    try:
        with schema_path.open(encoding="utf-8") as stream:
            schema = json.load(stream)
        with open(sys.argv[1], encoding="utf-8") as stream:
            envelope = json.load(stream)
        errors = validate(envelope, schema, schema)
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, SchemaError) as exc:
        print(str(exc), file=sys.stderr)
        return 6
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
