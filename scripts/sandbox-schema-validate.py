#!/usr/bin/env python3
"""Pinned JSON Schema / OpenAPI fixture validator for the sandbox API contract.

Required contract gate: a request is accepted only if the JSON Schema stage
AND the semantic stage both accept. A structural schema rejection already
rejects the request; the semantic stage may be not_applicable in that case.
Byte/decode bounds that JSON Schema cannot express use explicit per-stage
expectations. Neither stage is an acceptlist of fixture ids.

Run with pinned jsonschema==4.17.3 and PyYAML==6.0.2. Use a Python 3.12
container with binary wheels; host 3.14 source-builds of this PyYAML pin stall.
"""
from __future__ import annotations

import base64
import binascii
import json
import sys
from pathlib import Path

REQUIRED_PINS = {
    "jsonschema": "4.17.3",
    "yaml": "6.0.2",
}

SCHEMA_IDS = {
    "decimal-u64": "decimal-u64.json",
    "generation": "generation.json",
    "opaque-id": "opaque-id.json",
    "error-canonical": "error-canonical.json",
    "error-diagnostic": "error-diagnostic.json",
    "sandbox-create": "sandbox-create.json",
    "execution-create": "execution-create.json",
    "capabilities-diagnostic": "capabilities-diagnostic.json",
}

OPENAPI_SCHEMA_NAMES = {
    "decimal-u64": "DecimalU64",
    "generation": "Generation",
    "opaque-id": "OpaqueId",
    "error-canonical": "CanonicalError",
    "error-diagnostic": "DiagnosticError",
    "sandbox-create": "SandboxCreate",
    "execution-create": "ExecutionCreate",
}

TRUE_END = "(?![\\s\\S])"
MAX_STRING_BYTES = 4096
MAX_PATH_BYTES = 4096
MAX_ID_BYTES = 128
MAX_ARGV = 64
MAX_ENV = 64
U64_MAX = 18446744073709551615


class SemanticError(Exception):
    """Instance failed the semantic stage (UTF-8 bytes, decode, guest path)."""


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def check_pins() -> None:
    try:
        import jsonschema
        import yaml
    except ImportError as exc:
        fail(f"missing pinned dependency: {exc}. Install tests/contract/schema-pins.txt into a D: target.")
    versions = {
        "jsonschema": jsonschema.__version__,
        "yaml": yaml.__version__,
    }
    for name, expected in REQUIRED_PINS.items():
        got = versions.get(name)
        if got != expected:
            fail(f"pinned {name}=={expected} required, found {got}")
    from jsonschema import Draft202012Validator  # noqa: F401

    print(f"pins: jsonschema=={versions['jsonschema']} PyYAML=={versions['yaml']}")


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_store(schema_dir: Path) -> dict:
    store = {}
    for path in sorted(schema_dir.glob("*.json")):
        data = load_json(path)
        store[path.name] = data
        ident = data.get("$id")
        if ident:
            store[ident] = data
    return store


def validator_for(schema: dict, store: dict):
    import jsonschema

    resolver = jsonschema.RefResolver.from_schema(schema, store=store)
    return jsonschema.Draft202012Validator(schema, resolver=resolver)


def check_schema(schema: dict, label: str) -> None:
    import jsonschema

    try:
        jsonschema.Draft202012Validator.check_schema(schema)
    except Exception as exc:
        fail(f"check_schema({label}): {type(exc).__name__}: {exc}")


def instance_is_valid(schema: dict, store: dict, instance) -> bool:
    """True if the instance is valid. Only ValidationError means invalid.

    SchemaError, RefResolutionError, and other infrastructure errors propagate
    so the lane fails instead of treating them as request rejection.
    """
    import jsonschema

    try:
        validator_for(schema, store).validate(instance)
        return True
    except jsonschema.SchemaError:
        raise
    except jsonschema.ValidationError:
        return False


