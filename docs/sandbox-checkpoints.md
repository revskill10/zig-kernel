# Sandbox checkpoints — implementation and acceptance plan

**Status:** planned contracts and gates. Nothing in this document is
implemented by `zig-sandbox`.

**Date:** 2026-09-14.

**Does not change:** OpenAPI, runtime capabilities, or engine code. Snapshot
routes already exist as planned 501 operations; this plan maps future work
onto them without claiming they execute.

Vendor inventory: [audits/smolvm-features.md](../audits/smolvm-features.md).
Act-in-guest interaction: [sandbox local CI](sandbox-local-ci.md) and the
act-job case in §10.

## 0. Current product

Backed by this checkout:

| Fact | Evidence |
| --- | --- |
| Diagnostics only | [README.md](../README.md), [sandbox-api-implementation.md](sandbox-api-implementation.md) |
| `features.execution: false` | [schemas/capabilities-diagnostic.json](../schemas/capabilities-diagnostic.json) |
| `features.snapshots: false` | same schema |
| `/readyz` 503 | OpenAPI `x-bootstrap-status: 503` |
| Sandbox lifecycle 501 | `POST /v1/sandboxes`, pause, resume, snapshots, restore |
| `GET /v1/operations/{id}` 404 on bootstrap | [sandbox-api.openapi.yaml](sandbox-api.openapi.yaml) |
| No VM execution, checkpoint, SQLite control store, SDK, native Linux, or act qualification | [sandbox-api-implementation.md](sandbox-api-implementation.md) AP2–AP6 not started |

`engine/contracts.zig` already has swappable `Auth`, `Store` (idempotency
transactions), `Clock`, `Policy`, `Filesystem` (`guest_disk` / `sqlitefs` /
`host_export`), and `VmBackend` with `pause` / `resumeGuest`. Those seams are
unavailable by default. They are **not** a CheckpointStore.

Independent capabilities below stay `false` until the named gate passes. Docs
or SmolVM tests do not flip them.

## 1. Independent capabilities (all false until qualified)

| ID | Meaning | Not the same as |
| --- | --- | --- |
| `live_pause_resume` | Pause/resume the same generation and event cursor | Durable snapshot |
| `checkpoint_capture` | Quiesce, retain CPU/RAM/disk boundary, stream, abort | Dedup storage |
| `checkpoint_restore` | Materialize private writable state and rebind | Capture |
| `checkpoint_store_dedup` | Content-addressed immutable objects + full manifest | Dirty-page capture |
| `checkpoint_export` | Standalone artifact independent of the live store | Capture |
| `checkpoint_gc` | Reclaim unreferenced objects under pin rules | Retention scheduling |
| `branch` / `branch_batch` / `worker_ready` | CoW child and handshake | Snapshot published |
| `dirty_page_incremental_capture` | Future; read only dirty RAM | Dedup storage (vendor precedent is full RAM read) |

SmolVM incremental storage still reads retained RAM and inspects disk assets;
unchanged chunks are reused. zig-kernel must not label that dirty-page
capture. See
[incremental-checkpoints.md](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/docs/incremental-checkpoints.md).

## 2. Planned contracts (swappable)

Every interface is a typed injected adapter. File hardlinks are **one**
adapter. Portable contracts use owned references and transactions, not
host paths, nlink counts, or SmolVM CLI flags.

### 2.1 `ProviderCapture`

Owner: qualified `VmBackend` profile (Linux guest). Methods:

| Method | Required semantics |
| --- | --- |
| `preflight(source, profile)` | Fail closed on missing runtime stream capability, incompatible devices, or uncapturable resources **before** pause |
| `quiesce(source, generation, fence)` | Cross-process source lock; guest sync; freeze vCPUs/devices |
| `retainBoundary(source)` | Capture CPU/device state and exact disk-chain boundary while paused |
| `resumeSource(source)` | Resume the source independently of artifact publication |
| `streamRetained(source, sink, budget)` | Hash/compress retained RAM after resume; honor byte/time/I/O budgets |
| `abort(source, capture_id)` | Release pause/stream; leave source running if it was resumed. No-output only if abort wins **before** atomic publication. If publish has crossed or parent sync is uncertain: report committed or reconcile-required; never delete that artifact |
| `compatibility(manifest, dest)` | Format/runtime/CPU/device/host checks before restore resources execute |

