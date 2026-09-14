# SmolVM feature inventory for zig-kernel plans

**Audit date:** 2026-09-14.

**Status:** source inventory and planning evidence. This is not runtime
qualification, not a vendor update, and not a claim that zig-kernel currently
captures, restores, stores, or runs VMs.

**Scope:** focused SmolVM checkpoint, branch, store, and related host/guest
features that a future zig-sandbox provider might wrap. Implementation and
acceptance live in [sandbox checkpoints](../docs/sandbox-checkpoints.md) and
[sandbox local CI](../docs/sandbox-local-ci.md). This file records what the
pinned upstream source actually does, what the local dirty tree contains, and
what remains unproven.

Statements marked **Observed source** are file/line facts. Statements marked
**Documented upstream change** come from the 44-commit comparison and are not
independently re-proven here. Statements marked **Test definition** exist as
code or scripts; they were not executed. **Run evidence** is absent.

## 1. Identity

| Record | Value | Meaning |
| --- | --- | --- |
| Local vendor Git HEAD (source comparison receipt) | `b9fa2857ca95334d3c425a582293d8b5c1253826` (2026-09-07) | Checkout identity. Dirty/untracked work is already present. No fetch, reset, or vendor write was performed. |
| Pinned upstream `main` | [`9d442abd49169f3b2971f877fa687ef5763d9dc7`](https://github.com/smol-machines/smolvm/commit/9d442abd49169f3b2971f877fa687ef5763d9dc7) (2026-09-13) | Port-rebinding fix [#1248](https://github.com/smol-machines/smolvm/pull/1248). Primary source identity for this audit. |
| Latest release | [v1.16.0](https://github.com/smol-machines/smolvm/releases/tag/v1.16.0) (2026-09-13) | Includes incremental store [#1232](https://github.com/smol-machines/smolvm/pull/1232). Does **not** include [#1248](https://github.com/smol-machines/smolvm/pull/1248). |
| Distance | 44 commits ahead of local HEAD | Comparison is commit metadata, not a clean vendor tree. |
| Selected-file match | 20 pinned files match `9d442abd` after CRLF normalization | Content equivalence of those files only. Not a clean checkout. Raw SHA-256 still differs because of CRLF. |

Primary immutable links for every upstream claim below are GitHub blob URLs at
`9d442abd49169f3b2971f877fa687ef5763d9dc7`, the v1.16.0 tag, and the cited PRs.
Do not treat a local `vendor/smolvm` path as a public document dependency.

### 1.1 Current zig-kernel product (this checkout)

Backed by existing files, not by SmolVM:

| Surface | File | Today |
| --- | --- | --- |
| Diagnostic HTTP | [README.md](../README.md), [docs/sandbox-api-implementation.md](../docs/sandbox-api-implementation.md) | Linux/amd64 listener. `/healthz` 200, `/readyz` 503, `features.execution: false`, sandbox lifecycle 501. |
| Capabilities | [schemas/capabilities-diagnostic.json](../schemas/capabilities-diagnostic.json) | `snapshots: false`, `forks: false`, empty backends/images. |
| Planned snapshot routes | [docs/sandbox-api.openapi.yaml](../docs/sandbox-api.openapi.yaml) `POST /v1/sandboxes/{id}/snapshots` and `/restore` | `x-bootstrap-status: 501`. OpenAPI is a portable planned contract, not execution. |
| Engine seams | [engine/contracts.zig](../engine/contracts.zig) | `VmBackend.pause_resume` defaults false. `Store` is control-plane idempotency, not checkpoint payload storage. `FsKind.sqlitefs` is a filesystem adapter kind, not a checkpoint object store. |
| AP2+ | [docs/sandbox-api-implementation.md](../docs/sandbox-api-implementation.md) | Auth, durable store, VM providers, SDKs, native Linux, and act qualification are not implemented. |

There is no VM execution, live pause, checkpoint capture, CheckpointStore,
SQLite control store, TypeScript/Wasm SDK, native Linux ABI, or act-in-guest
qualification in this product today.

### 1.2 Source / test / run

| Kind | What it is | What it is not |
| --- | --- | --- |
| Source | Pinned files and the 44-commit log | Passing VMs, installed libkrun, or this product |
| Test definition | Unit tests in `checkpoint_store.rs`, `tests/test_incremental_checkpoints.sh`, `tests/checkpoint_checksum.rs`, `tests/test_api_uid_checkpoint.py`, `tests/test_api_checkpoint_ports.py` | Evidence those tests passed on Linux, macOS, Windows, or the currently installed runtime |
| Run | None collected for this audit | Docs or tests do not become fresh VM proof |

## 2. Pinned 20-file set

All 20 local counterparts match the pinned commit after CRLF normalization.
Blob URLs are the public identity. Raw SHA-256 of local dirty copies still
differs because of CRLF; those local hashes are not the GitHub raw hashes.

| Path | Blob | Role |
| --- | --- | --- |
| `README.md` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/README.md) | Host/guest matrix; Windows branch/checkpoint unavailable |
| `docs/incremental-checkpoints.md` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/docs/incremental-checkpoints.md) | `--store` workflow; full-index ownership; no scheduler/retention |
| `src/checkpoint_store.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs) | 1 MiB SHA-256/zstd/zero chunks; hardlink publish/prune/export |
| `src/portable_checkpoint.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/portable_checkpoint.rs) | Format 4 capture lifecycle, eligibility, restore compatibility |
| `src/api/types.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/types.rs) | Block I/O, capacity/memory fields, port specs |
| `src/api/handlers/machines.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/handlers/machines.rs) | HTTP capture streams standalone file; restore rebinds host ports |
| `src/api/mod.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/mod.rs) | Route timeouts; `POST/PUT /{id}/checkpoint` |
| `src/cli/machine.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/cli/machine.rs) | `checkpoint` / `checkpoint-prune`; `--nested`; `--block-io`; `--docker-socket` |
| `src/agent/manager.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/agent/manager.rs) | Agent/runtime management (not exhaustively re-audited here) |
| `src/agent/krun.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/agent/krun.rs) | Optional `krun_set_nested_virt` / `krun_check_nested_virt` |
| `src/agent/launcher.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/agent/launcher.rs) | Launch/restore path |
| `src/agent/launcher_dynamic.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/agent/launcher_dynamic.rs) | Dynamic launch |
| `crates/smolvm-protocol/src/forkpoint.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/crates/smolvm-protocol/src/forkpoint.rs) | Branchpoint protocol constants |
| `crates/smolvm-agent/src/forkpoint.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/crates/smolvm-agent/src/forkpoint.rs) | Guest forkpoint helper |
| `crates/smolvm-agent/src/branchpoint.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/crates/smolvm-agent/src/branchpoint.rs) | Typed wait/arm/park/release/activate/worker-ready |
| `crates/smolvm-agent/src/dirwatch.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/crates/smolvm-agent/src/dirwatch.rs) | Guest inotify wait for branchpoint markers |
| `tests/test_incremental_checkpoints.sh` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/tests/test_incremental_checkpoints.sh) | Intended real-VM store/export/interrupt checks |
| `tests/test_api_checkpoint_ports.py` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/tests/test_api_checkpoint_ports.py) | Host-port rebind; guest-port topology preserved |
| `tests/test_api_uid_checkpoint.py` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/tests/test_api_uid_checkpoint.py) | UID/seccomp/cgroup through branch/checkpoint/restore |
| `tests/checkpoint_checksum.rs` | [blob](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/tests/checkpoint_checksum.rs) | Damaged sidecar rejected before extract |