def expand_repeats(value, label: str):
    """Materialize exact long strings from {$repeat:{unit,count,suffix?}}.

    This is a corpus encoding for byte/decode boundary lengths, not a
    fixture-id acceptlist. Unknown keys fail the lane.
    """
    if isinstance(value, dict):
        if "$repeat" in value:
            extra = set(value) - {"$repeat"}
            if extra:
                fail(f"{label}: $repeat object must not mix with other keys {sorted(extra)}")
            spec = value["$repeat"]
            if not isinstance(spec, dict):
                fail(f"{label}: $repeat must be an object")
            allowed = {"unit", "count", "suffix"}
            unknown = set(spec) - allowed
            if unknown:
                fail(f"{label}: $repeat unknown keys {sorted(unknown)}")
            unit = spec.get("unit")
            count = spec.get("count")
            suffix = spec.get("suffix", "")
            if not isinstance(unit, str) or not isinstance(count, int) or isinstance(count, bool) or count < 0:
                fail(f"{label}: $repeat requires string unit and non-negative int count")
            if not isinstance(suffix, str):
                fail(f"{label}: $repeat suffix must be a string")
            return unit * count + suffix
        return {k: expand_repeats(v, f"{label}.{k}") for k, v in value.items()}
    if isinstance(value, list):
        return [expand_repeats(v, f"{label}[{i}]") for i, v in enumerate(value)]
    return value


def load_case_value(case: dict, fixture_dir: Path):
    cid = case.get("id")
    if "file" in case:
        path = fixture_dir / case["file"]
        raw = path.read_text(encoding="utf-8")
        return expand_repeats(json.loads(raw), cid)
    if "value" in case:
        return expand_repeats(case["value"], cid)
    fail(f"case {cid} has neither file nor value")


def explicit_stages(case: dict):
    """Return (schema_exp, semantic_exp) or None when the case uses combined expect."""
    cid = case.get("id")
    if "expect_schema" not in case and "expect_semantic" not in case:
        return None
    schema_exp = case.get("expect_schema")
    semantic_exp = case.get("expect_semantic")
    if schema_exp not in ("accept", "reject"):
        fail(f"{cid} expect_schema must be accept|reject")
    if semantic_exp not in ("accept", "reject", "not_applicable"):
        fail(f"{cid} expect_semantic must be accept|reject|not_applicable")
    return schema_exp, semantic_exp


def assert_true_end_pattern(schema: dict, name: str) -> None:
    pat = schema.get("pattern")
    if not isinstance(pat, str):
        fail(f"{name} missing pattern")
    if TRUE_END not in pat:
        fail(f"{name} pattern is not a true-end constraint (missing {TRUE_END!r})")
    if pat.endswith("$"):
        fail(f"{name} pattern still uses $ as the string-end anchor")


def assert_openapi_security(spec: dict, text: str) -> None:
    if spec.get("security") != [{"MutualTLS": []}]:
        fail(f"OpenAPI global security must be MutualTLS only, got {spec.get('security')!r}")
    schemes = spec.get("components", {}).get("securitySchemes", {})
    if "MutualTLS" not in schemes:
        fail("OpenAPI missing MutualTLS security scheme")
    if "LocalOsIdentity" in schemes:
        fail("OpenAPI must not declare LocalOsIdentity as a security scheme")
    for name, scheme in schemes.items():
        if scheme.get("type") == "apiKey":
            fail(f"OpenAPI security scheme {name} is apiKey; local identity must not be a header credential")
        if scheme.get("in") == "header" and "identity" in name.lower():
            fail(f"OpenAPI identity header scheme {name} is not allowed")
    if "X-Sandbox-Local-Identity" in text:
        fail("OpenAPI still names X-Sandbox-Local-Identity; local identity is x-local-ipc-* metadata")
    for key in (
        "x-local-ipc-identity",
        "x-local-ipc-peer-pid",
        "x-local-ipc-peer-uid",
        "x-local-ipc-peer-gid",
        "x-local-ipc-peer-sid",
        "x-local-ipc-audit-token",
    ):
        if key not in spec:
            fail(f"OpenAPI missing {key} transport metadata")
    for path in ("/healthz", "/readyz", "/v1/capabilities"):
        ops = spec.get("paths", {}).get(path, {})
        for method, op in ops.items():
            if method in ("get", "head") and op.get("security") != []:
                fail(f"{method.upper()} {path} must remain public diagnostics (security: [])")
    sandboxes = spec.get("paths", {}).get("/v1/sandboxes", {}).get("post", {})
    if "security" in sandboxes and sandboxes["security"] == []:
        fail("POST /v1/sandboxes must not override security to anonymous")
    print("openapi security: MutualTLS only; diagnostics public; no identity apiKey")