Capture lifecycle (durable names, not marketing):

```text
admitted → quiesced → retained_generation → source_resumed
        → streaming → verified → published
```

`source_resumed` is **not** `published`. Clients must not treat HTTP 200 of a
still-open stream, a resumed PID, or a pause-time header as a durable
checkpoint.

Admission: **one complete capture per source** at a time. Overlapping
hash/compress of retained generations is a resource amplification, not a
feature. Bound CPU, RAM, I/O, total logical bytes, and unique physical bytes
per tenant.

### 2.2 `CheckpointStore`

Owner: server-side object store. Methods:

| Method | Required semantics |
| --- | --- |
| `stage(capture_id)` | Private staging; not visible as a checkpoint |
| `putObject(id, bytes, codec, raw_digest, raw_len)` | **Enforced** immutability: validate digest/length/codec on ingest and on reuse/read; atomic insert-if-absent; never replace an existing ID; identical verified content is idempotent reuse; conflicting content is rejected; adapter exclusively owns published objects |
| `putZeroExtent(...)` | Explicit zeros, including overwriting previous nonzero pages |
| `commitManifest(manifest)` | Full index of every logical file/chunk; no dangling refs |
| `publish(checkpoint_id)` | Atomic no-replace; parent dir durable; refuse clobber |
| `pin` / `unpin` | Restore, export, and in-flight capture hold pins |
| `gc()` | Exclusive against publish; never delete a pinned or referenced object |
| `exportStandalone(checkpoint_id)` | Transportable artifact; does not require the original store |
| `verify(checkpoint_id)` | Manifest + every object digest/length/codec before restore allocate |

Hardlink filesystem adapter (vendor precedent, not the contract):

- Same-filesystem outputs.
- Object identity = digest of uncompressed bytes.
- Same ID already present: verify bytes/digest/length/codec; never replace.
  Identical content reuses; conflict is rejected. Vendor
  `persist_noclobber` + verify-on-exists is one insert-if-absent precedent.
- Reference count via `nlink` is adapter-local. Remote object storage and
  SQLite reference tables must implement the same pin/GC contract with
  owned references, not Unix nlink.
- Exclusive adapter ownership of the object tree. Ordinary writers must not
  mutate published inodes. Writable hardlinks remain a shared corruption
  domain if that ownership is violated (checksums detect; they do not
  recover).

1 MiB chunk size, SHA-256, zstd level 3, and zero-chunk encoding are vendor
precedent
([checkpoint_store.rs](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L13-L38)).
They are **not** a mandatory universal ABI. A future adapter may use other
chunk sizes/codecs if the manifest records them and restore verifies them.

Protected directory handles, no-follow symlink policy, and bounded
decompression (`window_log_max` or equivalent plus exact decoded length) are
required of every adapter. Path-then-open after a symlink_metadata check is
insufficient for a multi-tenant service.

### 2.3 `RestoreMaterializer`

| Method | Required semantics |
| --- | --- |
| `materialize(checkpoint_id, dest)` | Fresh private writable memory and disks; never writable-map a shared object |
| `compatCheck(manifest, dest_host)` | Fail before allocating on format/runtime/CPU/device mismatch |
| `rebind(network, ports, secrets, mounts)` | Explicit policy; default refuse uncapturable externals |

Restored writes must not mutate the retained checkpoint or sibling restores.

### 2.4 Control-plane seams (already sketched, still unavailable)

These stay swappable and distinct from payload storage:

| Seam | Existing sketch | Checkpoint role |
| --- | --- | --- |
| `Auth` | [engine/contracts.zig](../engine/contracts.zig) `Auth` | Tenant ownership of sandbox/checkpoint/operation IDs |
| `Store` (control) | idempotency `begin/commit/rollback/replay` | Operation journal, pins, fences — **not** RAM/disk bytes |
| `Clock` | monotonic + boot id | Capture duration, lease expiry, crash generation |
| `Policy` | admission | CPU/RAM/I/O/storage budgets; uncapturable resources |
| Scheduler | not present | Explicit later adapter; SmolVM has none |
| Crypto | not present | Encryption/signing of memory/disk secrets; key lifecycle |