Not among those 20, but previously hash-pinned in the local review (do not
confuse with the CRLF-normalized set): `src/cli/pack.rs` (CLI `--store` /
`--export-from` argument surface), `src/agent/fork.rs` (lineage/QCOW depth),
`AGENTS.md`, and guest-agent `main.rs`. Keep both records. This audit cites
pinned files for public claims.

## 3. Release versus `main`

[v1.16.0](https://github.com/smol-machines/smolvm/releases/tag/v1.16.0) is the
workspace bump after incremental live-checkpoint storage
([#1232](https://github.com/smol-machines/smolvm/pull/1232),
`a4e28bddad4e6d144ad6bdef4ebf310f57809a6a6`).

Pinned `main` `9d442abd` is **after** that tag:

1. [#1243](https://github.com/smol-machines/smolvm/pull/1243) bound parallel pack compression.
2. [#1248](https://github.com/smol-machines/smolvm/pull/1248) rebind checkpoint host ports without changing guest ports, and preserve startup errors (`9d442abd`).

A product that pins v1.16.0 still needs an explicit decision about #1248. This
plan treats `9d442abd` as the source identity and #1248 as required restore
semantics. Neither the tag nor `main` is zig-kernel runtime evidence.

Windows release bundles were rebuilt as part of libkrun bumps
([#1217](https://github.com/smol-machines/smolvm/pull/1217),
[#1232](https://github.com/smol-machines/smolvm/pull/1232)). An updated
Windows binary **does not** qualify branch/checkpoint: stored publish/prune are
`cfg(not(unix))` unsupported
([checkpoint_store.rs:401-407](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L401-L407),
[535-540](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L535-L540)),
and README says `machine branch` / `machine checkpoint` are not yet available
on Windows
([README.md:300](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/README.md#L300)).

## 4. The 44 commits, grouped

Source comparison receipt: local HEAD `b9fa2857` → upstream `9d442abd`, `ahead_by: 44`.
Do not treat this as a giant unique-feature list. Release bumps and small
fixes are grouped.

### 4.1 Release bumps (not separate product features)

Workspace version commits: 1.14.2 (#1185), 1.14.3 (#1203), 1.14.4 (#1209),
1.14.5 (#1216), 1.14.6 (#1221), 1.15.0 (#1235), 1.15.1 (#1239),
1.16.0 (#1242). Nix flake hash/cut-release repairs (#1225 / #1222) belong
with packaging, not checkpoint semantics.

### 4.2 Branchpoint, worker-ready, shared RAM generations

| Change | PR | Planning note |
| --- | --- | --- |
| Typed branchpoint protocol; child identity; dirwatch instead of poll | [#1178](https://github.com/smol-machines/smolvm/pull/1178) | Guest handshake, not host checkpoint |
| Document branchpoint; checkpoint wording | [#1183](https://github.com/smol-machines/smolvm/pull/1183), [#1186](https://github.com/smol-machines/smolvm/pull/1186) | Docs |
| Workload-readable release/identity files | [#1205](https://github.com/smol-machines/smolvm/pull/1205) | Non-root workloads |
| Shared RAM generations for active branches | [#1236](https://github.com/smol-machines/smolvm/pull/1236) | Live branch accounting, not durable store |
| Bound/share/reclaim live branch memory | [#1200](https://github.com/smol-machines/smolvm/pull/1200), [#1204](https://github.com/smol-machines/smolvm/pull/1204), [#1206](https://github.com/smol-machines/smolvm/pull/1206) | Host capacity, not CheckpointStore |

Observed source: `branchpoint.rs` typed wait/arm/park/release/activate and
worker-ready, generation markers, idempotent activation (`AlreadyDone` vs
rejected other token)
([branchpoint.rs:1-106](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/crates/smolvm-agent/src/branchpoint.rs#L1-L106),
tests from [451](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/crates/smolvm-agent/src/branchpoint.rs#L451)).
`dirwatch.rs` uses inotify+poll on Linux; non-Linux fallback sleeps 5 ms;
untimed wait holds no kernel timer so waiters can sit inside a snapshot
([dirwatch.rs:1-100](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/crates/smolvm-agent/src/dirwatch.rs#L1-L100)).
That is guest Linux implementation detail. It does not qualify host
checkpoint support.

### 4.3 Incremental store, deferred RAM stream, export/prune

[#1232](https://github.com/smol-machines/smolvm/pull/1232) is the incremental
**storage** feature. Observed source:

- 1 MiB chunks, SHA-256 of uncompressed bytes, zstd level 3, explicit zero
  chunks (`None` in the index, including a page that was previously nonzero),
  index version 1
  ([checkpoint_store.rs:13-38, 119-184](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L13-L38)).
- Bounded compressed metadata, `window_log_max(23)`, exact decoded length/hash
  ([63-76](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L63-L76),
  [410-449](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L410-L449)).
- Same-filesystem store/output; shared capture lock; staged objects; `sync_all`;
  no-clobber publish via Linux `renameat2` / macOS `renamex_np`
  ([88-116](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L88-L116),
  [504-533](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L504-L533)).
- Exclusive prune; abandoned staging; delete objects only at `nlink == 1`;
  non-Unix prune unsupported
  ([345-407](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L345-L407)).
- Materialize private writable state; standalone export without original store
  ([452-570](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L452-L570)).
- `--store` requires `SAVE_CAPABILITIES` reply `OK deferred-stream-v1`
  ([portable_checkpoint.rs:24-45, 460-467](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/portable_checkpoint.rs#L460-L467)).
- Pause captures CPU/device and disk boundary; source resumes; then
  `FINISH_SAVE_STREAM` hashes retained RAM; publish only after index completion
  ([538-622](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/portable_checkpoint.rs#L538-L622)).

This is **not** dirty-page-only capture. RAM is still read. Unchanged chunks
are reused. Each retained checkpoint owns a full index and hard links to every
required object. Deleting an older checkpoint or the cache must not break a
newer one
([docs/incremental-checkpoints.md:25-30](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/docs/incremental-checkpoints.md#L25-L30);
unit test
[checkpoint_store.rs:631](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/checkpoint_store.rs#L631)).
There is no false base-delta chain.

1 MiB / SHA-256 / zstd / zero extents are **vendor precedent**, not a
mandatory zig-kernel ABI.

CLI `--store` exists: `MachineCmd::Checkpoint` / `CheckpointPrune`
([machine.rs:337-341](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/cli/machine.rs#L337-L341))
and the documented commands
([incremental-checkpoints.md:6-16, 81-95](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/docs/incremental-checkpoints.md#L6-L16)).
HTTP capture is **not** that API: `CaptureOptions::default()` then stream a
standalone `.smolcheckpoint`
([machines.rs:185-258](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/handlers/machines.rs#L185-L258);
route
[api/mod.rs:256-259](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/mod.rs#L256-L259)).

No automatic periodic scheduler or age/count retention
([incremental-checkpoints.md:55-59](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/docs/incremental-checkpoints.md#L55-L59)).
Object GC (`checkpoint-prune`) is not retention policy.

### 4.4 Lineage versus QCOW depth

Documented: live branch lineage and QCOW2 backing chain are each bounded at
32 levels; store dedup does not flatten or reset either; batch sibling count
is not depth
([incremental-checkpoints.md:46-53](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/docs/incremental-checkpoints.md#L46-L53)).

### 4.5 UID / cgroup / restart recovery

[#1240](https://github.com/smol-machines/smolvm/pull/1240): reclaim VM cgroup
before kill; memfd allowance; preserve lineage UIDs; stage checkpoints in the
confined machine directory; prevent duplicate VMM launches; bound shutdown
during recovery. Test definition:
[test_api_uid_checkpoint.py](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/tests/test_api_uid_checkpoint.py)
requires a privileged local service and inspects `/proc/<pid>/status` UID,
seccomp, and `smolvm-vm-*.scope` cgroup. Not run here.

Capture staging also chowns the temporary tree to the lineage UID when
present
([portable_checkpoint.rs:341-363](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/portable_checkpoint.rs#L341-L363)).

### 4.6 Port rebinding without guest-port change

[#1248](https://github.com/smol-machines/smolvm/pull/1248) / test definition
[test_api_checkpoint_ports.py](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/tests/test_api_checkpoint_ports.py).
Observed restore rule: requested host ports may change; captured guest ports
must match
([machines.rs:263-285](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/handlers/machines.rs#L263-L285)).
Occupied host ports are a 409 `PORT_IN_USE` with guest port in the error.
Guest port topology is fixed; the host listener is recreated. Existing TCP
peers are not restored merely by mapping. This is not capture of arbitrary
`published_sockets`, which portable capture rejects.

### 4.7 Other documented upstream changes (not assumed runtime-qualified)

| Change | PR | Source note |
| --- | --- | --- |
| Selectable block I/O (`sync` default; Linux `async` / restricted io_uring) | [#1198](https://github.com/smol-machines/smolvm/pull/1198) | [types.rs:112-115](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/types.rs#L112-L115); CLI `--block-io` [machine.rs:650-652](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/cli/machine.rs#L650-L652) |
| Nested virtualization (`--nested`, `/dev/kvm` in guest) | [#1231](https://github.com/smol-machines/smolvm/pull/1231) | Optional libkrun symbols [krun.rs:88-94](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/agent/krun.rs#L88-L94). **Not** required for ordinary Docker/act job containers |
| Guest memory metrics (status asks the guest, not only the host) | [#1230](https://github.com/smol-machines/smolvm/pull/1230) | Documented change. Inspected `MachineInfo` still also reports host VMM RSS/PSS [types.rs:774-794](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/types.rs#L774-L794) |
| Operation-specific API timeouts | [#1237](https://github.com/smol-machines/smolvm/pull/1237) | Bounded routes 300 s; exec/start/pull own deadlines; checkpoint stream has no generic request timeout [api/mod.rs:194-319](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/mod.rs#L194-L319) |
| Bound parallel pack compression | [#1243](https://github.com/smol-machines/smolvm/pull/1243) | Documented change; not independently re-read in pack sources here |
| Honor smaller-than-template disks | [#1199](https://github.com/smol-machines/smolvm/pull/1199), [#1227](https://github.com/smol-machines/smolvm/pull/1227) | Packaging/disk, not checkpoint store |
| Init as root; packed USER | [#1188](https://github.com/smol-machines/smolvm/pull/1188), [#1190](https://github.com/smol-machines/smolvm/pull/1190), [#1202](https://github.com/smol-machines/smolvm/pull/1202), [#1215](https://github.com/smol-machines/smolvm/pull/1215) | Image/user identity |
| Open machine without creating disks | [#1197](https://github.com/smol-machines/smolvm/pull/1197) | Status-before-start |
| Pack launch/manifest/overlay | [#1150](https://github.com/smol-machines/smolvm/pull/1150), [#1174](https://github.com/smol-machines/smolvm/pull/1174) | Pack, not live checkpoint |
| libkrun bundle rebuild (all four platforms) | [#1217](https://github.com/smol-machines/smolvm/pull/1217) | Binary refresh ≠ checkpoint qualification |

Minor fixes grouped: fabric receive busy loop (#1201), TCP relay spawn cleanup
(#1210), delete-on-full-FS (#1219), archive symlink resolve (#1220), boot
failure console (#1229), pack-pull progress (#1218), export-helper disk sizing
(#1238), forget externally deleted machines (#1241), virglrenderer Nix path
(#1224).

## 5. Feature matrix (planning capabilities)

Every zig-kernel capability below is **false** until a named provider profile
passes its gate. Docs/tests in SmolVM do not flip these bits. These names are
planning capabilities, conceptually unavailable; they are not fields in the
current runtime schema. Existing actual fields remain `execution` /
`snapshots` / `forks` and `VmBackend.pause_resume`.

| Capability | SmolVM observed/documented | Independent of | zig-kernel today |
| --- | --- | --- | --- |
| `live_pause_resume` | Source pauses vCPUs during PREPARE_SAVE; not a public pause API | Durable checkpoint | `false` ([engine/contracts.zig](../engine/contracts.zig) default) |
| `checkpoint_capture` | Portable format 4 + deferred RAM stream | Dedup store | `false` |
| `checkpoint_restore` | Materialize private state + CPU/runtime/device checks | Capture | `false` |
| `checkpoint_store_dedup` | Content-addressed objects + full per-checkpoint index | Dirty-page capture (does not exist here) | `false` |
| `checkpoint_export` | Standalone file from store directory | Live VM | `false` |
| `checkpoint_gc` | Exclusive prune of nlink-1 objects + abandoned staging | Retention scheduler | `false` |
| `branch` | CoW child; `--branchable` | Durable checkpoint | `false`; OpenAPI `forks: false` |
| `branch_batch` / `worker_ready` | Typed branchpoint + `--wait-worker-ready` | Snapshot published | `false` |
| `shared_ram_generations` | #1236 documented | Dedup store | `false` |
| `lineage_depth_32` / `qcow_depth_32` | Separate 32-level ceilings | Dedup | not implemented |
| `host_port_rebind` | #1248; guest ports fixed | Capture | `false` |
| `uid_cgroup_restart_recovery` | #1240; test definition | Windows | `false` |
| `op_timeouts` | #1237 route classes | Checkpoint semantics | diagnostic listener only |
| `guest_memory_metrics` | #1230 documented | Capture | `false` |
| `bounded_compression` | zstd window bound; #1243 pack parallelism | Store ABI | `false` |
| `selectable_block_io` | `--block-io` / API `blockIo` | Checkpoint | `false` |
| `nested_virtualization` | `--nested` / libkrun optional symbols | Docker-in-guest | `false`; not required for act jobs |
| `periodic_scheduler` / `retention` | Explicitly absent | GC | `false` |
| `dirty_page_incremental_capture` | Not this feature | Dedup storage | `false` (future, separate) |

## 6. Capture blockers versus ordinary run

Ordinary run can mount host folders
([README.md:296](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/README.md#L296)).
That is not capturable host-external state. Portable capture rejects host
mounts, staged mounts, published sockets, remote volumes, host secret refs,
host-backed image layers, custom DNS, named inter-VM networking, Vulkan,
CUDA, Rosetta, SSH-agent forwarding, and Docker-socket forwarding
([portable_checkpoint.rs:1075-1128](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/portable_checkpoint.rs#L1075-L1128)).

`dirwatch.rs` watches the **guest** branchpoint directory. It is not host
folder-watch support and does not make host mounts checkpointable.

`--docker-socket` exposes the **guest** dockerd to the host
([machine.rs:676-678](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/cli/machine.rs#L676-L678))
and is rejected at capture. Guest-local Docker for act is a different
topology; see [sandbox local CI](../docs/sandbox-local-ci.md).

## 7. Durability, security, and platform limits (source-level)

- Source lock ends when the source resumes; hashing can overlap a later
  capture. Docs recommend one complete capture per source; there is no
  built-in scheduler.
- `source_resumed` ≠ durable published. A rename may succeed before a later
  directory-sync error. Reconcile that outcome; do not blindly recapture or
  delete.
- Shared hardlinked objects are a corruption domain: rewriting an inode
  through the cache affects every link. Checksums detect; they do not
  recover. Hashes are integrity, not authenticity.
- `read_object` checks symlink metadata then opens by path; not an atomic
  descriptor-relative no-follow policy. Production must own the store root.
- No encryption, signing, tenant auth, or authenticated manifest in
  `checkpoint_store.rs`. Captured RAM/disks can contain plaintext secrets.
- Stored publication is Unix-only. Windows ordinary run ≠ checkpoint
  capability.
- Portable packaging can move; live restore still requires matching
  format/runtime/CPU/device/host. Cross-platform API ≠ cross-OS live-state
  portability.

libkrun `PREPARE_SAVE` / `FINISH_SAVE_STREAM` internals were not available in
the inspected tree. Retained-RAM consistency is a required runtime capability
and a test target, not verified here.

## 8. Test definitions present

None of these were executed for this audit.

| Location | Intended check |
| --- | --- |
| `checkpoint_store.rs` tests (Unix/macOS) | Abandoned staging; unchanged/zero reuse and parent/cache independence; truncated capture; corruption; concurrent writers; malformed index/stream; sparse extents; no-overwrite publish; prune liveness; standalone export |
| `tests/test_incremental_checkpoints.sh` | Alpine VM, RAM/disk markers, two generations, restore, private branch, export, kill capture client during stream, unpublished output, source continuation, prune, retry |
| `tests/checkpoint_checksum.rs` | Damaged pack bytes fail before extract |
| `tests/test_api_uid_checkpoint.py` | Privileged service UID/seccomp/cgroup through nested branch/checkpoint/restore |
| `tests/test_api_checkpoint_ports.py` | Two restores with rebound host ports; invalid guest-port topology rejected |

## 9. Plan deltas (no implementation in this slice)

1. Keep SmolVM as an optional `VmBackend` candidate behind the same typed
   launcher/cgroup/identity/network/workspace/pause contracts as QEMU. Source
   availability is not qualification.
2. Split provider capture from CheckpointStore. Hardlinks are one adapter.
3. Do not copy `--store DIR` host paths into the public API. Server-owned
   opaque store IDs only.
4. Do not advertise HTTP capture as incremental storage. SmolVM itself does
   not.
5. Treat scheduling, retention, backup, encryption, and tenant isolation as
   new work.
6. Windows/macOS/Linux hosts all run a **Linux guest** for the sandbox
   product. SmolVM's Windows run support does not qualify checkpoint or
   native Windows jobs.

Missing external qualification remains an open gate.