def assert_shared_bounds(standalone: dict, openapi_schema: dict, name: str) -> None:
    for field in ("type", "pattern", "maxLength", "minLength"):
        left = standalone.get(field)
        right = openapi_schema.get(field)
        if left != right:
            fail(f"{name} {field} mismatch standalone={left!r} openapi={right!r}")


def resolve_openapi(schema: dict, openapi_schemas: dict) -> dict:
    ref = schema.get("$ref")
    if isinstance(ref, str) and ref.startswith("#/components/schemas/"):
        name = ref.rsplit("/", 1)[-1]
        return resolve_openapi(openapi_schemas[name], openapi_schemas)
    out = dict(schema)
    if "properties" in schema:
        out["properties"] = {
            k: resolve_openapi(v, openapi_schemas) if isinstance(v, dict) else v
            for k, v in schema["properties"].items()
        }
    if "additionalProperties" in schema and isinstance(schema["additionalProperties"], dict):
        out["additionalProperties"] = resolve_openapi(schema["additionalProperties"], openapi_schemas)
    if "propertyNames" in schema and isinstance(schema["propertyNames"], dict):
        out["propertyNames"] = resolve_openapi(schema["propertyNames"], openapi_schemas)
    if "items" in schema and isinstance(schema["items"], dict):
        out["items"] = resolve_openapi(schema["items"], openapi_schemas)
    if "allOf" in schema:
        out["allOf"] = [
            resolve_openapi(v, openapi_schemas) if isinstance(v, dict) else v for v in schema["allOf"]
        ]
    return out


def utf8_bytes(s: str) -> int:
    return len(s.encode("utf-8"))


def parse_decimal_u64(s: str) -> int:
    if not isinstance(s, str) or not s or len(s) > 20:
        raise SemanticError("decimal")
    if s[0] == "0":
        if len(s) != 1:
            raise SemanticError("decimal")
        return 0
    value = 0
    for ch in s:
        if ch < "0" or ch > "9":
            raise SemanticError("decimal")
        value = value * 10 + (ord(ch) - 48)
        if value > U64_MAX:
            raise SemanticError("decimal overflow")
    return value


def is_opaque_id(s: str) -> bool:
    if not isinstance(s, str):
        return False
    raw = s.encode("utf-8")
    if not raw or len(raw) > MAX_ID_BYTES:
        return False
    all_digits = True
    for c in raw:
        ok = (
            (65 <= c <= 90)
            or (97 <= c <= 122)
            or (48 <= c <= 57)
            or c in (46, 95, 45, 58)
        )
        if not ok:
            return False
        if c < 48 or c > 57:
            all_digits = False
    return not all_digits


def is_image_digest(s: str) -> bool:
    if not isinstance(s, str):
        return False
    prefix = "sha256:"
    if not s.startswith(prefix):
        return False
    hexpart = s[len(prefix) :]
    if len(hexpart) != 64:
        return False
    return all((48 <= ord(c) <= 57) or (97 <= ord(c) <= 102) for c in hexpart)


def is_guest_path(s: str) -> bool:
    if not isinstance(s, str):
        return False
    raw = s.encode("utf-8")
    if not raw or len(raw) > MAX_PATH_BYTES:
        return False
    if raw[0] != 0x2F:
        return False
    if 0 in raw or 0x5C in raw:
        return False
    if len(raw) >= 2 and raw[1] == 0x2F:
        return False
    start = 1
    n = len(raw)
    while start <= n:
        try:
            slash = raw.index(0x2F, start)
        except ValueError:
            slash = n
        seg = raw[start:slash]
        if len(seg) == 0 and slash != n:
            return False
        if seg in (b".", b".."):
            return False
        if slash == n:
            break
        start = slash + 1
    return True


def is_env_name(s: str) -> bool:
    if not isinstance(s, str) or not s:
        return False
    raw = s.encode("utf-8")
    c0 = raw[0]
    if not ((65 <= c0 <= 90) or (97 <= c0 <= 122) or c0 == 95):
        return False
    for c in raw[1:]:
        ok = (65 <= c <= 90) or (97 <= c <= 122) or (48 <= c <= 57) or c == 95
        if not ok:
            return False
    return True