SQLite **control state**, SQLiteFS **guest filesystem**, and checkpoint
**payload objects** are three different things. Shipping any one does not
ship the others. AP2's durable store remains unverified.

### 2.5 Full manifest (no false base-delta chain)

Each published checkpoint is independently restorable after the previous
point and the object cache are deleted. If a format uses no backing
checkpoints, `base_dependencies` is empty. Dedup is a storage optimization
inside the store, not a restore chain.

Required metadata (opaque IDs are protocol strings):

| Field | Rule |
| --- | --- |
| `format` | Versioned; reject unknown |
| `runtime_abi` | Example vendor value `libkrun-portable-snapshot-v1` is vendor-specific |
| `device_profile` | Example vendor value `smolvm-basic-v1` is vendor-specific |
| `cpu_contract` | Host/guest architecture and feature set |
| `kernel` / `guest_image` | Digests |
| `storage_profile` | Disk/overlay/block-I/O engine actually used |
| `digests` | Manifest and every object |
| `generation` / `owner` / `fences` | Source generation, tenant, pause/capture fences |
| `base_dependencies` | Explicit list; empty when the format is fully indexed |
| `resource_blockers` | Why capture was refused, if any |
| `logical_bytes` / `unique_physical_bytes` / `reused_logical_bytes` | Accounting |

## 3. Async states, uncertainty, cancellation

| State | Meaning |
| --- | --- |
| `admitted` | Passed preflight and budgets; source lock not yet exclusive |
| `quiesced` | vCPUs frozen |
| `retained_generation` | CPU/device/disk boundary cloned |
| `source_resumed` | Workload running; artifact not durable |
| `streaming` | Retained RAM in flight |
| `verified` | Index + objects checksummed |
| `published` | Atomic no-replace success + parent sync |
| `uncertain` | Publish may have crossed; parent sync or crash left the outcome unconfirmed. Reconcile; do not treat as absent |
| `failed` / `cancelled` | Abort or failure **before** atomic publication: no usable checkpoint ID; staging reclaimable. Not used once publish has crossed or parent sync is uncertain |

Commit uncertainty (rename succeeded, later `sync` error, process crash
between index write and publish): a **reconcile** operation walks the
journal and store. It may confirm published, mark abandoned staging, or
return `uncertain` for operator intervention. It must not blindly recapture
and must not delete a directory that might already be the published object.

Cancellation: abort the stream; source stays alive if already resumed
(`source_resumed` ≠ `published`). The no-output guarantee applies **only**
if cancellation wins before atomic publication begins: then nothing is
published and prune reclaims owned staging. Once publish has crossed, or
parent-directory sync is uncertain, durable state is committed or
reconcile-required. Cancellation must report that outcome, preserve the
artifact, and must not classify it as disposable staging or claim output
is absent. Do not delete a committed or uncertain checkpoint to "cancel."
Killing only the capture client is the vendor script's intended
pre-publish interrupt check
([test_incremental_checkpoints.sh](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/tests/test_incremental_checkpoints.sh)).

GC vs pin races: prune waits for exclusive lock; pins held across restore
and export; GC never removes an object still named by any retained
manifest.

Zero-chunk overwrites: a logical page that becomes zeros must not restore
the previous nonzero object bytes (`StoredFile.chunks` `None` precedent).

## 4. Public API and SDK (proposed, not implemented)

Do not accept arbitrary remote store paths. Server owns store roots.

Opaque IDs only (`snapshot_id`, `operation_id`, `sandbox_id`).

### 4.1 Map onto existing planned routes

These routes already exist in
[sandbox-api.openapi.yaml](sandbox-api.openapi.yaml) and remain 501 on the
diagnostic listener. This plan does **not** claim they are live.

