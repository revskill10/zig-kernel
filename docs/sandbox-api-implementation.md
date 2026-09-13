# Sandbox API implementation record

Published diagnostic slice on the native-containing tree. This is not a
production API, release approval, or execution-backend claim.

**Updated:** 2026-09-14 (clean-main integration of AP0/AP1 diagnostic listener)

## Envelope rule

The diagnostic bootstrap listener and the planned production service use
**different JSON error documents**:

| Envelope | Shape | Who serves it |
| --- | --- | --- |
| Diagnostic nested | `{"error":{"code","message"}}` | Current `zig-sandbox` HTTP bootstrap |
| Canonical | `{"code","message","request_id","retryable","detail?"}` | Planned AP2+ authenticated service |

Do not treat the two as one schema. Bootstrap `execution_unavailable` 501 maps
to canonical `unsupported` with `retryable:false` only as a translation table
in `supervisor/contract.zig`. The listener still emits the nested document.

## Slice boundary

This checkout publishes the anonymous Linux/amd64 diagnostic HTTP listener,
portable contract, independent fixtures, JSON schemas, OpenAPI document, and
unavailable engine adapter seams.

It does **not** compose `supervisor/api.zig` success paths, `runtime.zig`
spawn/reap, or `session.zig` lifecycle into the listener. It does not provide
authentication, filesystem adapters, guest execution, pause/resume, client CLI,
TypeScript/Wasm SDKs, host mounts, or cross-platform servers.

Native x86_64 UEFI bootstrap, ELF64 payload, hosted parser fixtures, and the
public native qualifier remain a **separate** qualification path in this tree.
They are not an API execution backend and do not make `/readyz` 200 or
`features.execution` true.

## Phase status

| Phase | Status | What landed | What is not claimed |
| --- | --- | --- | --- |
| AP0 | in this slice | Portable contract, std.json bounded validation, structured canonical detail, bound-VM composition gate, typed engine contracts, exact u64 schema | Host execution, durable auth/store |
| AP1 | in this slice | Independent JSON/detail/inventory/schema fixtures; MutualTLS-only remote OpenAPI; fail-closed diagnostic listener | No live 401/403 from this anonymous listener |
| AP2 | not started | — | Durable store, auth, operations; SQLite dependency unverified |
| AP3 | not started | — | Linux QEMU/KVM guest operations |
| AP4 | not started | — | macOS HVF / Windows WHPX |
| AP5 | not started | — | TypeScript SDK, Wasm core, guest WASI, callback broker |
| AP6 | not started | — | Release, SBOM, runbooks |

## Verification (this clean slice)

Measured on Windows with Zig 0.16.0. Hosted Zig tests and a linux-musl
compile are not QEMU boot, guest execution, or Docker/process proof.

```sh
zig build test-sandbox sandbox-api -Doptimize=ReleaseSafe --summary all
```

75/75 tests passed; 17/17 steps succeeded (43 supervisor, 6 bootstrap, 9
engine, 17 independent contract, plus `sandbox-api`).

```sh
zig build test-native test native-image native-tools --summary all
```

175/175 tests passed; 46/46 steps succeeded (117 native hosted contract
tests + 58 hosted kernel tests). This command does not run supervisor
tests. `test-native` and `test` are hosted; `native-image` and
`native-tools` build artifacts. None of these is UEFI boot or guest
qualification.

Python 3.12 container with `tests/contract/schema-pins.txt`: 74/74 corpus
passed; schema lane passed.

```sh
python scripts/sandbox-schema-validate.py
```

Fresh Linux/amd64 Docker image build passed; the container ran as sandbox
UID 999 with a read-only root filesystem and capabilities dropped, and
the Docker healthcheck was healthy. 15/15 coordinator HTTP checks passed
including readiness 503, create/resume 501, HEAD empty bodies, method 405,
oversized header 431/body 413, five-second incomplete-header deadline 400,
and post-negative health 200. Built Linux process script returned
`PROBE_OK`; reproduce with the README Docker commands and
`bash scripts/sandbox-probe.sh`. This only qualifies diagnostic behavior,
not execution, security, auth, or isolation.

Anonymous diagnostic bootstrap remains `execution:false`, ready 503,
lifecycle 501, nested error. Authenticated durable AP2 and real
providers/AP3–AP6 are not implemented.

## AP0/AP1 artifacts

- `supervisor/contract.zig` — decimal u64, opaque IDs, envelopes, inventory, std.json bounded request validation, structured canonical detail, fingerprints
- `supervisor/bootstrap.zig` — consumes diagnostic documents; ignores `BackendState.ready` and qualified inventory for execution
- `supervisor/bootstrap_main.zig` — Linux TCP listener CLI (`serve`)
- `engine/contracts.zig` — typed injected adapter vtables; Auth/Store/FS/VM handles and AdapterError; defaults unavailable; live resume method is `resumeGuest` because `resume` is a Zig keyword. HTTP `POST /v1/sandboxes/{id}/resume` is unchanged.
- `docs/sandbox-api.openapi.yaml` — OpenAPI 3.1 with bootstrap vs planned status; remote MutualTLS only; local identity is `x-local-ipc-*`. This is a portable planned contract, not evidence every route executes.
- `tests/contract/**` — independent fixtures plus shared schema corpus
- `schemas/**` — JSON Schema for envelopes, decimal u64, opaque ids, create bodies
- `scripts/sandbox-probe.sh` — built linux-musl process probes on 127.0.0.1
- `scripts/sandbox-schema-validate.py` — pinned JSON Schema/OpenAPI fixture lane (`tests/contract/schema-pins.txt`)

`supervisor/api.zig` hosted `create` / `guestReady` / `startExec` success paths
are **not** composed into the listener.

## Execution advertisement rule

`inventoryAdvertisesExecution` only means inventory contains a record that
*could* qualify. Client-visible execution requires `capabilitiesFromComposition`
evidence: a **ready bound VM** whose kind/profile/image match that specific
qualified inventory record, live pause/resume, lifecycle, and required
auth/store/launcher/guest/policy/clock/entropy/image-registry controls.
Unrelated inventory rows, unbound VM metadata, missing pause, or missing
controls cannot advertise execution. Guest execution features stay false without execution; the planned wasm_core capability separately requires auth and durable store. The serializer rejects `execution:true` without matching bound evidence
and auth/store/pause. The diagnostic HTTP listener still never returns ready
200 or `execution:true`. Canonical `detail` is a structured object of
validated scalars, never caller JSON interpolated into the envelope. Explicit
JSON null is rejected for non-nullable request properties; omission remains
allowed. Schema bounds are enforced by the pinned Python JSON Schema/OpenAPI
lane, not by mirroring a regex in Zig.

## Next slice (AP2)

AP2 is not started. Planned work remains authenticated local IPC, durable
store, idempotency replay, leases, event cursors, and audit redaction.
Capabilities remain `execution:false` until a later slice qualifies a real
provider. This document does not claim that work.
