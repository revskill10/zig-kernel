# Cross-Platform Sandbox API Compatibility Plan

**Status:** proposed compatibility and qualification plan. No execution API in
this document is implemented by `zig-sandbox`.

**Publication rebaseline:** 2026-09-14 against selected accepted tree
`6c8c8ca0611005e7776f437f381c55a866a67e3c`.

**Implementation status (this checkout):** AP0/AP1 diagnostic slice is
**published in this tree** as recorded in
[sandbox-api-implementation.md](../docs/sandbox-api-implementation.md)
(bound-VM composition matching, typed adapter contracts, MutualTLS-only remote
OpenAPI, exact u64 JSON Schema/OpenAPI lane). The anonymous diagnostic
bootstrap reports `features.execution: false` and 501 `execution_unavailable`
using the nested diagnostic error envelope, with `/readyz` 503. This listener
does not serve live 401/403. Authenticated durable AP2 and real
providers/AP3–AP6 are not implemented. A pinned SQLite amalgamation wrapper
exists and is not Store/AP2. Native x86_64 UEFI bootstrap is a separate
qualification path and is not an API execution backend. See also
[README Sandbox API (diagnostics)](../README.md#sandbox-api-diagnostics).

**Audit date:** 2026-09-13 (original); rebaseline 2026-09-14.

**Scope:** a remote API and SDK surface that preserves useful observable
semantics from a historical local Torkbot Sandbox inspection while supporting
a Linux VM guest through separately qualified Linux, macOS, and Windows
providers. This is semantic compatibility, not a promise to copy TypeScript
names, private BSON frames, or local filesystem paths into HTTP. Torkbot is a
local reference, not a repository dependency.

## 1. Current truth

The current `zig-sandbox` is only the diagnostic bootstrap documented in
[README Sandbox API (diagnostics)](../README.md#sandbox-api-diagnostics) and
[sandbox-api-implementation.md](../docs/sandbox-api-implementation.md). It
reports `execution:false` and returns `501 execution_unavailable` for sandbox
paths. The diagnostic HTTP listener has no lifecycle backend, VM provider,
durable state, authentication, client SDK, host-folder export, or local-engine
mode. A separate unqualified private Bun TS0 helper package exists for local
helper / remote diagnostics; neither mode has an execution backend. This
plan does not alter that behavior.

The Torkbot reference is also not an HTTP service. Historical local inspection
of a private development package versioned `0.0.0-dev` (`package.json`) showed
an in-process Node.js library plus a signed native helper. Its one CLI command,
`setup-macos`, signs the local helper for Hypervisor.framework (`src/cli.ts`).
It has no REST routes, inbound HTTP auth, remote tenant management, OpenAPI
document, generic event feed, or snapshot/pause/resume operation. Those paths
were workspace siblings, not files in this checkout.

### 1.1 Pinned local reference manifest

These hashes identify the **historical local inspection** (2026-09-13) used
for this plan. They are not a tagged upstream release, not a git submodule,
and not installed with this repository.

| File (historical local path) | SHA-256 | Evidence |
| --- | --- | --- |
| `torkbot-sandbox/package.json` | `c674a94b7795dd4a4645dd65d524347b311194a92b1b1a338df188d1e623b2bd` | Private development package, Node 24+ contract, build/test entry points. |
| `torkbot-sandbox/README.md` | `ff7267990ee20327cf05413e99ee4ade6adf01c493bf10756a261f2338759e85` | Declared VM, storage, mount, process, PTY, and policy semantics. |
| `torkbot-sandbox/src/index.ts` | `4551fb2d802992178ea6b5fc65c95493013283c6322dc94bcd8915da3e04b627` | Exported TypeScript object model and validation. |
| `torkbot-sandbox/src/control-codec.ts` | `f9b29d4fdd92d2bf9dc9e4550837d9c508d798d505e457c2a2f001eff94392a8` | Private length-prefixed BSON host/guest messages. |
| `torkbot-sandbox/src/artifacts.ts` | `2cf3e6cfc9250d612ce2fa054d67f73a2a96d9806e9781921f3c102bbf660a65` | Then-selected native host targets. |

## 2. Torkbot reference inventory

The reference uses `defineSandbox(...).boot(...)`, returning a local object.
`SandboxInstance` exposes `exec`, streaming `spawn`, interactive `pty`,
guest `fs`, guest-routed `fetch`, `environmentFacts`, and `close`
(historical local inspection: `torkbot-sandbox/src/index.ts`). Its private
local control transport exchanges length-prefixed BSON frames for process
output/exit, guest filesystem operations, and guest connection data
(`torkbot-sandbox/src/control-codec.ts`). That wire format is not a public
remote API.

| Area | Actual local reference surface | Planned remote compatibility scope |
| --- | --- | --- |
| Definition/boot | Rootfs/image, resources, mounts, and network policy validate before helper launch; boot creates one VM. | Create/start from a versioned image/profile. Validate before allocation; use idempotency keys and resource generations. |
| Exec | argv, cwd, env, timeout, AbortSignal; buffered stdout/stderr and exit result. Timeout terminates the guest process group. | Bounded execution operation with argv only, exit/signal, output limits, timeout outcome, durable operation ID. Client abort only stops waiting. |
| Process/PTY/channels | `spawn` streams stdin/stdout/stderr and exit, and can request numbered full-duplex guest channels at descriptors 3 or above; `pty` supports terminal I/O, resize, signal, exit. | Durable process/terminal resources with bounded chunks and resumable cursor events. Planned typed guest channels use opaque channel IDs, never caller-selected server file descriptors. WebSocket or equivalent is planned only after stream qualification. |
| Guest files | stat/list/read/write/mkdir/remove/rename use guest absolute paths and typed metadata/errors. | Server-owned workspace/file handles with range/size, byte-name, symlink, and error rules in the versioned contract. |
| Mounts | Virtual FS, block device, and live host-directory `ro`/`rw` binding are distinct. | Keep uploads, authorized server live exports, and data volumes as distinct resources. A remote client path never becomes a server path. |
| Root state | Immutable QCOW2 plus ephemeral/COW/persistent overlays and flatten-to-image. | Explicit image lineage, durable volume, and materialized-image export. This does **not** imply VM checkpoint, snapshot, pause, or resume. |
| Network/secrets | Default-deny DNS/TCP/UDP/HTTP policy; trusted-destination HTTP header mutation; injected credentials remain host-side. | Service-owned egress and secret broker. Host/provider credentials never reach guest files/logs/events. An explicitly authorized future user-secret feature needs its own delivery, redaction, revocation, and audit contract. |
| Errors/events | JavaScript errors, selected typed filesystem/blob errors; local promises and streams, private `guest.*` frames. | JSON error envelope, HTTP status/retry rules, request ID, public event cursor/retention contract. Private frame names stay private. |
| CLI | Only local macOS helper signing. | Planned remote CLI/SDK may use the same API but never executes a fallback host child process. |

`storage.blob` can declare local, S3, GCS, and Azure storage with
provider-specific credentials (historical local inspection:
`torkbot-sandbox/src/spawn-options.ts`). That is a local host integration
capability, not a reason to accept storage credentials from untrusted remote
callers. The server owns durable-storage credentials.

### 2.1 TypeScript facade, remote callback broker, and local callback bridge

**Planned required compatibility profile:** `@zig-sandbox/sdk` provides a
Torkbot-shaped TypeScript facade.
Its `defineSandbox`, `rootfs`, `fs`, `storage`, and `network` helpers build
validated declarations. **Remote binding:** those helpers map to the versioned
HTTP resources in Section 3. **Local binding:** the same logical resource and
subsystem interfaces bind to authorized native adapters or Bun callback
adapters through a future `LocalAdapterRegistry` (proposed name, not shipped).
Selecting `LocalEngineTransport` only chooses how to reach the engine; it is
not the subsystem adapter registry and does not install filesystem, network,
policy, store, clock, image, or VM contracts. Local mode does not serialize
functions into remote HTTP JSON, and it does not require a user-managed API
or callback-broker server.

Its required planned API includes remote `boot`, `exec`, `spawn`, `pty`, guest
`fs`, guest-routed `fetch`, `environmentFacts`, `close`, and `rootfs.flatten`.
Each method first checks the selected profile capability and returns a typed
unavailable result until its matching server/provider or local adapter feature
is qualified. That is client ergonomics, not a second server API: a remote
HTTP server receives data, IDs, and bounded operation requests; it never
deserializes or executes a client's JavaScript function.

Illustrative planned usage only; these names are not an installable package,
not a TS0 runnable program, and not a final TypeScript signature:

```ts
const client = new SandboxClient({ transport });
const definition = client.defineSandbox({
  profile: "linux-vm/x64",
  image: { id: "linux-dev-v1", digest: "sha256:..." },
  rootfs: client.rootfs.cow({ volume: "machine-42" }),
  network: client.network.policy({ mode: "offline" }),
});
const vm = await definition.boot({ workspace: uploadedWorkspaceId });
try {
  const operation = await vm.exec(["/bin/sh", "-lc", "npm test"]);
  await client.operations.wait(operation, { signal }); // does not cancel it
} finally {
  await vm.close(); // planned durable stop/reap, not an implicit destroy
}
```

Illustrative planned `/local` library usage only; not shipped by TS0, not
helper/1, and not a runnable TypeScript program today:

```ts
import { LocalSandbox } from "@zig-sandbox/sdk/local";

const withHostFs = await LocalSandbox.open({
  helperPath,
  adapters: {
    filesystem: hostFolderFs({ roots: [approvedRoot], mode: "rw" }),
  },
});
await withHostFs.close();

const withSqliteFs = await LocalSandbox.open({
  helperPath,
  adapters: { filesystem: sqliteFs({ dbPath: approvedDb }) },
});
await withSqliteFs.close();
```

Rebinding filesystem adapters is a new open/epoch, not a mid-run privileged
hot-swap. The selected transport, server or local capability response, and
profile decide whether each call is available. The SDK never replaces a
rejected Linux VM call with a Node, Windows, or macOS child process.

Planned `vm.close()` and asynchronous disposal map to durable stop/reap: they
end the active VM and release running capacity, retain only declared eligible
persistent volume and export-origin state, and clean up explicitly ephemeral
state according to the resource policy. They do not mean destroy or tombstone
the sandbox. `destroy` remains a separate generation-fenced, idempotent server
operation. SDK aborting a wait/stream is neither close, durable cancel, nor
local adapter-registry revoke.

Torkbot virtual filesystems and network middleware are callbacks, so they
cannot be serialized in JSON. **Remote** callback compatibility therefore
requires a separately registered, separately deployed **planned callback
broker**, not a function string. That broker is an authenticated companion
for remote callers; it is not the local `/local` callback path:

1. The SDK registers an opaque callback ID for one sandbox/resource and its
   authenticated principal.
2. A Node sidecar, or an explicitly supported browser worker on an
   authenticated same-origin held-open channel, receives only typed requests
   for that ID.
3. Each request has a deadline, maximum request/response bytes, concurrency
   allotment, cancellation, and correlation ID. The broker applies backpressure
   rather than buffering without bound.
4. A disconnected, expired, unauthorized, slow, or overloaded callback fails
   the dependent guest I/O according to the declared mount/policy error. It is
   never retried as a host-execution fallback.
5. The server records callback capability and lease state, but never evaluates
   source, imports, closures, or browser/Node ambient authority.

A browser is not a general inbound server. It supports callback brokering only
through an active, authenticated same-origin connection that meets the
delivery/deadline contract; otherwise callback filesystem/policy features are
absent from its advertised SDK capability set.

**Remote entrypoint (`@zig-sandbox/sdk` / `/remote`):** the SDK remains a pure
remote client and never launches a VM or host process, and it must not fall
back to local helper spawn when the server rejects a call. Remote traffic
cannot activate a local adapter registry, spawn the local helper, or inherit
the embedding application's filesystem, network, or credential authority.

**Local entrypoint (`@zig-sandbox/sdk/local`, TS0 2026-09-14):** the SDK may
own a pinned Zig userspace helper and, later, a selected VM provider. That
local runtime is an explicit import, not a remote fallback. TS0 still reports
execution unavailable and speaks only the diagnostic helper/1 one-inflight
protocol; aborting that diagnostic call may tear down the helper/1 channel.
That teardown is a TS0 diagnostic fact, not the future executing-VM
wait-abort contract. Callbacks are absent and unadvertised. `LocalAdapterRegistry`,
bidirectional callback IPC, SQLiteFS, filesystem/network/policy callback
registration, guest mount bridges, and real provider execution remain
unavailable until a later version-negotiated bridge protocol plus
provider/adapter qualification pass.
The local helper source is an intended Windows/Linux
x64 draft until the actual host matrix passes; it is not qualified by
cross-compile.

**Planned Bun-local subsystem adapters.** A future Bun application imports
`/local` and registers typed adapter-contract handles at open. The SDK owns
the private bidirectional native-helper IPC, the callback registry, and their
lifetimes. A **local callback bridge** is an automatic SDK-owned component of
that LocalSandbox runtime; local mode does not require a user-managed API
server or callback-broker process. Automatic helper/dispatcher/provider
processes may exist, but the library owns and documents their lifetime and
authority. Bun JavaScript callbacks run on the embedding Bun event loop or an
SDK-owned, explicitly qualified Worker; they are never invoked from an
arbitrary native helper or provider OS thread. No function, source, `eval`,
or import string crosses the private IPC. Every call is versioned and bound
to runtime, lease, generation, resource, principal, adapter version, and
declared rights, with separate engine-request and callback-request
namespaces, bounded queues and bytes, deadlines, cancel, revoke, and
parent-death behavior independent of ordinary JS finalization. Cancellation
and revocation scopes are distinct: a wait/stream `AbortSignal` detaches and
settles only that waiter; a callback-request cancel/deadline revokes only
that invocation and rejects its late response under the adapter's
fence/unknown-side-effect contract; explicit durable operation cancel is a
separate fenced engine operation; explicit revoke of one resource, lease,
or registration revokes only that scope, its handles, and dependent I/O and
epoch, while unrelated adapters and leases remain usable; runtime close,
helper/Bun death, or explicit whole-registry revoke tears down that
runtime's registry. TS0 helper/1 diagnostic-channel abort teardown remains
a one-inflight diagnostic fact and is not the future executing-VM
wait-abort contract. A new runtime, rebind, restart, or revoke creates a
new epoch scoped to the affected resource or registry; IDs and replies from
prior epochs are rejected and are never promoted onto the new runtime or
resource. Local callback IPC byte ownership follows the shared rule in
[sandbox.md §8.1](sandbox.md#81-required-typescript-sdk): copied
request/reply payloads or owned versioned byte handles; the producer
releases source ownership only after copy or transfer; internal
borrowed/scratch/invocation buffers release on completion, cancel, or
revoke; delivered copied or transferred bytes remain caller-owned and valid
until caller disposal or GC, including after completion, cancel, or later
revoke of handles/authority; a late canceled callback cannot publish a new
result; Worker transfer, if used, detaches sole ownership; the initial
profile rejects shared-memory shortcuts. See
[sandbox.md §5.1](sandbox.md#51-swappable-subsystem-contracts) for the full
subsystem map and [sandbox.md §8.1](sandbox.md#81-required-typescript-sdk)
for SDK ownership and TS0 limits.

This local callback bridge is not the remote callback broker. For remote
callers, the trusted authenticated callback-broker companion remains a
separately deployed service with narrowly granted callback and, where
approved, local-folder authority. It still does not select or launch the VM
provider for remote callers. The authenticated server-side provider companion
owns VM launch for remote mode. Identities, leases, and failure modes stay
explicit rather than being inherited from the SDK process.

### 2.2 Storage, folders, architecture, and integer fidelity

The reference distinguishes immutable base image, COW overlay, ephemeral COW,
persistent QCOW2 overlay, and a separately mounted block device (historical
local inspection: `torkbot-sandbox/src/index.ts`). Remote compatibility retains
these distinct resource kinds. A blob overlay is machine-root state; a blob
block is a guest data device; neither is a generic snapshot and neither may
silently become the other.

Masked folders have exact roles: a read-only bind can hide named guest paths,
while a read-write bind requires separate writable mask storage for hidden
paths (same historical `index.ts` inspection). The future API must distinguish
live RO export, live RW export with mask-store resource, uploaded copy, and
block volume. It may reject an incapable provider; it may not call a copy live
or collapse mask storage into the exported tree.

Guest ISA and every unsigned 64-bit quantity are wire fields, not host
accidents. An image/profile declares `guest_arch` independent of server OS.
Byte offsets, byte lengths, disk sizes, dirty limits, and numeric stream byte
positions are non-negative decimal strings in JSON with checked bounds. Opaque
resource IDs and event cursors are protocol strings, not numeric counters. The TypeScript
facade may expose `bigint`, but serializes the specified decimal string and
rejects unsafe JavaScript `number` values. This prevents JSON precision loss
and makes x64/arm64 selection observable.

## 3. Planned HTTP compatibility profile

This is a design target only. The final versioned OpenAPI document must
negotiate capabilities. Existing bootstrap responses remain unchanged until a
qualified implementation exists.

### 3.1 Resources and operations

All planned mutations require an idempotency key. Mutable resources have opaque
IDs, generations, timestamps, and state. State changes supply the expected
generation and receive `409 conflict` when stale.

| Resource | Planned operations | Semantic requirement |
| --- | --- | --- |
| Capabilities | `GET /v1/capabilities` | Truthfully list provider, guest ABI/image profile, export, terminal, snapshot, event, and auth features. Absence means unavailable. |
| Sandbox | Create, get/list, start, stop, pause, resume, reset, destroy | Lifecycle is durable and server-owned. Stop differs from destroy; IDs are never reused for another sandbox. |
| Execution | Create/get/cancel bounded `exec` operation | Command is argv, never an implied host shell. Durable cancel is explicit, idempotent, and auditable. |
| Process/terminal/channel | Create/get/signal/resize/close and attach stream; create bounded typed guest channels | Guest-only features with process/output/duration/attachment limits. Numeric server file descriptors are never API authority. |
| Workspace/files | Create; upload/download/list/stat/mutate inside policy | Upload/download transfer bytes; they are not implicit mounts. Client and server path scopes differ. |
| Export | Create/revoke authorized server live `ro` or `rw` export | Only a local provider resolves export roots. Remote callers name approved export IDs, never server filesystem paths. |
| Image/volume/snapshot | Inspect lineage; create volume; export materialized image; optional immutable snapshot/restore | Live pause and durable snapshot are separate capability-gated contracts with fences, external-resource checks, and recovery rules. |
| Events | Bounded stream or poll using `after` cursor | Scope, monotonic cursor, retention expiry, reconnection, byte/rate limits are stable contract fields. |

The reference has no generic event feed. Its local process streams do not
establish public stream semantics. Planned event records therefore include
resource scope, cursor, stream identity, sequence, encoding/binary data, and
truncation state. Cursor expiry is a typed error requiring a fresh resource
read, not an implicit replay promise.

Pause, resume, checkpoint, and restore must not be represented as working
merely because the reference supports durable root overlays. They are planned
only after a provider demonstrates guest clock/network behavior, storage
consistency, recovery, external-export safety, and cross-version image rules.
A qualified live pause retains reserved VM state; stop/start does not. Restore
failure is terminal or recovering, never a silent cold boot.

### 3.2 Planned route mapping

The [normative planned route table](sandbox.md#6-server-specification) controls
route names, fields, and statuses. This plan maps the Torkbot-shaped facade to
those routes instead of inventing vendor REST. The table is the **remote HTTP**
binding. Local `/local` binds the same logical operations to the SDK-owned
helper and a future adapter registry; it does not POST JavaScript to these
routes, and it does not require the application to run this HTTP API.

| Planned facade action | Planned HTTP route |
| --- | --- |
| `client.capabilities()` | `GET /v1/capabilities` |
| `definition.boot()`, list, inspect | `POST` or `GET /v1/sandboxes`; `GET /v1/sandboxes/{id}` |
| `vm.exec()`, inspect, durable cancel | `POST /v1/sandboxes/{id}/executions`; `GET /v1/sandboxes/{id}/executions/{exec}`; `POST /v1/sandboxes/{id}/executions/{exec}/cancel` |
| `vm.fs` and byte transfer | `PUT/GET /v1/sandboxes/{id}/files` |
| `vm.environmentFacts()` | `GET /v1/sandboxes/{id}` plus immutable image/profile facts in capabilities; richer observed facts are a planned extension. |
| guest-routed `vm.fetch()` | Planned execution-network extension, capability gated by the qualified egress profile; no endpoint exists today. |
| authorized live export and attach/detach | `GET/POST /v1/exports`; `POST/DELETE /v1/sandboxes/{id}/mounts` |
| `vm.spawn()`, `vm.pty()`, typed channels | Planned extension of execution resources, gated by terminal/channel capability; no route exists today. |
| `rootfs.flatten()` | Planned authorized image-materialization extension, gated by image/export capability; no endpoint exists today. |
| event poll/follow | `GET /v1/sandboxes/{id}/events` with cursor or SSE |
| reset/stop/start/pause/resume/snapshot/restore/destroy | The corresponding planned sandbox subresource routes and `DELETE /v1/sandboxes/{id}` |
| operation wait | `GET /v1/operations/{id}` and bounded event observation |

The process/PTY/channel subresource remains unassigned until guest-agent and
stream protocol qualification. It uses opaque process/channel IDs and never
exposes server FD numbers or local BSON frames.

### 3.3 Auth and error contract

Production authentication does not inherit the bootstrap's anonymous
diagnostics. A deployment selects local UDS peer identity on Linux/macOS,
Windows named-pipe peer identity when qualified, or remote TLS 1.3 with mTLS
as the proposed default. Bearer tokens are a separately qualified extension
with explicit issuer, audience, rotation, and revocation rules; they are not an
implicit mTLS fallback. A loopback TCP listener still authenticates; loopback
is an address scope, not an identity. The server maps the resulting identity to
tenant, sandbox, workspace, export, and secret scopes.

```json
{
  "code": "unavailable",
  "message": "the selected Linux VM provider is not available",
  "request_id": "opaque-id",
  "retryable": true,
  "detail": {}
}
```

`detail` is optional, bounded, and redacted: no host path, command line,
credential, raw provider error, or guest secret. The canonical categories in
[sandbox.md](sandbox.md#6-server-specification) cover invalid request,
unauthenticated, forbidden, not found, conflict/stale generation/idempotency,
limit/payload too large, cursor expired, unsupported host/image, capacity,
guest failure, resource limit, deadline, unavailable, and internal failure.
Their documented route status mappings control SDK vectors. The bootstrap's
current `execution_unavailable` 501 remains correct until a qualified backend
replaces it.

An SDK `AbortSignal` closes only that caller's wait/stream. It neither
asserts workload completion, cancels the workload, nor revokes a local
adapter registry. Durable cancellation is a separate idempotent operation.
Local callback-request cancel, durable execution cancel, scoped
resource/lease/registration revoke, and whole-runtime/registry teardown
remain the distinct scopes in §2.1 and
[sandbox.md §8.1](sandbox.md#81-required-typescript-sdk). 501 is non-retryable feature absence; bounded
network/timeout/503 retry policy belongs to the caller; 401 starts the chosen
transport's authentication flow.

## 4. Required host and guest profiles

The unit of compatibility is a declared guest workload profile, not “run this
file anywhere.” A profile names guest OS/ABI, architecture, image digest,
init/agent protocol, device features, and limits. A host may advertise it only
after meeting the corresponding provider gate.

| Planned profile | Execution location | It may claim | It must never claim |
| --- | --- | --- | --- |
| `linux-vm/<arch>` | Qualified Linux VM guest | Pinned Linux image, declared guest ABI, and guest-compatible tool bundles. | A Windows PE, macOS Mach-O, or arbitrary host executable runs in the Linux guest. |
| `wasm-core-p1` | Qualified WASM/WASI runtime inside `linux-vm/<arch>` | Only its pinned runtime, ABI/WASI capabilities, quotas, and guest mounts. | Browser privilege, portable-SDK authority, host mounts, KVM, or normal Linux-computer behavior. |
| `native/<os>-<arch>` | Explicit separately designed matching-host backend | Only the named native ABI and documented isolation. | Linux VM/binary compatibility or a fallback from a requested Linux VM. |

Native Windows workload support, if ever added, is a distinct
`native/windows-<arch>` profile. It is not Windows-host support for Linux
VMs, and it is not evidence that Linux ELF workloads run on Windows. A request
for `linux-vm/x64` fails typed-unavailable when its provider is absent; it
never invokes a Windows shell, macOS process, `child_process`, or a host tool
as a substitute.

### 4.1 Mandatory provider qualification

| Required host | Planned provider | Mandatory evidence before it can advertise `linux-vm` | Current state |
| --- | --- | --- | --- |
| Linux | **Proposed default:** QEMU/KVM for declared x64/arm64 guest | KVM access, CPU virtualization, image/architecture check, boot/agent, accounting, default-deny egress, export policy, live pause/resume, shutdown/recovery, hostile guest corpus. | Not implemented; bootstrap has no KVM requirement because it executes nothing. |
| macOS | **Proposed default:** QEMU/HVF, matching guest ISA, signed/notarized helper | Entitlement/signing, HVF availability, boot/agent, virtio network/filesystem, mount identity/metadata where offered, live pause/resume/recovery, no unsigned-helper fallback. | Not implemented. Reference evidence is only a `darwin-arm64` helper and local signing workflow. |
| Windows | **Proposed default:** QEMU/WHPX on Windows x64, authenticated named-pipe control, and Job Object process limits | WHPX feature/virtualization, boot/agent, named-pipe identity, Job Object containment, networking, storage/export semantics, live pause/resume/recovery, installer/signing, rejection when unavailable. WSL is not presumed equivalent. | Not implemented. A future remote client is not local hosting. |

QEMU documents KVM for Linux, HVF for macOS, and WHPX for Windows in its
[system introduction](https://www.qemu.org/docs/master/system/introduction.html),
and describes WHPX as QEMU's Windows hardware-acceleration backend in its
[WHPX guide](https://www.qemu.org/docs/master/system/whpx.html). Those pages
are current-master capability references only; they do not pin a QEMU release,
prove security properties, or close the qualification gates above. libkrun and
WSL2 are separately proposed adapters only after their own contracts pass;
neither is an implicit fallback from the stated defaults.

The reference itself rejects a rootfs whose architecture differs from
`process.arch` (historical local inspection: `torkbot-sandbox/src/index.ts`)
and then selected only `darwin-arm64` or `linux-x64-gnu`
(`torkbot-sandbox/src/artifacts.ts`). The future API must expose incompatible
host/provider/guest architecture before scheduling; it must not emulate it
invisibly.

## 5. Planned TypeScript and WebAssembly boundaries

| Planned artifact | Responsibility | Prohibited authority |
| --- | --- | --- |
| `packages/zig-sandbox-client` root and `/remote` (`@zig-sandbox/sdk`, `@zig-sandbox/sdk/remote`) | Node/browser remote client, versioned types, selected transport, capabilities, bounded operations/events. | VM launch, shell/process execution, host-directory access, local helper spawn, undocumented provider fallback, authorization decisions. Importing the package does not grant those. |
| `packages/zig-sandbox-client` `/local` (`@zig-sandbox/sdk/local`) | Bun-focused local library: SDK-owned helper, future `LocalAdapterRegistry`, private IPC, callback registry/lifetime, and capability-gated operations. TS0 remains diagnostic helper/1 only. | Ordinary host workload exec; ambient directory export; remote-to-local spawn; unauthenticated path/SQL authority; function serialization/`eval`; JS callbacks on native helper threads; claiming Bun `sqlite` is POSIX filesystem or a host-jail fallback. Qualified host-folder and SQLiteFS adapters may be registered only through the versioned filesystem contract. |
| `packages/zig-sandbox-core-wasm` | `wasm32-freestanding` codec, validation, stable error mapping, advisory transition checks. Separate from `/local` and from guest Wasm. | Ambient imports, filesystem, sockets, subprocesses, KVM, mounts, persistence, token acquisition, execution authority. |
| `guest/wasm/` | In-VM WASI profile and hostile-module corpus. Separate from the portable SDK core. | Browser privilege inheritance, SDK-core authority, unrestricted host tools, implicit native fallback. |

Node may select mTLS or a UDS transport where deployed; UDS is Node-only.
Browsers require a same-origin proxy and cannot assume CORS, UDS, direct mTLS,
or host-path access. Browser and remote entrypoints never launch a VM, host
process, or local helper. In-process Node-API bindings are a separate future
track and do not qualify Bun `/local`. Node/Deno/macOS/ARM remain unqualified.
TypeScript and portable-core implementations consume the same OpenAPI/JSON
vectors for capability/error/cursor/idempotency behavior. Passing portable-core
vectors does not qualify guest WASI execution.

## 6. Phases and gates

| Phase | Planned deliverable | Gate |
| --- | --- | --- |
| AP0 | Freeze semantic scope, IDs/generations/idempotency, error envelope, event retention, path namespaces, capability schema. **In this slice.** | Contract tests prove bootstrap remains `execution:false`/501 and no API model calls host execution. |
| AP1 | `docs/sandbox-api.openapi.yaml` and vectors for lifecycle, processes/PTY/channels, files, exports, events, auth, errors, 64-bit fields. Depends on sandbox WP1. **Diagnostic fixtures and OpenAPI are in this slice;** live 401/403 are not served by the anonymous listener. | Independent fixtures validate unknown features, 64-bit decimal rejection, and documented 401/403/409/422/429/501/503 outcomes. |
| AP2 | Authenticated durable server/store/audit core, no provider yet. **Not started.** The SQLite amalgamation wrapper is not this store. | Crash/restart, leases, redaction, idempotency, cursor expiry pass; capabilities still say no execution. |
| AP3 | `engine/*`, provider/guest/workspace/export adapters for Linux QEMU/KVM `linux-vm/<arch>` with mandatory live pause/resume. Depends on sandbox WP5-WP9. | Fresh boot, exec, PTY/channels, files, blob/block/overlay and masked-export conformance, transfer, egress denial, pause/resume of same execution/event cursor, stop/destroy, cleanup, hostile guest corpus pass on pinned manifest bytes. Snapshot/restore stays optional. |
| AP4 | macOS QEMU/HVF and Windows QEMU/WHPX provider adapters with the same mandatory live pause/resume contract. Depends on AP3 and sandbox WP5-WP9. | Each Section 4.1 row passes, including mount/network/pause/recovery; unsupported combinations fail typed with no native fallback. |
| AP5 | `packages/zig-sandbox-client/*`, `packages/zig-sandbox-core-wasm/*`, `guest/wasm/*`, remote trusted callback-broker companion, and future Bun `/local` callback bridge. Depends on sandbox WP10b-WP10c. | Remote: package, Node/browser transport, callback tenant binding/disconnect/deadline/backpressure, callback egress non-escalation, ABI/import/Worker, guest-WASI, cursor/reconnect, abort-versus-cancel, no-host-exec tests pass. **Future Bun-local (not TS0):** a fresh application imports `/local`, registers host-folder then SQLiteFS adapters, opens and owns helper/dispatcher/provider with no user-managed API or broker process, and runs the same guest filesystem conformance plus callback failure/revoke/queue/cleanup, abort-scope, epoch-rejection, and byte-ownership tests; remote parity without host-exec fallback. See [sandbox.md §11.2](sandbox.md#112-adapter-conformance). |
| AP6 | Release/runbook qualification and callback/export/provider operational evidence. Depends on AP1-AP5. | Signed artifacts, SBOMs, recovery drills, provider/image support matrix, callback/broker revocation drills, and evidence manifest are published per candidate. |

The broader prerequisites remain in [sandbox.md](sandbox.md): [swappable
contracts](sandbox.md#51-swappable-subsystem-contracts), [server
specification](sandbox.md#6-server-specification), [TypeScript
SDK](sandbox.md#81-required-typescript-sdk), [WebAssembly
interfaces](sandbox.md#82-required-webassembly-interfaces), and
[qualification gates](sandbox.md#12-qualification-gates).

## 7. Final acceptance evidence

No phase closes on an API mock or a successful local shell command. Each
candidate records server/SDK/core/image/provider hashes, host OS/build/arch/
virtualization facts, guest profile, and test evidence proving:

1. Linux workloads run only in the selected qualified Linux guest profile.
2. Unavailable hosting returns typed failure on every host without fallback.
3. Client/server/portable-WASM vectors interpret capabilities and errors alike.
4. Aborting a wait leaves durable workload state observable and leaves
   registered local adapters usable; cancellation is explicit. Prior-epoch
   IDs are rejected after a new runtime/rebind/restart.
5. Remote client paths cannot become exports; each live export is authorized.
6. Host/provider credentials are absent from guest files, logs, error detail,
   events, and export metadata. Any explicitly authorized user-secret feature
   passes its separate delivery, redaction, revocation, and audit corpus.
7. Every advertised optional capability has recovery and hostile-workload
   evidence for that provider.