| Existing route | Planned checkpoint meaning |
| --- | --- |
| `POST /v1/sandboxes/{id}/pause` | Live pause of the same execution/event cursor. **Not** a durable snapshot. |
| `POST /v1/sandboxes/{id}/resume` | Live resume with `pause_fence`. Not restore. |
| `POST /v1/sandboxes/{id}/snapshots` | Admit capture; return `202` + `Operation`. Body today is `GenerationBody`; future qualified fields stay additive and gated. |
| `POST /v1/sandboxes/{id}/restore` | Restore from `RestoreBody.snapshot_id` into this sandbox generation. |
| `GET /v1/operations/{id}` | Capture/restore/export/gc progress. Bootstrap 404. |
| `GET /v1/capabilities` | Advertise `snapshots` / `pause_resume` only after composition evidence (same rule as `execution`). |

### 4.2 Proposed operations (not in OpenAPI yet; do not implement in this slice)

When a later OpenAPI slice is allowed, add capability-gated:

| Operation | Notes |
| --- | --- |
| `GET /v1/sandboxes/{id}/snapshots` | List tenant-owned IDs + manifests (no raw RAM) |
| `GET /v1/snapshots/{snapshot}` | Metadata, pin state, logical vs physical bytes |
| `POST /v1/snapshots/{snapshot}/export` | Standalone artifact; pin during export |
| `POST /v1/snapshots/{snapshot}/pin` / `unpin` | Explicit pins |
| `POST /v1/stores/{store}/gc` | Server-owned store ID; not a host path |
| `POST /v1/operations/{id}/cancel` | Abort capture/stream **before** publish. After publish crossed or parent sync uncertain: report committed or reconcile-required; do not unpublish |
| `POST /v1/operations/{id}/reconcile` | Commit-uncertainty recovery |

CLI/SDK (planned names, not shipping):

```text
zig-sandbox snapshot create --sandbox sbx_...          # planned
zig-sandbox snapshot restore --sandbox sbx_... --snapshot snp_...
zig-sandbox snapshot export  --snapshot snp_... --out artifact
zig-sandbox snapshot gc --store sto_...
```

TypeScript SDK and embeddable Wasm SDK **delegate to a qualified provider**.
There is no magical native VM inside the browser. Wasm may hold handles and
stream bytes; it does not implement libkrun or KVM.

### 4.3 Retention, backup, crypto (separate)

| Concern | Rule |
| --- | --- |
| Object GC | Reclaims unreferenced store objects |
| Retention | Expires checkpoint **directories/IDs** after policy; only after a newer durable success if the policy says so |
| Scheduling | External/job adapter; serialize per source; alert on failure |
| Backup | Copy/export complete checkpoints off-host; store is not a backup service |
| Encryption | Memory and disk payloads may contain secrets; encrypt at rest with tenant keys; do not bake CI secrets into default checkpoints |
| Tenant separation | No cross-tenant object reuse unless an explicit shared-image policy exists and is qualified |

## 5. External resources (no all-state pause promise)

Capture is conditional. Uncapturable resources fail preflight with a
specific code, or follow a **tested** quiesce/detach/rebind policy.

| Resource | Default | Allowed only after a named test |
| --- | --- | --- |
| Host-mounted folders | refuse | detach to guest-private copy, then capture |
| GPU / Vulkan / CUDA | refuse | profile with device-state restore evidence |
| SSH agent | refuse | detach |
| Host Docker socket | refuse always | never a qualification path |
| Guest Docker daemon | refuse until §10 | quiesced idle daemon profile, or active-job profile |
| Published sockets (Unix/other socket publications) | refuse | separately qualified detach/rebind; portable capture rejects nonempty `published_sockets` |
| Qualified TCP host-port mappings | rebind **host** listener; preserve captured **guest** ports | #1248; occupied host port is conflict (`PORT_IN_USE` with guest port) |
| Remote volumes / custom DNS / inter-VM net | refuse | explicit rebind contract |
| External TCP peers / GitHub / registries | not restored | reconnect after resume |
| Credential lifetimes | not restored | re-inject via secret broker; do not default-checkpoint secrets |