def is_standard_base64(s: str) -> bool:
    if not isinstance(s, str):
        return False
    if s == "":
        return True
    if len(s) % 4 != 0:
        return False
    pad = 0
    for c in s:
        if c == "=":
            pad += 1
            if pad > 2:
                return False
            continue
        if pad != 0:
            return False
        ok = (
            ("A" <= c <= "Z")
            or ("a" <= c <= "z")
            or ("0" <= c <= "9")
            or c in "+/"
        )
        if not ok:
            return False
    return True


def decoded_stdin_len(s: str) -> int:
    if not is_standard_base64(s):
        raise SemanticError("invalid base64")
    if s == "":
        return 0
    try:
        raw = base64.b64decode(s, validate=True)
    except binascii.Error as exc:
        raise SemanticError("base64 decode") from exc
    if len(raw) > MAX_STRING_BYTES:
        raise SemanticError("decoded stdin too large")
    return len(raw)


def semantic_decimal(instance) -> None:
    parse_decimal_u64(instance)


def semantic_generation(instance) -> None:
    if parse_decimal_u64(instance) < 1:
        raise SemanticError("generation")


def semantic_opaque(instance) -> None:
    if not is_opaque_id(instance):
        raise SemanticError("opaque-id")


def semantic_execution_create(instance) -> None:
    if not isinstance(instance, dict):
        raise SemanticError("object")
    semantic_generation(instance.get("generation"))
    argv = instance.get("argv")
    if not isinstance(argv, list) or not argv or len(argv) > MAX_ARGV:
        raise SemanticError("argv")
    for arg in argv:
        if not isinstance(arg, str) or not arg or "\x00" in arg:
            raise SemanticError("argv item")
        if utf8_bytes(arg) > MAX_STRING_BYTES:
            raise SemanticError("argv utf-8 bytes")
    if "cwd" in instance:
        cwd = instance["cwd"]
        if not is_guest_path(cwd):
            raise SemanticError("cwd")
        if utf8_bytes(cwd) > MAX_PATH_BYTES:
            raise SemanticError("cwd utf-8 bytes")
    if "timeout_ms" in instance:
        semantic_decimal(instance["timeout_ms"])
    if "env" in instance:
        env = instance["env"]
        if not isinstance(env, dict):
            raise SemanticError("env")
        if len(env) > MAX_ENV:
            raise SemanticError("env size")
        for key, value in env.items():
            if not is_env_name(key):
                raise SemanticError("env name")
            if not isinstance(value, str) or "\x00" in value:
                raise SemanticError("env value")
            if utf8_bytes(key) > MAX_STRING_BYTES or utf8_bytes(value) > MAX_STRING_BYTES:
                raise SemanticError("env utf-8 bytes")
    if "stdin_base64" in instance:
        decoded_stdin_len(instance["stdin_base64"])


def semantic_sandbox_create(instance) -> None:
    if not isinstance(instance, dict):
        raise SemanticError("object")
    image = instance.get("image")
    if not isinstance(image, dict):
        raise SemanticError("image")
    if not is_opaque_id(image.get("id")):
        raise SemanticError("image.id")
    if not is_image_digest(image.get("digest")):
        raise SemanticError("image.digest")
    limits = instance.get("limits")
    if limits is not None:
        if not isinstance(limits, dict):
            raise SemanticError("limits")
        for key, value in limits.items():
            if value is not None:
                semantic_decimal(value)
    if "rootfs" in instance and isinstance(instance["rootfs"], dict):
        vol = instance["rootfs"].get("volume")
        if vol is not None and not is_opaque_id(vol):
            raise SemanticError("rootfs.volume")


def semantic_error_canonical(instance) -> None:
    if not isinstance(instance, dict):
        raise SemanticError("object")
    if not is_opaque_id(instance.get("request_id")):
        raise SemanticError("request_id")
    message = instance.get("message")
    if not isinstance(message, str) or not message or utf8_bytes(message) > MAX_STRING_BYTES:
        raise SemanticError("message")


def semantic_passthrough(_instance) -> None:
    return


SEMANTIC_VALIDATORS = {
    "decimal-u64": semantic_decimal,
    "generation": semantic_generation,
    "opaque-id": semantic_opaque,
    "execution-create": semantic_execution_create,
    "sandbox-create": semantic_sandbox_create,
    "error-canonical": semantic_error_canonical,
    "error-diagnostic": semantic_passthrough,
    "capabilities-diagnostic": semantic_passthrough,
}