Guest topology (the captured set of guest ports) is **fixed** on restore.
The host-side listener is **recreated** at a requested or original host
port; it is not the original socket. Existing external TCP connections are
not preserved by mapping. Do not refuse all TCP port publications while
also promising #1248 rebinding, and do not treat arbitrary published
sockets as rebindable port mappings.

Ordinary successful run with host mounts does **not** imply capturable state.

## 6. Sequence

Each CP gate is fail-closed. Later gates may not skip earlier ones.
Capabilities remain false until the gate's acceptance matrix passes on the
exact artifact.

### CP0 — contracts and storage fixture (no VM)

- Freeze adapter vtables for `ProviderCapture`, `CheckpointStore`,
  `RestoreMaterializer` as unavailable-by-default seams (same style as
  `engine/contracts.zig`).
- In-process fake store: put/get/zero-extent/full manifest/atomic
  no-replace/pin/gc/export.
- Same-ID `putObject`: identical verified content reuses; different content
  is conflict and does not replace; concurrent publish of one ID has one
  winner.
- Corrupt/missing chunk, oversized index, path-escape (`../`), zero-overwrite,
  deleted-old-point independence, concurrent writers.
- **Does not** set `features.snapshots`.

### CP1 — store atomicity on a real filesystem or object adapter

- Crash before publish: no visible checkpoint; staging reclaimable.
- Crash after publish, error on parent sync: reconcile, do not recapture blindly.
- Conflicting `putObject` / concurrent publish of the same object identity:
  existing object unchanged on conflict; no silent replace.
- Concurrent capture vs prune vs pin.
- Disk full / `sync` failure.
- Bounded decompression bomb rejected before restore allocate.
- Descriptor-relative no-follow opens on the store root.
- Unix hardlink adapter may be the first implementation; Windows remains
  `unsupported` until a non-nlink adapter is qualified.
- **Does not** require a VM.

### CP2 — qualified VM capture/restore

Prerequisite: a real Linux-guest provider with live pause/resume (AP3-class).
Native zig-kernel is **not** this gate.

- Preflight missing stream capability fails before pause.
- Two generations; restore each; private branch/write isolation.
- Source continues after capture and after stream cancel.
- CPU/runtime/device incompatibility fails closed.
- Lineage depth and QCOW/backing depth fail independently at their ceilings.
- Host-port rebind without guest-port change; occupied host port is conflict.
  Guest topology stays fixed; the host listener is recreated; existing TCP
  peers are not preserved. Published sockets remain a capture refuse unless
  a named detach policy exists.
- UID/cgroup/restart recovery if the provider claims isolation.
- Metrics: `source_pause_ms`, `capture_total_ms`, `logical_bytes`,
  `unique_compressed_bytes`, `reused_logical_bytes`, index/link overhead,
  retained physical bytes, CPU/RAM/I/O of the capture worker.
- Act-job case: §10, after local-CI ACT1 topology exists. Idle warm image
  first; active job only as a named profile.

### CP3 — API / SDK

- Authenticated AP2 store + Auth required before advertising snapshots.
- Map §4 routes; opaque IDs; server-owned stores; idempotency keys.
- TypeScript SDK methods delegate to the service. Wasm SDK same.
- CLI planned commands in §4.2 labeled planned until this gate.
- Diagnostic bootstrap remains 501/`snapshots: false` until composition
  evidence exists (same serializer rule as `execution`).

### CP4 — schedule, retention, cross-platform, native

- Scheduler adapter: one capture per source; keep previous success until new
  publish; then expire per policy; then GC.
- macOS HVF and Windows WHPX/WHP: Linux **guest** only; each host is its own
  provider qualification. SmolVM Windows bundle updates do not pass this gate
  (`cfg` unsupported; README branch/checkpoint unavailable).
- Native zig-kernel capture is a separate gate after native process/memory
  ABI exists. Linux-guest success never closes it.
- Encrypted payloads and tenant-separated GC.

## 7. Acceptance failure matrix

Every row is a required test. Pass means the stated outcome, not a crash or
silent success.

| Case | Required outcome |
| --- | --- |
| Missing chunk / digest mismatch | Restore and reuse fail closed; no partial VM |
| Truncated stream / no index | Nothing published; retry may reuse intact objects |
| Old checkpoint and cache deleted | Newer fully indexed point still restores |
| Concurrent capture and prune | No lost live checkpoint; no use-after-gc |
| Crash before publish | No checkpoint ID; staging GC-able |
| Crash after publish | Reconcile confirms or `uncertain`; never blind delete |
| Disk full / `sync` error | Failed operation; no clobber of existing ID |
| Stream cancel before publish; source alive | No output; source markers unchanged; retry works |
| Stream cancel racing publish | Committed or reconcile-required; never delete a possible published object; never claim output absent |
| Cancel after committed publication | Report already committed; artifact preserved; not staging |
| Conflicting `putObject` (same ID, different verified content) | Reject; existing object unchanged |
| Concurrent publish of same object ID | One winner; no silent replace |
| Zero chunk overwrites old bytes | Restored zeros, not previous nonzero object |
| Private restored writes | Source and sibling restores unchanged |
| Incompatible CPU/runtime/device | 422/unsupported before allocate |
| Branch depth / QCOW depth | Independent errors at 32 (or the profile's documented ceiling) |
| Auth path escape | `../`, symlink swap, caller host path → deny |
| Occupied host port on restore | Conflict with guest port in diagnostic; guest topology unchanged |
| Uncapturable mount/GPU/SSH/host-docker/published sockets | Preflight refuse (or documented detach). Not the same as qualified TCP host-port rebind |
| Tenant A GC | Cannot delete tenant B objects |
| Bounded decompression | Reject before large alloc |

Keep failed gates visible in capabilities and in qualifier output. A skipped
or unavailable host is **unavailable**, not pass.

## 8. Metrics (required on CP2+)

Report separately, never one "checkpoint time" number:

- `source_pause_ms`
- `capture_total_ms`
- `logical_bytes`
- `reused_logical_bytes`
- `unique_compressed_bytes`
- index/link overhead
- retained physical bytes after GC
- capture worker CPU/RAM/I/O

Storage savings do not imply proportional pause-time savings.

## 9. Platform and provider notes

- Host Windows/macOS/Linux: Linux guest. Native Windows/macOS runner jobs are
  unsupported unless an actual provider exists.
- First qualified host is Linux/KVM (or a libkrun-compatible Linux provider)
  as a **Linux VM provider** milestone. Native Zig kernel replacement is
  later and separate.
- Nested hardware virtualization (`--nested` / guest `/dev/kvm`) is a
  distinct optional profile. Ordinary checkpoints and act jobs do not require
  it.

## 10. Act-job checkpoint case (after act preflight)

Prerequisite: [sandbox-local-ci.md](sandbox-local-ci.md) ACT1 guest with
**guest-owned** dockerd. Never mount the host Docker socket.

Safest first warm checkpoint:

1. Linux guest + idle dockerd + preloaded immutable runner/action images.
2. **Before** per-run secrets, event identity, or credentials are injected.
3. Restore materializes a **private** writable Docker data disk and unique
   run/network/cache identity.
4. Then inject secrets/event and start the job.

Active act/dockerd/containerd/services span threads, overlay mounts, disk
transactions, timers, and external sockets. Capture is allowed only for a
**named resource profile** that has passed RAM/device/disk consistency tests
on that profile. External registries, GitHub APIs, and credential lifetimes
need explicit reconnect/rebind/quiesce policy; they are not implied by CPU
resume.

Resume vs new-job rerun:

| Mode | Semantics |
| --- | --- |
| New job | Fresh generation, new operation ID, replay workflow from event |
| Restore idle warm image | Same image/digest, new run identity, then start job |
| Resume captured in-flight job | Same generation only if fences, operation IDs, and external side effects reconcile; two restored copies must not both complete the same CI operation |

Default: do not bake secrets into checkpoints. Prefer idle/quiesced warm
state until an active-job profile passes.

This case does not move ACT1. It is a CP2 profile on top of a qualified
guest-local CI image.