def semantic_is_valid(schema_key: str, instance) -> bool:
    fn = SEMANTIC_VALIDATORS.get(schema_key)
    if fn is None:
        fail(f"no semantic validator for {schema_key}")
    try:
        fn(instance)
        return True
    except SemanticError:
        return False


def assert_infrastructure_failures(store: dict) -> None:
    import jsonschema

    def expect_infra(name: str, fn) -> None:
        try:
            fn()
        except jsonschema.SchemaError:
            print(f"PASS {name}: SchemaError")
            return
        except jsonschema.ValidationError:
            fail(f"{name}: instance ValidationError is not an infrastructure failure")
        except Exception as exc:
            print(f"PASS {name}: {type(exc).__name__}")
            return
        fail(f"{name}: expected infrastructure failure, succeeded")

    expect_infra(
        "harness-invalid-schema-keyword",
        lambda: jsonschema.Draft202012Validator.check_schema({"type": "not-a-json-type"}),
    )
    broken = {"$ref": "https://zig-sandbox.local/schemas/does-not-exist.json"}
    expect_infra(
        "harness-broken-ref",
        lambda: validator_for(broken, store).validate({"x": 1}),
    )
    assert_decoder_infrastructure_fault()


def assert_decoder_infrastructure_fault() -> None:
    """Injected decoder RuntimeError must fail the lane, not reject the instance.

    Catching every Exception in decoded_stdin_len converted infrastructure
    faults into SemanticError, which semantic_is_valid treats as ordinary
    invalid. Only binascii.Error is a malformed-base64 instance rejection.
    """
    original = base64.b64decode

    def boom(*_args, **_kwargs):
        raise RuntimeError("injected decoder fault")

    base64.b64decode = boom
    try:
        try:
            decoded_stdin_len("Zg==")
        except SemanticError:
            fail(
                "harness-decoder-runtimeerror: RuntimeError converted into SemanticError"
            )
        except RuntimeError:
            print("PASS harness-decoder-runtimeerror: RuntimeError")
        else:
            fail("harness-decoder-runtimeerror: injected RuntimeError succeeded")
    finally:
        base64.b64decode = original


def main() -> int:
    check_pins()
    import yaml

    here = Path(__file__).resolve()
    root = here.parents[1]
    schema_dir = root / "schemas"
    fixture_dir = root / "tests" / "contract" / "fixtures"
    corpus_path = fixture_dir / "schema-corpus.json"
    openapi_path = root / "docs" / "sandbox-api.openapi.yaml"

    store = load_store(schema_dir)
    for filename, schema in store.items():
        if isinstance(filename, str) and filename.endswith(".json"):
            check_schema(schema, filename)

    openapi_text = openapi_path.read_text(encoding="utf-8")
    spec = yaml.safe_load(openapi_text)
    assert_openapi_security(spec, openapi_text)

    openapi_schemas = spec["components"]["schemas"]
    assert_shared_bounds(store["decimal-u64.json"], openapi_schemas["DecimalU64"], "DecimalU64")
    assert_shared_bounds(store["generation.json"], openapi_schemas["Generation"], "Generation")
    assert_shared_bounds(store["opaque-id.json"], openapi_schemas["OpaqueId"], "OpaqueId")
    assert_true_end_pattern(store["decimal-u64.json"], "DecimalU64")
    assert_true_end_pattern(store["generation.json"], "Generation")
    assert_true_end_pattern(store["opaque-id.json"], "OpaqueId")
    assert_true_end_pattern(store["sandbox-create.json"]["properties"]["image"]["properties"]["digest"], "ImageDigest")
    assert_true_end_pattern(openapi_schemas["ImagePin"]["properties"]["digest"], "OpenAPI ImagePin.digest")
    if openapi_schemas["CanonicalError"]["properties"]["request_id"] != {
        "$ref": "#/components/schemas/OpaqueId"
    }:
        req = openapi_schemas["CanonicalError"]["properties"]["request_id"]
        if req.get("pattern") != store["opaque-id.json"]["pattern"]:
            fail("OpenAPI CanonicalError.request_id is not OpaqueId")
    cwd_schema = openapi_schemas["ExecutionCreate"]["properties"]["cwd"]
    if cwd_schema.get("type") != "string" or "null" in str(cwd_schema.get("type")):
        fail("OpenAPI ExecutionCreate.cwd must be a non-nullable string")
    for prop in ("cwd", "timeout_ms", "stdin_base64", "env"):
        node = openapi_schemas["ExecutionCreate"]["properties"][prop]
        types = node.get("type")
        if isinstance(types, list) and "null" in types:
            fail(f"OpenAPI ExecutionCreate.{prop} must not be nullable")
        if node.get("nullable") is True:
            fail(f"OpenAPI ExecutionCreate.{prop} must not set nullable: true")
    standalone_exec = store["execution-create.json"]["properties"]
    openapi_exec = openapi_schemas["ExecutionCreate"]["properties"]
    if standalone_exec["cwd"].get("pattern") != openapi_exec["cwd"].get("pattern"):
        fail("ExecutionCreate.cwd pattern mismatch standalone vs OpenAPI")
    if standalone_exec["stdin_base64"].get("pattern") != openapi_exec["stdin_base64"].get("pattern"):
        fail("ExecutionCreate.stdin_base64 pattern mismatch standalone vs OpenAPI")
    if standalone_exec["argv"]["items"].get("pattern") != openapi_exec["argv"]["items"].get("pattern"):
        fail("ExecutionCreate.argv item pattern mismatch standalone vs OpenAPI")

    assert_infrastructure_failures(store)

    corpus = load_json(corpus_path)
    passed = 0
    failed = 0
    for case in corpus["cases"]:
        schema_key = case["schema"]
        filename = SCHEMA_IDS[schema_key]
        standalone = store[filename]
        instance = load_case_value(case, fixture_dir)

        try:
            standalone_ok = instance_is_valid(standalone, store, instance)
        except Exception as exc:
            fail(f"{case['id']} standalone infrastructure failure: {type(exc).__name__}: {exc}")

        openapi_ok = None
        openapi_name = OPENAPI_SCHEMA_NAMES.get(schema_key)
        if openapi_name:
            openapi_schema = openapi_schemas[openapi_name]
            inlined = resolve_openapi(openapi_schema, openapi_schemas)
            check_schema(inlined, f"openapi:{openapi_name}")
            try:
                openapi_ok = instance_is_valid(inlined, store, instance)
            except Exception as exc:
                fail(f"{case['id']} openapi infrastructure failure: {type(exc).__name__}: {exc}")

        try:
            semantic_ok = semantic_is_valid(schema_key, instance)
        except Exception as exc:
            fail(f"{case['id']} semantic infrastructure failure: {type(exc).__name__}: {exc}")

        openapi_agrees = openapi_ok is None or openapi_ok == standalone_ok
        schema_ok = bool(standalone_ok and openapi_agrees)
        combined_accept = bool(schema_ok and semantic_ok)
        stages = explicit_stages(case)

        if stages is not None:
            expect_schema, expect_semantic = stages
            schema_pass = standalone_ok if expect_schema == "accept" else not standalone_ok
            if openapi_ok is not None:
                openapi_match = openapi_ok if expect_schema == "accept" else not openapi_ok
                schema_pass = schema_pass and openapi_match
            if expect_semantic == "not_applicable":
                semantic_pass = True
            else:
                semantic_pass = semantic_ok if expect_semantic == "accept" else not semantic_ok
            ok = bool(schema_pass and semantic_pass and openapi_agrees)
            if expect_schema == "accept" and expect_semantic == "accept":
                ok = ok and combined_accept
            elif expect_schema == "accept" and expect_semantic == "reject":
                ok = ok and not combined_accept
            elif expect_schema == "reject":
                ok = ok and not combined_accept
        else:
            expect = case.get("expect")
            if expect not in ("accept", "reject"):
                fail(f"{case['id']} missing expect or explicit stages")
            expect_schema = expect
            expect_semantic = "accept" if expect == "accept" else "not_applicable"
            if expect == "accept":
                ok = combined_accept
            else:
                ok = (not combined_accept) and openapi_agrees
        status = "PASS" if ok else "FAIL"
        if not ok:
            failed += 1
            print(
                f"{status} {case['id']}: standalone_valid={standalone_ok} "
                f"openapi_valid={openapi_ok} semantic_valid={semantic_ok} "
                f"combined_accept={combined_accept} "
                f"expect_schema={expect_schema} expect_semantic={expect_semantic}"
            )
        else:
            passed += 1
            print(f"{status} {case['id']}")

    print(f"corpus: {passed} passed, {failed} failed, {passed + failed} total")
    if failed:
        return 1
    print("schema lane passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
