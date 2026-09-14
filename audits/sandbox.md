# Production Sandbox Audit and Implementation Plan

**Status:** audit and proposed implementation plan; not a deployment approval.

**Publication rebaseline:** 2026-09-14 against selected accepted tree
`6c8c8ca0611005e7776f437f381c55a866a67e3c`. This is not a new runtime
qualification.

**Bun TS0 SDK status (2026-09-14):** `@zig-sandbox/sdk` under
`packages/zig-sandbox-client/` is a private Bun 1.4.2 prerelease **draft**.
Local mode owns a Zig userspace helper (`zig build sandbox-helper`) over
private stdio pipes. Remote mode remains a pure client with no local fallback.
`create` and `exec` stay typed unavailable (`features.execution: false`,
readiness 503). Windows/Linux x64 are intended, not qualified, until the
actual host matrix retains receipts. This is not production execution, not an
npm registry package, not Alpine, and not a desktop. Node/Deno/macOS/ARM are
unqualified. Planned later: signed platform helper packaging, provider/Store
policy, Linux guest execution and act-in-guest same-conformance, optional
in-process Node-API, portable Wasm core and guest Wasm as separate tracks.
`bun:ffi` is not the production default.

**Implementation status (this checkout):** AP0/AP1 diagnostic listener is
published as recorded in
[sandbox-api-implementation.md](../docs/sandbox-api-implementation.md):
portable contract (`supervisor/contract.zig`), typed unavailable-by-default
seams (`engine/contracts.zig`), independent fixtures, JSON Schema/OpenAPI
lane, and OpenAPI 3.1 with MutualTLS-only remote security. The fail-closed
bootstrap is preserved (`features.execution: false`, `/readyz` 503, sandbox
lifecycle 501, nested diagnostic error). WP2–WP14 remain pending. AP2–AP6
production acceptance gates remain open; the TS0 draft AP5/WP10b subset does
not complete them. A pinned SQLite 3.53.4 amalgamation and Zig wrapper exist
(`vendor/sqlite/`, `engine/sqlite_c.zig`, `zig build test-store-dependency`);
they are **not** `engine/contracts.Store`, not a control database, and not
AP2. Native kernel/distro work is out of scope for SBX-API-001: this tree
has a bounded x86_64 UEFI bootstrap and hosted user-VM constructor, not
CPL3, Linux replacement, guest execution, Alpine, desktop, or Photon.

**Audit date:** 2026-09-13 (original); rebaseline 2026-09-14.

**Scope:** current plans, supervisor, guest execution path, build/CI/release,
the required server and CLI modes, and planned TypeScript and WebAssembly
interfaces.

**Excluded:** full production implementation, deployment, publication, a
kernel-security certification, and a completed production qualification. The
additive fail-closed bootstrap is included as current implementation evidence.

**Terminology:** statements labelled **Proposed** are review defaults, not
approved product or operations decisions.

**Source-location convention:** paths are repository-relative. In a shortened
reference, `api.zig`, `runtime.zig`, `jail.zig`, `qemu.zig`, and `workspace.zig`
mean `supervisor/`; `elf64.zig`, `userstack.zig`, and `capture.zig` mean
`src/proc/`; and `uaccess.zig`/`syscall.zig` mean `src/`. Local source links
point at files in this checkout, not stale line-number fragments. Historical
local inspection notes are unlinked text with date and limit; they are not
product evidence.

## 1. Assessment

The repository has a useful prototype layer: pure admission/session/workspace
policy, a QEMU argv builder, Linux-oriented fork/exec/pidfd code, an in-memory
API model, a fail-closed Linux/amd64 diagnostic HTTP listener, a pinned SQLite
amalgamation wrapper (not Store), and a separate native x86_64 UEFI bootstrap.
It does not provide a runnable production sandbox: the bootstrap has no
execution backend, there is no production CLI mode, durable control store,
applied launcher isolation, guest control service, SDK/Wasm artifacts, or
qualified workload environment.

The release blocker is composition. Existing host controls are largely policies
or standalone components, not an auditable path that authenticates a request,
persists a lease, creates isolated host resources, starts a VM, transfers
workspace bytes, executes a guest workload, streams bounded output, and
reliably recovers or destroys everything.

The target shape is one portable engine contract with Linux-first and required
macOS/Windows provider implementations, used by three entry points:

1. `zig-sandbox serve`: local IPC listener (UDS on Unix, named pipe on
   Windows) and, when explicitly configured, remote TLS.
2. `zig-sandbox`: remote client CLI.
3. `zig-sandbox run --local`: one-shot local ephemeral engine invocation
   through a qualified provider.

The current implementation remains Linux-only and has no execution backend.
The planned macOS/Windows provider path is defined in
[cross-platform API plan](sandbox-api.md). Each local host must either advertise
a qualified VM provider and capabilities or fail closed with `unsupported_host`;
it must never run the requested workload as a host child-process fallback.

## 2. Contract, evidence, and limits

This is an evidence-backed plan, not a claim that source-level intent is
enforced. No date, throughput, security-SLA, or unrun test result is inferred.

| ID | Evidence | Observation and boundary |
| --- | --- | --- |
| E1 | [build.zig](../build.zig) and [supervisor/main.zig](../supervisor/main.zig) | **Pre-bootstrap baseline (historical):** kernel artifacts and supervisor tests existed while `supervisor/main.zig` exported modules only. This explains the original F01 finding. |
| E1a | [build.zig](../build.zig) `sandbox-api` step, [bootstrap router](../supervisor/bootstrap.zig), [bootstrap CLI](../supervisor/bootstrap_main.zig), and [Dockerfile](../Dockerfile) | **Current diagnostic delivery:** Linux-musl `zig-sandbox` bootstrap and container API exist. `/healthz` is 200, `/readyz` is 503, capabilities say `execution:false`, and sandbox routes return 501; no VM/state operation is implied. Dockerfile copies `vendor/sqlite` for the amalgamation wrapper but does not start Store or execution. |
| E1b | Historical local inspection, 2026-09-13 sandbox-audit snapshot (logs not in this checkout; not a current release image) | **Historical audit snapshot only:** ReleaseSafe bootstrap build 3/3; regression 9/9 steps, 85/88 tests, 3 Linux skips. Docker linux/amd64 image `sha256:f5787133b2b0a2f6d067bf74b1c275babd43f28e12ccf9182be3ba5188c66310` smoke-tested as nonroot UID/GID 999. That digest is **not** a currently published or reproducible release image. Current public diagnostic record: [sandbox-api-implementation.md](../docs/sandbox-api-implementation.md) (75/75 `test-sandbox`, 175/175 hosted native+kernel command, 74/74 schema corpus, 15/15 diagnostic HTTP checks). Reproduce diagnostics with README Docker commands and `bash scripts/sandbox-probe.sh`. |
| E2 | `supervisor/runtime.zig`, `jail.zig`, `qemu.zig` | Linux runtime, jail specification, and exact-argv parts exist; no integrated launcher applies the specified controls. |
| E3 | [supervisor/api.zig](../supervisor/api.zig) and [bootstrap router](../supervisor/bootstrap.zig) | Prototype business logic is fixed-array/in-memory; the diagnostic listener reports unavailable execution. Neither supplies persistence, authenticated lifecycle, or VM operations. `supervisor/api.zig` success paths are not composed into the listener. |
| E4 | [build.zig](../build.zig) `qemu-bin` and `native-*` steps; [native-bootstrap.md](../docs/native-bootstrap.md); [qemu-verification-status.md](../docs/qemu-verification-status.md) | i386 `qemu-bin` ELF32 demo remains. This checkout also has a bounded native x86_64 UEFI/ELF/FAT16/smoke-initramfs slice. Neither is CPL3 userspace, Linux ABI, or a sandbox execution backend. |
| E5 | Historical local inspection, 2026-09-13 hosted-tests.log (not in this checkout) | **Historical audit snapshot:** Windows, Zig 0.16.0: `zig build test test-supervisor --summary all` 6/6 steps, 83/86 tests, 3 Linux skips. Current published hosted counts live in [sandbox-api-implementation.md](../docs/sandbox-api-implementation.md) and [native-bootstrap.md](../docs/native-bootstrap.md). |
| E6 | Historical local inspection, 2026-09-13 linux-checks (not in this checkout) | **Historical audit snapshot:** WSL Ubuntu 24.04, Linux 6.18.33.1-microsoft-standard-WSL2: 28 supervisor tests including Linux fork/exec/pidfd. Component evidence, not launcher integration. |
| E7 | Historical local inspection, 2026-09-13 kvm-smoke.log (not in this checkout) | **Historical i386 KVM smoke:** QEMU 8.2.2 KVM, one SMP, no NIC, debug-exit, host exit 3; `kernel-baremetal` SHA-256 `a2fc881b6a36b83b299cf3dd3ae614e26b349205c20648f12faf36bc722e9d0b`. No user program, hardened launcher, or hostile suite. Distinct from later native x86_64 UEFI TCG smoke in [native-bootstrap.md](../docs/native-bootstrap.md). |
| E8 | Historical local inspection, 2026-09-13 api-defect-probes.log | Two probes reproduced owner truncation/prefix authorization and admission accounting divergence in `supervisor/api.zig`. These are bugs, not a demonstrated host escape. |
| E9 | Historical local inspection, 2026-09-13 workspace-defect-probe.log | A link target `/workspace/../../etc/passwd` is accepted by `checkLinkTarget` while resolver policy rejects it. Helper inconsistency, not a demonstrated host escape. |
| E10 | [docs/sandbox-production-plan.md](../docs/sandbox-production-plan.md) | Existing plan identifies key missing work and predates the published diagnostic listener and native UEFI slice. |
| E11 | [docs/sandbox-api.openapi.yaml](../docs/sandbox-api.openapi.yaml); [docs/sandbox-abi.md](../docs/sandbox-abi.md) | OpenAPI is the portable planned contract plus diagnostic `x-bootstrap-status`. It is not evidence every listed route executes. |
| E12 | Kernel primary documentation | Cgroup v2 controls apply to host processes in their cgroup; they do not themselves limit guest process counts. [cgroup v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html) |
| E13 | QEMU primary documentation | VM behavior is controlled by a specific QEMU invocation/version and must be qualified on the pinned release build. [QEMU invocation](https://www.qemu.org/docs/master/system/invocation.html) |
| E14 | Linux seccomp/openat2 documentation | Seccomp filters its installing process; `openat2` supplies pathname-resolution restrictions for dirfd-based operations. [seccomp](https://docs.kernel.org/userspace-api/seccomp_filter.html), [openat2](https://man7.org/linux/man-pages/man2/openat2.2.html) |

The primary references support these narrow facts. They do not establish that
this repository’s host kernel, QEMU, runtime configuration, or deployment has
the intended security properties.

### 2.1 Truth matrix

| Area | Observed now | Production conclusion |
| --- | --- | --- |
| API | In-memory slots/events/ownership/state methods plus diagnostic HTTP listener (`execution:false`, ready 503, lifecycle 501) | Not durable, authenticated, lifecycle-capable, or restart-safe. AP2 not started. |
| Runtime | Historical WSL supervisor component tests; no applied launcher | No full launcher, cgroup/ns/seccomp application, or failure-rollback qualification. |
| QEMU | Pure hardening argv; historical i386 KVM smoke; separate native x86_64 UEFI TCG smoke | No launched sandbox VM through runtime; neither smoke is execution isolation. |
| Guest | Modelled x64 policy/loader, i386 demo, hosted user-VM page-table constructor (`test-native-user-vm`; no CR3 switch/CPL3) | No CPL3 process, Linux ABI, static ELF64 guest run, or agent protocol. |
| Workspace | Policy and metadata; SQLite amalgamation wrapper only | No durable dirfd-safe workspace transfer; no SQLiteFS; no Store. |
| Network | Builder requests `-nic none` | No runtime inspection of a child and no supported egress feature. |
| Build/release | Hosted tests plus Linux-musl diagnostic `zig-sandbox`; `build.zig.zon` includes supervisor, Docker bootstrap, native, and `vendor/sqlite` | No production server/CLI artifacts, no current published image digest, no release promotion. |
| TypeScript/Wasm SDKs | Private Bun TS0 source exists as a local-helper / remote-diagnostics package and remains unqualified. Portable Wasm core, guest Wasm runtime/profile, production SDK, and registry publication are pending. | Required planned interfaces; production SDK, both Wasm tracks, and registry publication remain pending. Private Bun TS0 does not complete them. |
| Linux/KVM | Historical WSL supervisor suite and historical i386 KVM smoke | No hostile workload, concurrency, recovery, watchdog, or release candidate qualification. |
| Checkpoints / act | Planned only: [sandbox-checkpoints.md](../docs/sandbox-checkpoints.md), [sandbox-local-ci.md](../docs/sandbox-local-ci.md) | No capture/store/restore; no act-in-guest. |

## 3. Prioritized findings

P0 blocks a production-isolation claim. P1 blocks a reliable public service or
production lifecycle. P2 is required before accepting its relevant milestone.

| ID | Priority | Evidence | Required closure |
| --- | --- | --- | --- |
| F01 | P0 | The pre-bootstrap build had no service/CLI entry point. Current [build.zig](../build.zig) `sandbox-api` step adds a fail-closed Linux HTTP bootstrap only; it has no state/VM backend and no production CLI contract. | Preserve bootstrap truth; implement WP1-WP4 and WP10. |
| F02 | P0 | `jail.zig` specifies UID, cgroup, namespaces, no-new-privs, and seccomp but applies none. | WP5 applied launcher, then G2-G3. |
| F03 | P0 | `qemu.zig` builds argv and `runtime.zig` handles generic processes; no lifecycle binds them. | WP5 and WP9. |
| F04 | P0 (native scope) | i386 ELF32 demo remains. This checkout also has a bounded native x86_64 UEFI bootstrap ([native-bootstrap.md](../docs/native-bootstrap.md)) and a hosted/native-compile user-VM constructor ([user_vm.zig](../src/arch/x86_64/native/user_vm.zig), `test-native-user-vm`) that builds private page tables without a CR3 switch, CPL3, SYSCALL, or scheduler. No ring-3 userspace. Blocks native-backend promotion, not a separately qualified Linux VM profile with the native backend disabled. | WP8 and G7. |
| F05 | P0 | [supervisor/jail.zig](../supervisor/jail.zig) maps guest processes to host `pids.max`. That limits QEMU host threads, not guest processes; `memory.max` includes QEMU overhead. | Separate host/guest limits in WP5/WP8. |
| F06 | P0 | [supervisor/api.zig](../supervisor/api.zig) uses fixed in-memory arrays (`MAX_SESSIONS` 8 and related caps); no durable images, workspaces, or recovery. The SQLite wrapper is not this store. | SQLite/WAL control store and durable filesystem state in WP3/WP7. |
| F07 | P0 | Current bootstrap has bounded TCP HTTP routing but no UDS/TLS listener, peer authentication, durable request handling, or SSE. | WP4. |
| F08 | P0 (native scope) | [src/proc/elf64.zig](../src/proc/elf64.zig) maps VMA metadata but does not copy segments/BSS; [src/proc/proc.zig](../src/proc/proc.zig) still uses the older loader path. Blocks native-backend promotion, not a separately qualified Linux VM profile. | WP8-WP9. |
| F09 | P1 | [supervisor/api.zig](../supervisor/api.zig) `checkOwner` compares stored owner bytes; `create` truncates into a 64-byte owner buffer. Historical probe: a 65-byte owner loses access and a distinct 64-byte-prefix owner gains it. | Authenticated opaque principals in WP3-WP4. |
| F10 | P1 | Global u64 idempotency entries in [supervisor/api.zig](../supervisor/api.zig) lack principal, route, digest, response, expiry, and durability. | Scoped idempotency transaction in WP3. |
| F11 | P1 | With admission max 9, ninth create fails but eight slots are used while active count/memory differ (`create` vs `MAX_SESSIONS`). | Transactional reservation without fixed-slot mismatch in WP3. |
| F12 | P1 | `api.tick` does not enforce TTL; fixed caps cover sessions/execs/tombstones/idempotency with no eviction. | Fenced durable expiry/recovery in WP3/WP6. |
| F13 | P1 | [supervisor/runtime.zig](../supervisor/runtime.zig) `kill` marks reaped on ESRCH before wait/FD closure; `reconcileDead` changes fields only. | Explicit idempotent exit observation/reap/close in WP6. |
| F14 | P1 | [supervisor/qemu.zig](../supervisor/qemu.zig) bypasses checked insertion; NUL writes can exceed exact-fit storage. | Typed argv builder plus fuzz/boundary tests in WP2. |
| F15 | P1 | Comment says QEMU exits yet argv adds `-no-shutdown`, which keeps it alive after guest shutdown. | One explicit host-owned terminal policy in WP2/WP6. |
| F16 | P1 | [supervisor/workspace.zig](../supervisor/workspace.zig) `checkLinkTarget` accepts a traversal-looking target; resolver policy rejects it. | Remove lexical link check from enforcement path; use dirfd/openat2 in WP7. |
| F17 | P1 | `uidFor` in [supervisor/jail.zig](../supervisor/jail.zig) rejects ID 8192, incompatible with durable allocation/reuse. | Explicit bounded launcher slot identity in WP3/WP5. |
| F18 | P1 (native scope) | [src/uaccess.zig](../src/uaccess.zig) checks model metadata then directly dereferences; no fault-safe recovery. | Fault-contained copy helpers and hostile pointer tests before native promotion. |
| F19 | P1 (native scope) | [src/baremetal.zig](../src/baremetal.zig) raw CPU page-fault/int80 bypass evidence; x64 header defers `lgdt/ltr/iret`. | Real privilege boundary, vectors, and transition tests before native promotion. |
| F20 | P1 (native scope) | [src/syscall.zig](../src/syscall.zig) lacks actual W^X enforcement; [src/proc/capture.zig](../src/proc/capture.zig) aliases PID modulo 64. | Kernel enforcement and nonaliasing capture/session identifiers before native promotion. |
| F21 | P2 (native scope) | [src/proc/userstack.zig](../src/proc/userstack.zig) exact-fit/alignment defects and [src/proc/elf64.zig](../src/proc/elf64.zig) program-header arithmetic are unsafe parser foundations. | Repair/property-test before native promotion. |
| F22 | P2 | [scripts/qemu-x86_64.sh](../scripts/qemu-x86_64.sh) falls back to the hosted executable and omits explicit accel. [scripts/release-gate.sh](../scripts/release-gate.sh) enables `set -e`, so expected-probe and intended exit-3 handling can abort before capture/interpretation. | Deterministic harness captures QEMU status explicitly, then classifies expected debug-exit. |
| F23 | P2 | CI/release coverage is uneven: [build.zig.zon](../build.zig.zon) includes supervisor, Docker bootstrap, native, schemas, and `vendor/sqlite`, but release still rebuilds/publishes without supervisor/KVM/broker qualification or a promoted-artifact hash path. | WP11 harness and WP14 final release gate. |

## 4. Security boundary

### 4.1 Threat model

Assume entire guest compromise: submitted input/program, guest agent, kernel,
disk, protocol, output, guest accounting, and all guest timestamps. Attack
classes include malformed ELF/frame data, CPU/memory/process/disk/output
exhaustion, protocol desynchronization, QEMU exploitation attempts, host-path
traversal, credential/socket discovery, inter-tenant access, egress, and
reset/watchdog races.

Trusted computing base: supported Linux kernel/cgroup facilities, pinned QEMU,
small privileged launcher, supervisor engine/store, image publisher, service
operator, and configured identity provider. A client identity provider is only
trusted to authenticate the asserted identity; authorization stays in service.

This plan does not promise protection from a host-kernel/QEMU escape, privileged
operator, physical attacker, or side channel without separately funded design
and qualification.

### 4.2 Enforcement matrix

| Objective | Authoritative host enforcement | Guest support | Required proof |
| --- | --- | --- | --- |
| CPU | cgroup `cpu.max`, QEMU vCPU cap, host watchdog | reporting only | Host control plane remains responsive under guest CPU loop. |
| Memory | cgroup `memory.max` includes QEMU overhead | guest accounting | Creation rejects unsafe headroom; pressure is a recorded terminal result. |
| Process count | QEMU host-thread budget separately from guest PID quota | guest process table/fork quota | Guest fork bomb hits guest quota without starving QEMU threads. |
| Time/silence | Host monotonic deadline; pidfd kill/reap | optional cooperative cancel | Hung guest/transport reaches bounded terminal state. |
| Files | mount namespace; image descriptors; dirfd/openat2; brokered export handles | guest disk plus authorized exports | traversal/symlink/race corpus cannot access host paths outside authorized exports. |
| Network | `-nic none` and isolated network namespace | none | Packet/socket probes find no egress/inherited host listener. |
| Privilege | UID/GID, closed FDs, empty env, no-new-privs, pinned seccomp | none | Process inspection records every expected control. |
| Control API | auth, authorization, bounded parser, durable fencing | versioned bounded protocol | Client/guest cannot cross ownership or allocate unbounded memory. |
| Cleanup | pidfd, cgroup/mount/socket cleanup, durable recovery | ACK advisory only | Restart leaves no unfenced VM or mutable generation. |

Seccomp is defense in depth for QEMU/launcher, not the sandbox by itself. The
filter must be generated and tested against the pinned QEMU/KVM profile, not
invented as a generic allowlist.

## 5. Architecture

```text
CLI / automation
       │ HTTPS+mTLS or Unix-domain HTTP
       ▼
transport: bounded HTTP/SSE, auth, request ID
       ▼
service: validation, authorization, idempotency mapping
       ▼
engine: state, leases, fencing, quotas, watchdog
    ┌──┴───────────────────┐
    ▼                      ▼
SQLite/WAL store       Linux launcher: cgroup/ns/seccomp/QEMU/pidfd
    ▼                      ▼
images/workspace       guest serial/vsock protocol
                               ▼
                      QEMU → untrusted guest/workload
```

| Seam | Proposed modules | Responsibility |
| --- | --- | --- |
| Entrypoints | `cli_main.zig`, `server_main.zig`, `build.zig` | Mode parsing/process exit only. |
| Model/engine | `model.zig`, `errors.zig`, `engine.zig` | IDs, lifecycle, leases, fencing, deadlines. |
| Persistence | `store.zig`, `store_sqlite.zig`, migrations | Transactions, events/audit, idempotency, recovery queries. |
| HTTP/auth | `http.zig`, `sse.zig`, `auth.zig`, `service.zig` | Bound parsing and principal derivation. |
| Linux runtime | `linux/launcher.zig`, `cgroup.zig`, `namespace.zig`, `seccomp.zig`, `process.zig` | Privileged setup and rollback only. |
| VM/guest link | `qemu_argv.zig`, `guest_link.zig` | Typed launch, immutable handles, bounded protocol. |
| Storage | `workspace_fs.zig`, `images.zig` | Descriptor-safe files and image verification. |
| Guest | `src/arch/x86_64/*`, `src/proc/*`, `src/agent/*` | CPU boundary, loader, quotas, agent. |
| Qualification | `tests/sandbox/*`, `scripts/qualify-sandbox.*`, CI | Reproducible release evidence. |

The public service must pass only validated typed image/lease/workspace handles
to the trusted launcher. It must never accept arbitrary QEMU options, arbitrary
host paths, arbitrary `ExecSpec`, raw cgroup paths, or public seccomp choices.

### 5.1 Swappable subsystem contracts

Subsystems are replaceable only at deliberate stable contracts owned by the
engine. Runtime selection occurs once at process startup from validated config;
callers import contracts, not concrete adapters. Adapters expose capability and
version metadata, and a common conformance suite is mandatory before selection.

| Contract | Required operations and semantic guarantees | Initial adapter and allowed replacement |
| --- | --- | --- |
| API transport / callback delivery | Bounded request/response/stream bytes, cancellation, peer metadata, no implicit identity. Callback delivery is a separately negotiated bidirectional protocol with distinct request namespaces. | Remote: UDS HTTP/1.1; optional mTLS HTTP. Local: SDK-owned private helper IPC plus a future callback bridge. Changing transport does not install remaining adapters. |
| Auth/authz | Authenticate principal, return immutable subject/attributes, authorize action/resource | SO_PEERCRED mapper; mTLS mapper; local-owner OS identity derivation. No caller owner string. Callbacks cannot choose or replace the principal. |
| Policy/admission | Validate immutable request, reserve/release capacity atomically, explain denial | Policy model plus durable admission adapter. Native or Bun policy may implement typed decisions; native enforcement and immutable owner limits still apply. Reserve/release and fencing are not advisory booleans. |
| State/idempotency/events/audit | Transaction, fence, idempotency reservation/replay, ordered cursor, append audit | SQLite control-state store; a future store must preserve transaction/fence semantics. Bun SQLite bindings alone are not this contract. |
| Lifecycle clock/watchdog | Monotonic deadline, boot identity, entropy, durable deadline, kill/reap result | Linux monotonic clock/pidfd watchdog; a replacement must fail closed on uncertain reboot time. A blocked JS event loop cannot stop independent deadlines, entropy validation, or force-reap. |
| Launcher | Create/revert typed lease, isolation proof, process lifecycle | **Linux baseline:** cgroup/ns/UID/seccomp/QEMU launcher. macOS/Windows providers supply AP4-equivalent supervised VM/isolation proof; no database substitute. Privileged isolation remains native enforcement, not a callback return value. |
| VM backend | Boot immutable image with typed CPU/RAM/disk/network/pause capabilities | QEMU/KVM initially; SmolVM/libkrun is a candidate adapter, never an automatic subprocess-CLI replacement; each backend passes isolation/guest conformance gates. Guest image/kernel is a boot artifact, not a JS callback. |
| Pause/snapshot | Native provider owns live CPU/RAM/device pause, capture, and restore. CheckpointStore payload/object/chunk/manifest storage is an independent adapter identity. | Live pause/capture/restore stay backend-native; unavailable capability returns `unsupported`, never an emulated transparent resume. Incremental **chunk storage** (content-addressed reuse of unchanged RAM/disk objects) is not dirty-page **execution** capture. Qualified Bun/native CheckpointStore callbacks may store chunks/manifests only when they provide content identity, atomic publication, durability, GC-pin, and cancel semantics; storage qualification does not confer device capture or execution-state restore. See [sandbox-checkpoints.md](../docs/sandbox-checkpoints.md). |
| Image registry | Resolve allowlisted immutable digest/provenance/ABI; cache/rootfs/blob/block/overlay semantics stay distinct | Local signed-manifest registry; no tenant URL loader. Local/native or qualified Bun-backed registry/storage may replace it after digest, provenance, quota, and credential isolation gates. |
| Workspace filesystem | Hierarchical dirs/files/handles/ranges, atomic rename, permissions/types/links, durability/quota | Native guest disk, SQLiteFS, explicitly authorized NativeHostExport, and future qualified Bun host-folder or Bun SQLiteFS adapters implementing this same contract with declared features. |
| Guest exposure | Transfer/mount workspace through bounded protocol or guest VFS adapter | Framed service/virtio disk; host export via virtiofsd, virtiofs, 9p, or bounded FSRPC per qualified provider. Never host-kernel mount of guest-controlled FS. A Bun callback completing is not proof the guest can mount or use the filesystem. |
| Network | Deny/allow route with connection/DNS/proxy policy and audit | Deny adapter only initially; allowlisted egress later. Bun or native policy/proxy adapters remain under the owner's egress ceiling. |
| Secret broker | Resolve authorized reference into one execution without logging bytes | Disabled adapter initially; explicit broker only after its own design/gates. Owner-supplied adapters and scoped references only; no guest-supplied storage credentials. |
| Metrics/logging | Bounded structured observation/redaction/health | Local metrics adapter; no raw tenant bytes/IDs as labels. A slow observer cannot indefinitely block kill/reap. |
| ToolRegistry / ToolExecutor | Discover and execute declared tools against a qualified guest profile | Guest tool adapters as in Section 9.6. Rejection never becomes ordinary host workload execution. |
| Scheduler / retention / backup / crypto | Explicit future serialization, tenant ownership, durable pins, key lifecycle, and recovery | Not implied by a checkpoint or filesystem adapter; each needs its own contract and qualification. |

The workspace contract has explicit cross-adapter meaning: directories,
regular files, byte ranges, ordered listing, atomic same-filesystem rename,
fsync/durable-commit status, quota reservation, ownership/permissions, and
symlink/hard-link behavior must be declared. An adapter returns opaque handles,
never unchecked host paths. Cross-adapter rename is either an explicit
copy-then-commit operation with crash record or `unsupported`; it is never
silently claimed atomic.

**SQLiteFS option.** A SQLite-backed filesystem adapter is distinct from the
control-state SQLite database. The common guest `WorkspaceFs/VFS` contract has
two initial exposure adapters: native guest filesystem over the bounded
virtio-block disk, and a feature-gated bounded guest filesystem RPC/VFS bridge
to a per-sandbox/generation SQLiteFS database. Native raw-disk and SQLiteFS are
not silently interchanged or mounted through each other.

SQLiteFS tables represent inode, directory entry, and chunk data. Transactional
write/rename also reserves quota; chunk/range reads and writes have stated
limits; symlink/hard-link modes are either fully specified and tested or return
typed `unsupported`. Its physical host quota includes DB, WAL, rollback/temp,
and staging files. The host bridge derives workspace authority only from the
authenticated channel and opaque generation handle: it never trusts
guest-supplied owner, host path, or SQL.

SQLiteFS does not grant OS isolation, does not replace Linux cgroups/namespaces/
KVM, and must never cause the host kernel to mount guest-controlled content.
Native host staging remains a real Linux dirfd/OS adapter; raw image/block
files and jail setup are necessarily real host resources, not database adapters.
Both workspace exposure adapters pass identical contract tests; missing a
configured bridge dialect/capability fails closed.

A future Bun SQLite filesystem adapter may use Bun's SQLite binding for those
inode/dirent/chunk tables. It must declare its actual SQLite/runtime version
and test transaction, durability, and concurrency limits. `bun:sqlite` alone
is not a POSIX filesystem, not a host-folder fallback, not the control Store,
and not a kernel, jail, or block device. It still must implement the same
`WorkspaceFs/VFS` contract with declared features and still needs a qualified
guest mount bridge (virtiofs, 9p, virtio-block, or bounded FSRPC per provider)
before guest operations are advertised. If mmap, locks, symlinks, hardlinks,
sparse extents, notifications, or cross-adapter rename cannot be implemented
faithfully, advertise them `unsupported`. Direct database CRUD is not guest
filesystem evidence.

**Planned Bun-local subsystem adapters.** Every row above is selectable at
startup/open from validated configuration through a future
`LocalAdapterRegistry` (proposed name, not shipped). Native engine adapters
and Bun-defined adapters implement the same relevant capability/conformance
contract. Adapter registration is owned by the embedding application and bound
to runtime/lease/generation/resource plus adapter/version; a new runtime,
restart, rebind, or revoke starts a new epoch scoped to the affected
resource or registry, and prior-epoch IDs are rejected rather than
promoted. Credentials and host paths stay in owner-controlled
local configuration; callback requests carry authorized handles, not
guest-provided owner, path, or SQL authority. This table is an architectural
map, not a reason to expose every privileged internal to untrusted remote
tenants, and not a claim that TS0 implements any of it.

Not every subsystem is a JavaScript callback. Classify local bindings as
follows:

| Subsystem | Local binding class | Callback-capable? |
| --- | --- | --- |
| Engine transport / callback delivery | SDK-owned private helper IPC plus a separately negotiated callback protocol | Delivery mechanism only; swapping transport does not swap other subsystems |
| Authentication / authorization | Trusted OS/local-owner identity plus explicit policy | No: callbacks cannot select the principal |
| Policy / admission / capacity | Native or Bun typed decisions under an immutable owner ceiling | Decision injection only; cannot widen limits |
| Control Store / idempotency / audit / events | Native or qualified Bun-backed durable store | Only if the durable contract is preserved; `bun:sqlite` alone is insufficient |
| Clock / entropy / watchdog | Injectable sources with monotonic/boot-id/entropy guarantees | No: a blocked JS loop cannot disable independent deadlines |
| Launcher / process supervisor | Qualified native host adapter | No: isolation/rollback/process ownership stay native |
| VM backend / guest control | Selected qualified provider | No: guest image is a boot artifact, not a JS library |
| Live pause / capture / restore / checkpoint store | Native provider owns live CPU/RAM/device pause/capture/restore. CheckpointStore payload/object/chunk/manifest storage is an independent native or qualified Bun callback store. | Device capture/restore: No — callbacks do not preserve CPU/RAM/device or execution state. CheckpointStore: qualified Bun/native chunk/manifest storage callbacks are permitted with content identity, atomic publication, durability, GC-pin, and cancel semantics; storage qualification does not confer capture/restore |
| Image registry / cache / rootfs / blob/block/overlay | Local/native or qualified Bun-backed storage | Storage injection only; resolve approved sources only |
| Workspace filesystem / approved host-folder export | Native guest disk, authorized host-folder, Bun FS callback, or SQLiteFS | Yes, behind the shared FS contract and declared features |
| Guest filesystem exposure / mount bridge | Qualified virtiofs/9p/virtio-block/FSRPC per provider | No: callback completion is not a mount |
| Network / DNS / HTTP proxy | Bun/native policy or proxy under outer egress ceilings | Yes, for allow/deny under the ceiling; cannot widen egress or hide host-exec |
| Secrets / credential provider | Explicit owner-supplied adapter and scoped references | Handle resolution only; no implicit environment discovery |
| Metrics / logs / tracing | Replaceable bounded sink with backpressure/drop and redaction | Observer only; cannot block kill/reap |
| ToolRegistry / ToolExecutor | Replaceable discovery/execution contracts | Selected tool/profile only; never host-exec fallback |
| Scheduler / retention / backup / crypto | Explicit future adapters | Not implied by filesystem or checkpoint implementations |

These sixteen rows remain independently swappable contracts. A qualified
CheckpointStore does not become live pause, capture, or device restore, and
the Callback-capable column does not pretend every subsystem is a JavaScript
callback.

Kernel CPU, MM, scheduler, VFS, device, and ABI implementations may use
compile-time interfaces selected per build and validated by a guest-image test
matrix. They are not hot-swappable privileged internals and are not runtime
JavaScript replacement: changing any trusted implementation requires a new
image digest and full guest/isolation qualification.

A native host-folder adapter exposes only approved roots and declared
RO/RW/mask policy. Workspace, symlink, path-authority, transaction, error,
fence, and durability rules are the existing filesystem contract. Network and
policy callbacks may propose or restrict decisions under that ceiling; they
cannot override helper/launcher isolation, escape path grants, expand egress,
acquire credentials, or downgrade authentication. Arbitrary application
callbacks run with the embedding application's own trust; an in-process Bun
closure is not sandboxed from its host merely because requests use capability
handles. Untrusted plugin code needs a separately qualified isolation profile.

### 5.2 Guest choice

| Candidate | Role | Benefit | Requirement |
| --- | --- | --- | --- |
| Qualified Linux general-computer guest through swappable VM backend | **Proposed production baseline** | Meets the required normal developer-workstation contract: shell, common runtimes/toolchains, package management, processes, PTY, network profiles, and POSIX filesystem behavior. | Immutable image/publisher/update path plus the full G7/G11 acceptance matrix on exact promoted artifacts. |
| Zig-native x86_64 QEMU guest | Experimental profile | Retains repository research path and narrow static ABI. | It remains experimental until it passes the same normal-computer acceptance matrix; static ELF-only success cannot satisfy production acceptance. |

Current sources do not prove glibc/musl, dynamic linker, POSIX processes,
`/proc`, Bash, Python, Node, package-manager, or host-export compatibility.
Capabilities must advertise each qualified image/profile truthfully.

The native Zig guest stays experimental under this plan. Its kernel, Vinix,
Linux-ABI, distro, and cross-platform provider milestones are independently
defined in [kernel and distro plan](kernel-distro.md); a sandbox guest workload
or client SDK/API result never closes those native-kernel gates.

### 5.3 SmolVM feature comparison

Public source identity for SmolVM planning is pinned upstream
[`9d442abd49169f3b2971f877fa687ef5763d9dc7`](https://github.com/smol-machines/smolvm/commit/9d442abd49169f3b2971f877fa687ef5763d9dc7)
(2026-09-13), inventory in [smolvm-features.md](smolvm-features.md). That
inventory is not runtime qualification and is not a claim that SmolVM’s trust
model establishes this service’s multi-tenant isolation. The proposed
`VmBackend` adapter may evaluate SmolVM/libkrun only through the same typed
launcher, cgroup, identity, network, workspace, pause, and qualification
contracts as QEMU.

Vendor incremental checkpoints reuse unchanged **storage chunks** after a full
retained-RAM read; they are **not** dirty-page execution capture. zig-kernel
must not label that dirty-page capture. See
[incremental-checkpoints.md](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/docs/incremental-checkpoints.md)
and [sandbox-checkpoints.md](../docs/sandbox-checkpoints.md).

| SmolVM source group | Feature coverage | Plan disposition |
| --- | --- | --- |
| [machine.rs](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/cli/machine.rs) | run, exec, create/start/stop/delete/status, branch/checkpoint/release, resize/update, images/prune, shell, cp/sync, monitor, egress events, list, network test | Core lifecycle/exec/status/start/stop/monitor map to required engine contracts; resize/update and branch/checkpoint are optional backend extensions; no CLI reuse implied. |
| `src/cli/pack.rs` (historical local inspection; not among the 20 CRLF-normalized pinned files) | create/run/push/pull/inspect/prune pack operations | Optional image/package registry adapter; not required to ship the sandbox core. |
| [api/mod.rs](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/api/mod.rs) | interactive WebSocket, SSE, checkpoint, capacity/drain/prewarm, P2P, pools/leases/batch heartbeat, volumes, rollout executors | SSE/interactive map to server/PTY requirements; capacity/leases inform operations; P2P/pools/rollouts are optional scale extensions outside first production core. |
| [portable_checkpoint.rs](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/portable_checkpoint.rs) | validated running/control checkpoint preconditions; RAM/device/disk save/resume; host-mount/etc rejection | Candidate durable checkpoint adapter only. Live pause remains `unsupported` unless independently qualified. |
| `src/agent/fork.rs` (historical local inspection; not among the 20 pinned files); [forkpoint.rs](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/crates/smolvm-agent/src/forkpoint.rs) | staged-mount rejection, shared live RW exports, timing rearm caveat, inherited RAM secrets/entropy/MAC/IP state | Fork/checkpoint is optional and must declare shared/external state; no transparent fork/resume claim. |
| [launcher.rs](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/agent/launcher.rs) | restore errors logged | Our adapter treats restore error as terminal/recovering failure; it never cold-boots silently as a restore fallback. |
| `crates/smolvm-smolfile/src/lib.rs` (historical local inspection; no public pin in the 20-file set) | image, env, user, resources, network, storage/mount, init/artifact/dev/fork, health/restart/auth/service schema | Required validated image/profile configuration contract; each field needs declared capability and policy, never passthrough to launcher. |
| `src/data/storage.rs` (historical local inspection); [machine.rs](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/cli/machine.rs) copy/sync | staged guest copy and sync | Copy-in/staged sync only; not live host-folder coherence. NativeHostExport remains the live-export design and defaults RO. |
| [machine.rs](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/cli/machine.rs) stopped-machine update | stopped-machine update | Optional stopped-profile/resource update; live resize/change requires separate backend capability and admission/fencing test. |
| [README](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/README.md) | containerd/Kubernetes, Vulkan/Venus/headless browser, CUDA remoting | Shim/orchestration and GPU/browser integrations are optional/out of core. CUDA remoting is a host process concern, not proof of GPU-in-VM isolation. |
| `crates/smolvm-s3fs` (historical local inspection; no public pin in the 20-file set) | remote volume adapter | Optional volume adapter; it cannot claim full POSIX semantics without this plan’s filesystem conformance tests. |
| `src/main.rs`, `src/cli/config.rs` (historical local inspection); [machine.rs](https://github.com/smol-machines/smolvm/blob/9d442abd49169f3b2971f877fa687ef5763d9dc7/src/cli/machine.rs) diagnostics | top-level Machine/Serve/Pack/Config, registry configuration, data-dir diagnostics; SSH-agent/secret/socket forwarding and Rosetta profile concerns | Optional typed capability/profile extensions with explicit secret/object/audit policy; diagnostics are required observability, while forwarding/Rosetta never imply ambient host access. |

Observer health/metrics/logs and declared loopback port publishing for normal
web development are required bounded capabilities in WP10a/G11: ingress is
explicitly mapped to a sandbox/port/profile and never ambient host networking.
Registry/cache pruning/auth, private fabrics, third-party SDK/pack/shim, pools,
and cluster rollouts are optional adapter extensions. The requested first-party
TypeScript SDK and both WebAssembly tracks are required by Sections 8.1-8.2
instead. All extensions expose bounded capabilities and pass their own
qualification; source availability does not silently widen first-release scope.

## 6. Server specification

### 6.1 Listeners and identity

**Proposed UDS:** `zig-sandbox serve --socket /run/zig-sandbox/api.sock` owns
its parent directory; it validates any stale socket before removal, binds mode
0660, uses a service group, reads `SO_PEERCRED` before application parsing, and
maps allowed UID/GID records to immutable principals. Caller-supplied owner
fields are ignored/rejected. This is the **Linux/Unix baseline** only.

**Proposed AP4 local IPC:** macOS uses a launchd-managed service and
service-owned signed helper, with an OS-native peer-identity policy; Windows
uses a service-owned named pipe with restrictive ACL/SID identity mapping.
Neither provider assumes SO_PEERCRED, Unix modes, cgroups, or a Linux process
model. Each must prove authenticated peer derivation before application parsing
and fail closed if its selected IPC/identity primitive is unavailable.

**Proposed remote TLS:** disabled until explicit listen address, CA/client
trust roots, certificate/key references, and identity mapping exist. Require
TLS 1.3 plus client certificates. Map approved SPIFFE URI SAN or configured
SAN/CN rule to a principal. Tokens are not an implicit fallback; any token
design needs issuer/audience/rotation/revocation approval.

The service is unprivileged. A small privileged launcher receives only an
opaque validated lease/image/limit handle over a private authenticated channel.

### 6.2 HTTP/SSE bounds

- **Proposed finite defaults:** request-header/read/write deadline 15 seconds;
  lease renewal 10 seconds; attachment reconnect grace 30 seconds; guest boot
  deadline 60 seconds; cancel grace 5 seconds; cleanup deadline 30 seconds.
  These are configuration defaults to calibrate against qualified host limits,
  not performance promises. Exhaustion of any deadline is recorded and follows
  the lifecycle table.
- Bound request line, headers, header count, body, JSON depth, file bytes,
  connection count, in-flight requests, and per-principal work.
- Support only deliberately implemented HTTP/1.1 forms and transfer encodings.
- Use read/write deadlines and backpressure; reject before durable allocation.
- Parse/canonicalize route/query once; never map an HTTP path to a host path.
- Give every response/log a request ID; redact secret bytes and raw stdin.
- Persist monotonic event cursors and generation; SSE slow consumers receive
  terminal cursor-expiry and resume through polling, never unbounded buffering.
- Preserve output as bounded byte chunks; encode non-UTF-8 bytes safely in JSON
  and SSE; terminate on host-enforced output limit.

### 6.3 API delta and status contract

The OpenAPI document is revised to 3.1 JSON Schema: nullable values use a
union such as `type: [string, "null"]`, rather than OAS 3.0 `nullable`.
[OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.0.html) is the controlling
syntax reference. All mutating routes require `Idempotency-Key`.

| Method and route | Required request and response | Statuses |
| --- | --- | --- |
| `GET /v1/capabilities` | Advertised images/ABIs/effective ceilings/features, including exact Wasm runtime/ABI/WIT profile where qualified | 200 |
| `POST /v1/sandboxes` | Image/limits/TTL; always returns operation/location; CLI may wait for `ready` | 202 creating; 400/401/403/409/413/422/429/503 |
| `GET /v1/sandboxes` | Owner-paginated list with opaque cursor/filter | 200 |
| `GET /v1/sandboxes/{id}` | Authorized state, generation, instance/pause fence, image digest, limits, reserved resources | 200/404 |
| `POST /v1/sandboxes/{id}/executions` | Expected generation, argv, cwd/env/stdin/timeout/detach; always returns operation/execution | 202; 400/401/403/404/409/413/422/429/503 |
| `GET /v1/sandboxes/{id}/executions/{exec}` | Execution inspection and terminal result | 200/404 |
| `POST /v1/sandboxes/{id}/executions/{exec}/cancel` | Expected generation and idempotency key | 202 cancelling; 200 already terminal; 409 stale |
| `PUT/GET /v1/sandboxes/{id}/files` | Expected generation; bounded path/bytes/hash; binary body | 201/200; 409 stale; 413 too large |
| `GET /v1/exports`; `POST /v1/exports` | Authorized server-host export catalog/registration through HostExportBroker | 200/202; never accepts remote arbitrary host path |
| `POST/DELETE /v1/sandboxes/{id}/mounts` | Expected generation, opaque export handle, approved target/mode; attach/detach is fenced operation | 202; 403/409/422/503 |
| `GET /v1/sandboxes/{id}/events` | `after` cursor/limit or SSE accept header; observation does not cancel | 200; 410 cursor expired |
| `POST /v1/sandboxes/{id}/reset` | Expected generation and idempotency key | 202 operation; 409 stale |
| `POST /v1/sandboxes/{id}/stop` | Expected generation/idempotency; kill/reap VM and retain eligible internal disk/package/export-origin state | 202 operation; 409 stale |
| `POST /v1/sandboxes/{id}/start` | Expected generation/idempotency; fresh running-capacity reservation and VM instance | 202 operation; 409 stale; 503 capacity |
| `POST /v1/sandboxes/{id}/pause` | Expected generation/idempotency; requires advertised live-pause capability | 202 operation; 409 stale; 422 busy/unsupported external state; 501/503 unavailable |
| `POST /v1/sandboxes/{id}/resume` | Expected generation/idempotency and current pause fence | 202 operation; 409 stale; 422/503 when resume preconditions fail |
| `POST /v1/sandboxes/{id}/snapshots`; `POST /v1/sandboxes/{id}/restore` | Explicit snapshot/restore capability, immutable snapshot ID, source/target generation and idempotency | 202 operation; 409 stale; 422 unsupported/external-resource conflict |
| `DELETE /v1/sandboxes/{id}` | Expected generation and idempotency key | 202 operation; 200 replayed terminal tombstone; 409 stale |
| `GET /v1/operations/{id}` | Authorized create/reset/destroy/cleanup operation | 200/404 |
| `GET /healthz`, `/readyz`, `/metrics` | Operator-only readiness/metrics policy | 200/503 or 401/403 |

Identity is never a caller field; derive it from UDS/TLS. IDs are opaque, never
PIDs/row IDs used as authority. Effective host and guest limits plus immutable
image digest are returned on creation/inspection. No shell string is accepted.

For idempotency, use `UNIQUE(principal_id, key)`. Keep a separate immutable
fingerprint of method, canonical route/query, expected generation, canonical
JSON body or streaming content digest, and relevant content type. Same key and
different fingerprint is `idempotency_conflict`; same fingerprint replays the
stored accepted/terminal response. A transaction reserves `in_progress` before
work, records the operation ID, and records terminal response/error. On restart,
an in-progress reservation is reconciled to the durable operation rather than
executed twice. File upload uses a staged digest/commit record and guest ACK;
crash before commit leaves only reclaimable staging, while crash after commit
replays the committed metadata/result.

Every error has `code`, `message`, `request_id`, `retryable`, and optional
redacted `detail`. Define stable mappings for invalid request, unauthenticated,
forbidden, not found, conflict, stale generation, idempotency conflict, limit,
payload too large, cursor expired, unsupported host/image, capacity,
guest failure, resource limit, deadline, unavailable, and internal error.

## 7. Durable store, lifecycle, recovery

### 7.1 Proposed SQLite/WAL

Use local SQLite in WAL mode on a service-owned local filesystem, with foreign
keys, bounded busy retry, migration lock, backup procedure, and singleton
server lock. **Proposed default:** `PRAGMA synchronous=FULL` for durable
intent/state transactions, because WAL is same-host storage and FULL syncs each
commit while NORMAL may lose committed work on power loss. [SQLite WAL](https://sqlite.org/wal.html)
documents those scope/durability trade-offs. SQLite is a single-host
control-plane choice, not clustered coordination.

**Current checkout (not AP2):** [vendor/sqlite/SOURCE.json](../vendor/sqlite/SOURCE.json)
pins official amalgamation 3.53.4. [engine/sqlite_c.zig](../engine/sqlite_c.zig)
is the Zig binding. `zig build test-store-dependency` and
`store-dependency-probe` are actual-file seed/reopen gates. They are **not**
wired into `engine/contracts.Store`, not SQLiteFS, not checkpoint payload
storage, and do not change `/readyz` or `execution`. A later control-database
foundation in a separate unaccepted tree is not shipped here.

Tables: principals, images, sandboxes, generations, executions, operations,
idempotency, events, audit, leases, and schema version. Store immutable image
digest, effective limits, principal, state, generation, fencing token, deadline,
opaque workspace location, terminal result, and retention. Audit is append-only
logical data with actor/action/policy/result hashes; it excludes secrets, stdin,
cert material, and raw output.

Create commits `creating` plus operation/fence before launch. A worker claims
that exact fence transactionally before calling the launcher. Every transition
checks current generation/fence, so an old watchdog/reset/recovered worker
cannot publish a stale VM result.

### 7.2 Lifecycle

| State | Legal next states | Workspace and execution rule |
| --- | --- | --- |
| `creating` | `ready`, `failed`, `destroying` | New generation and disk allocated; only trusted boot/hello may advance it. |
| `ready` | `busy`, `pausing`, `stopping`, `resetting`, `expired`, `destroying`, `failed` | Workspace is stateful and retained until reset/destroy/expiry. |
| `busy` | `ready`, `pausing`, `stopping`, `recovering`, `resetting`, `expired`, `destroying`, `failed` | One or more bounded executions/PTYs are active; cancel/timeout targets one execution before VM escalation. |
| `pausing` | `paused`, `recovering`, `failed`, `destroying` | Persist prior state, execution IDs, event cursors, and pause fence; quiesce guest I/O and ask backend to live-pause. |
| `paused` | `resuming`, `stopping`, `resetting`, `expired`, `destroying`, `failed` | VM RAM/process state remains reserved; session TTL, host watchdog, quotas, and audit continue. |
| `resuming` | `ready` or `busy`, `recovering`, `failed`, `destroying` | Restore prior state; resume the saved execution without rerun only after same fence/resources/guest heartbeat validate. |
| `stopping` | `stopped`, `recovering`, `failed`, `destroying` | Kill/reap VM; RAM/process state is lost while eligible internal disk/package state and host export origins remain. |
| `stopped` | `starting`, `resetting`, `expired`, `destroying` | No VM/RAM capacity retained; storage retention continues. |
| `starting` | `ready`, `failed`, `destroying` | Re-reserve running capacity and launch fresh VM instance; no old execution resumes. |
| `resetting` | `creating`, `failed`, `destroying` | Fence first, abort/reap old VM, wipe old workspace, create new generation, require replacement `hello/ready`. |
| `recovering` | prior safe state, `failed`, `destroying` | Startup owns lease and reconciles only matching fence/markers. |
| `failed` | `resetting`, `destroying` | Preserve evidence/workspace unless explicit reset/destroy/expiry policy removes it. |
| `expired` | `destroying`, `destroyed` | Stop/reap then remove workspace and retained material by retention policy. |
| `destroying` | `destroyed`, `failed` | Repeatable teardown removes all host resources; error leaves recoverable failure record. |
| `destroyed` | none | Bounded tombstone supports idempotent replay before retention purge. |

TTL expiry and destroy authority apply to every nonterminal state, including
pausing, paused, resuming, stopping, and starting; their fence wins and drives
the state through destroying rather than allowing an ignored transition.

Reset, destroy, TTL expiry, cancel escalation, watchdog, and recovery obtain
the same durable lease. Reset increments generation before teardown. Every
execution/file/event mutation carries expected generation. Cancel/timeout kills
and reaps the selected execution when cooperative cancel succeeds; other
executions remain `busy`. VM kill/reap, replacement under a new fence, and
`recovering`/`failed` apply only to escalation or integrity failure, after which
replacement `hello/ready` is required before returning to `ready`. Reset,
destroy, expiry, or an unrecoverable disk failure wipes only the internal
generation workspace/COW layer. It first revokes/fences live export handles and
never deletes their registered host origin. Destroy retains an idempotent
tombstone.

The session is `busy` while any execution/PTY is active. Execution concurrency
is a declared bounded profile limit: default one is permitted only for profiles
that advertise it, while the production developer profile must qualify at least
two concurrent executions so a dev server and interactive/debug terminal can
coexist. Pause persists all active execution IDs, PTY ownership, and event
cursors; resume returns aggregate `busy` until all finish. Cancel targets the
selected execution; VM escalation kills all active executions and records every
affected terminal result.

Stop/start is distinct from pause/resume. Stop destroys VM RAM and all guest
processes after kill/reap, preserves eligible internal disk/package state and
never deletes live host-export origins. Start creates a new VM instance fence
while preserving the sandbox generation; prior execution IDs are terminal/gone
and cannot be resumed. Stopped sandboxes retain storage only, not CPU/RAM
admission. Start must obtain fresh running-capacity admission or return
capacity unavailable; it never overcommits paused/stopped sessions.

Live pause and durable snapshot are separate contracts. Live pause retains VM
RAM, host cgroup reservation, pidfd, and device state; it is not resource-free
or reboot-safe persistence. Snapshot/restore is available only when the
selected backend advertises a qualified capture/restore of declared RAM, disk,
and device state under a new generation/fence. Neither promises arbitrary
transparent resumption of sockets, host exports, clocks, package downloads, or
external services. Pause/restore fails closed when mounted-export revocation,
socket state, host boot identity, clock/deadline, or backend compatibility is
unsafe; a restore error is terminal/recovering failure, never silent cold boot.
Pause is session-wide: it freezes the guest process tree and PTY and quiesces
guest I/O to authorized mounts; external host writes continue and are neither
rolled back nor claimed frozen. It makes no per-process pause claim. Session
TTL and host wall/run elapsed deadline continue while paused; heartbeat/silence
alarms are suppressed only after acknowledged pause, while independent host
liveness checks continue. A backend may separately advertise guest-CPU
accounting, never a silent extension of wall time. State queries acknowledge
pause fence, reserved memory, deadline, and backend capability. Cancel/reset
from paused terminates/reaps rather than resumes; duplicate, crash, expiry,
external-write, socket-disconnect, and clock-change races are G6 acceptance
cases.

Snapshot/restore endpoints are an optional backend extension outside the core
state table until a profile supplies complete entry/return/new-generation rules
and G6 evidence. They never substitute for the required Linux live
pause/resume capability.

Host watchdog uses monotonic time plus a persisted absolute deadline and host
boot ID. If boot ID changed and safe remaining time cannot be determined, it
fails closed into recovery/teardown rather than granting extra execution time.
Guest cancel is advisory and cannot delay host kill/reap. The worker records
result, closes pidfd, removes mounts/cgroup/sockets/writable disk when required,
then commits terminal state.

A local `run --local` must survive CLI SIGKILL/crash. **Proposed Linux
implementation:** create a systemd transient disposable worker with `Type=exec`,
`RuntimeMaxSec` at the durable external TTL, and `KillMode=control-group`; the
CLI only attaches to it. QEMU remains a descendant of that unit’s cgroup and is
never migrated outside it, so `KillMode=control-group` reaches the VM as well as
the worker. The service/engine checks that systemd support and the required
isolation prerequisites exist, else fails closed. The systemd service and kill
documentation describe these lifecycle controls. [service](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.service.xml),
[kill](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.kill.xml)
**Proposed macOS/Windows implementations:** independently supervised
Hypervisor.framework and a selected Hyper-V/WHPX boundary respectively, with the same
lease/fence/reap/recovery contract and provider-specific capability discovery.
They are planned only and cannot claim Linux namespaces/cgroups/seccomp;
unsupported prerequisites fail closed.

A completed stateful `POST /sandboxes` persists its TTL when its ordinary HTTP
connection closes. An attached `exec` acquires/renews an attachment lease:
connection loss starts the proposed 30-second reconnect grace, then sends
cancel but does not destroy the sandbox. SSE/poll observers never own a lease
and never cause cancellation. `run --local` is ephemeral: after its attachment
ends or grace expires it cancels, reaps, and destroys, unless `--detach` was
accepted with an explicit TTL.

Startup takes singleton lock, migrates, marks unfinished work recovering,
enumerates service-owned cgroups/mounts/sockets/process markers, reconciles
by immutable sandbox/generation marker, kills unknown/unfenced children,
finishes cleanup, and records recovery events. Ambiguous resources are
quarantined for an operator repair command, not blindly deleted.

## 8. CLI specification

| Mode | Meaning |
| --- | --- |
| `zig-sandbox --endpoint … command` | Remote client on Linux/macOS/Windows. Never executes a workload locally. |
| `zig-sandbox run --local …` | Qualified Linux/macOS/Windows provider, same engine/transactions as serve, one-shot ephemeral worker. |
| `zig-sandbox serve …` | Provider-qualified server; never selected implicitly by a client operation. |
| Local host unsupported/prereqs absent | Fails closed with `unsupported_host`; no QEMU/host/shell fallback. |

**Proposed commands**

```text
zig-sandbox capabilities
zig-sandbox doctor [--json]
zig-sandbox create --image ID [--limits FILE] [--ttl DURATION]
zig-sandbox list [--state STATE] [--json]
zig-sandbox inspect SANDBOX
zig-sandbox upload SANDBOX LOCAL --path /workspace/DEST [--sha256 HEX]
zig-sandbox download SANDBOX --path /workspace/SRC --output LOCAL
zig-sandbox export register SERVER_SOURCE [--mode ro|rw] [--principal SUBJECT]
zig-sandbox mount attach SANDBOX --generation N --mount export=EXP,target=/workspace/project,mode=rw
zig-sandbox mount detach SANDBOX --generation N EXPORT
zig-sandbox exec SANDBOX --generation N [--detach] -- ARGV...
zig-sandbox execution inspect SANDBOX EXEC
zig-sandbox operation wait OPERATION [--timeout DURATION]
zig-sandbox events SANDBOX [--after CURSOR] [--follow]
zig-sandbox cancel SANDBOX EXEC
zig-sandbox stop SANDBOX --generation N
zig-sandbox start SANDBOX --generation N
zig-sandbox pause SANDBOX --generation N
zig-sandbox resume SANDBOX --generation N
zig-sandbox snapshot create SANDBOX --generation N
zig-sandbox snapshot restore SANDBOX SNAPSHOT
zig-sandbox reset SANDBOX --generation N
zig-sandbox destroy SANDBOX [--generation N]
zig-sandbox run --local --image ID [--upload LOCAL:DEST] -- ARGV...
zig-sandbox serve --config FILE [--socket PATH] [--listen ADDR]
```

Examples:

```sh
zig-sandbox --endpoint https://sandbox.example capabilities --json
zig-sandbox doctor --json
zig-sandbox create --image linux-dev-v1 --ttl 10m --json # waits for ready
zig-sandbox export register /srv/projects/acme --mode rw --principal team_acme
zig-sandbox upload sbx_123 ./tool --path /workspace/tool
zig-sandbox mount attach sbx_123 --generation 1 --mount export=exp_project,target=/workspace/project,mode=rw
zig-sandbox exec sbx_123 --generation 1 -- /workspace/tool --input in.json
zig-sandbox download sbx_123 --path /workspace/out.json --output ./out.json
zig-sandbox reset sbx_123 --generation 1
zig-sandbox destroy sbx_123 --generation 2
zig-sandbox run --local --image zig-native-v1 --upload ./tool:/workspace/tool -- /workspace/tool
```

The normal stateful walkthrough is create (wait ready) → upload → exec (or
`execution inspect`/`operation wait`) → download → reset if a clean workspace
is needed → destroy. Use `create --no-wait` only when automation will call
`operation wait`. `doctor` reports client transport, local Linux prerequisites,
and supported capabilities without launching a workload; it cannot claim KVM
or isolation is usable until the server/launcher verifies it.

The register example names an ordinary folder on the **server host** and is
available only to the operator/principal authorized by HostExportBroker policy;
it returns opaque `exp_project`, never a reusable path capability. A remote
client’s local folder is not eligible through this command: it must copy upload
or use the separately enabled authenticated client-export agent. The current
bootstrap `/v1/exports` routes are 404, while `/v1/sandboxes/{id}/mounts` and
other sandbox-prefix routes are 501 execution-unavailable. It exposes no CLI
register/attach command until the production engine lands.

Precedence: flags, explicitly named config, `ZIG_SANDBOX_*` environment,
platform config, compiled safe defaults. Secrets come only from a descriptor or
OS credential-store reference, never command args/history/diagnostics.

`--json` writes one result object to stdout for non-streaming commands; events
and attached execution streaming use one JSON object per line, each carrying
sequence/stream/byte encoding. Human progress/retries/diagnostics write stderr.
Attached guest streams use matching stdout/stderr only outside JSON. Redirected
streams stay binary-safe. Terminal rendering must escape
untrusted control sequences; `--raw-output` is an explicit warning-bearing
override for a trusted terminal.

Exit codes: 0 success; 2 usage/config; 3 auth; 4 protocol/request; 5 sandbox
operation; 6 guest failure/nonzero; 7 client timeout/cancel/resource; 8
transport unavailable; 9 unsupported host/image. First Ctrl-C sends durable
cancel; second exits the client while reporting execution ID. `--detach` returns
after accepted persistence. Retry only before response or when response marks
retryable, always with the saved idempotency key. Connect/request/wait timeouts
are distinct and never revise server execution deadline.

### 8.1 Required TypeScript SDK

**TS0 (2026-09-14):** `@zig-sandbox/sdk` exists as a private Bun 1.4.2 package
under `packages/zig-sandbox-client/` with ESM/declaration exports `.`,
`/local`, and `/remote`. Local mode launches an SDK-owned Zig helper through
an explicit trusted `helperPath`; remote mode never does. Execution remains
typed unavailable. Landed source is not a completed TS0 qualification until
helper build, lifecycle, and packed-consumer receipts exist for the intended
Windows/Linux x64 matrix.
Helper/1 remains a bounded one-inflight diagnostic
protocol; aborting that diagnostic call may tear down the helper/1
channel. That teardown is a TS0 diagnostic fact, not the future
executing-VM wait-abort contract, and later provider execution must not
inherit it for ordinary waiter abort. Callbacks, adapter registration,
SQLiteFS, and guest I/O are absent and unadvertised. The remainder of this subsection is the production
SDK plan (generated OpenAPI types, Node/browser qualification, local adapter
registry, registry publish) and is not claimed by TS0.

**Proposed production package:** `@zig-sandbox/sdk` under
`packages/zig-sandbox-client/`, owned with `package.json`,
`src/client.ts`, `src/types.ts`, `src/errors.ts`, `src/transports/*`,
`src/generated/*`, `tests/*`, and API-version compatibility
fixtures. TS0 source contains a bounded subset of that tree; it is not a registry
release.

The package exports a typed `SandboxClient`, resource/operation IDs, lifecycle
and capability types, stable error classes, and a version constant compatible
with the OpenAPI/API contract. Generate or verify request/response types from
the versioned OpenAPI description in CI; a server/SDK schema mismatch blocks
release. The package uses ESM and declaration files, supports current Node and
browser consumers only where their transport/auth constraints are met, and
does not expose host-execution fallback.

**Wire-number rule:** resource IDs, idempotency keys, operations, and event
cursors stay opaque validated strings: their visible spelling has no numeric
meaning. Generations, fencing tokens, byte counts, and every numeric value
that may exceed JavaScript safe-integer precision use canonical base-10 strings
in OpenAPI, JSON, TypeScript, and portable-Wasm vectors. The SDK may provide
an explicit `BigInt` conversion helper, but never silently passes a JavaScript
`number` through a precision boundary. The schema rejects numeric spellings
for opaque tokens, and rejects noncanonical leading zeroes, signs, fractions,
overflow, and type drift for decimal counters; the same fixtures verify server,
TypeScript, and Wasm behavior.

| SDK surface | Required behavior |
| --- | --- |
| Transport/auth | **Remote entrypoint:** Node selects HTTPS or configured UDS transport; browser selects same-origin HTTPS/proxy only. Browser code never embeds mTLS private keys, UDS access, internal broker/FD/launcher handles, or server credentials. A server-authorized opaque export resource ID travels only through the normal mount API. Remote mode never launches a helper, VM, or host process, and never inherits local path or callback authority. **Local entrypoint (`/local`):** Bun-only TS0 may spawn the pinned userspace helper at an explicit `helperPath` and later a selected VM provider; that is not a remote fallback. Transport injection is not subsystem adapter registration. |
| Resources | Typed create/list/inspect, async operation wait, start/stop/pause/resume, optional snapshot capability, executions/PTY/files/exports/mounts, events, reset/destroy. Methods check advertised capability before use. |
| Correctness | Mutations create/save idempotency keys; calls carry generation and operation fences; 202 returns typed operation/location; stale/unsupported/retryable errors retain server request ID. |
| Streams/bytes | Upload/download accept `Uint8Array`/web streams; output/events expose `AsyncIterable` byte chunks with cursor resume; abort uses `AbortSignal` and distinguishes client disconnect from remote cancel. |
| Retry/security | Retry only safe/idempotent pre-response or explicitly retryable results; no automatic replay of non-idempotent streams; bounded bodies/timeouts; redact credentials. Remote never invokes local shell/QEMU. Local TS0 may spawn only the owned helper binary; it must not shell-expand or PATH-search untrusted executables. |

Node mTLS credentials are supplied by a caller-controlled secure credential
provider; browser callers rely on same-origin session/proxy authentication and
documented CORS policy. A browser never connects directly to a privileged UDS
or uses a server identity. Remote browser access requires an explicit BFF/proxy
authorization boundary rather than permissive CORS.

**Planned local adapter binding.** A Bun application that explicitly imports
`/local` supplies typed filesystem, network, and policy adapters through a
versioned `LocalAdapterRegistry` at open (proposed name, not shipped). The
SDK owns that local runtime's native helper, private bidirectional IPC, and
callback dispatcher. Bun functions remain in the trusted embedding process or
an SDK-owned, explicitly qualified Worker; the helper receives only bounded
messages and opaque adapter/resource handles. JavaScript callbacks execute on
the Bun event loop or that Worker, never on an arbitrary native OS thread.
No function, source, `eval`, or import string crosses the private IPC. Local
mode does not require a user-managed API server or callback-broker service;
automatic SDK-owned components may exist, but the library owns their lifetime
and authority. Remote mode keeps the separately provisioned authenticated
callback broker described in
[sandbox-api.md §2.1](sandbox-api.md#21-typescript-facade-remote-callback-broker-and-local-callback-bridge).
The two modes share observable contracts, not ambient authority.

Registry selection occurs at startup/open from validated configuration. Bind
handles to runtime identity, sandbox/generation, adapter version, and declared
rights. A new runtime, rebind, restart, or revoke creates a new epoch scoped
to the affected resource or registry; prior-epoch IDs and replies are
rejected and never promoted onto the new runtime or resource. Do not promise
hot-swapping privileged internals mid-run.
Bidirectional callbacks require a versioned protocol extension beyond the TS0
diagnostic allowlist: separate engine-request and callback-request correlation
namespaces, bounded byte/queue/concurrency budgets, deadlines, cancellation,
backpressure, and defined reentrancy (or rejection of callback-to-same-
operation recursion). The pump must service callbacks while an engine
operation is awaiting a callback; a simple serialized RPC loop can deadlock.
No callback may run under a helper lock that prevents cancel, close, or
receiving the callback response. Cancellation and revocation have four
distinct scopes:

1. **Wait/stream `AbortSignal`:** detaches and settles only that waiter or
   stream. It is not durable execution cancel and does not revoke the adapter
   registry, cancel a continuing guest, or disable unrelated registered
   FS/network adapters.
2. **Callback-request cancel/deadline:** revokes only that invocation and
   rejects its late response. Any dependent guest I/O failure follows that
   adapter's fence/unknown-side-effect contract; it does not revoke other
   registrations.
3. **Explicit durable operation cancel:** a separate generation-fenced,
   idempotent engine operation. It is not implied by waiter abort or by a
   single callback-request cancel.
4. **Resource/lease/registration revoke versus whole-runtime/registry
   teardown:** explicit revoke of one resource, lease, or registration
   revokes only that scope, its handles, and dependent I/O and epoch;
   unrelated adapters and leases remain usable. Runtime close,
   owner/helper/Bun death, or explicit whole-registry revoke tears down that
   runtime's registry and owned resources, rejects dependent guest I/O,
   settles promises, releases handles once, and reports uncertain durable
   writes.

No retry into ordinary host exec or an unrelated adapter. Parent death is
independent of ordinary JS finalization. A JS callback that blocks the Bun
loop cannot disable helper/provider-enforced operation deadlines. TS0
helper/1 may tear down its one-inflight diagnostic channel on abort; that
diagnostic teardown is not the executing-VM wait-abort contract.

**Local callback IPC byte ownership.** Request and reply payloads are either
copied bounded byte snapshots or owned versioned byte handles. Copy
validated, bounded inputs before asynchronous use; do not retain borrowed
Bun typed-array views, `ArrayBuffer` slices, or native buffers after the
agreed call boundary. Copy or transfer reply bytes into caller-owned memory
before the producer or bridge releases its source ownership. Internal
borrowed, scratch, and invocation buffers are released on completion,
cancel, or revoke. Successfully delivered copied or transferred byte results
remain caller-owned and valid until caller disposal or GC, including after
that invocation's completion, cancel, or later runtime/resource revoke.
Later runtime or resource revocation invalidates handles and authority, not
already delivered byte copies. A late canceled callback cannot publish a new
result. Callbacks receive immutable snapshots or sole-owned transferred
handles. If a qualified Bun `Worker` transfer is selected, transfer detaches
sole ownership and the sender must not access the buffer after transfer. The
initial callback profile rejects `SharedArrayBuffer`, raw native-pointer
zero-copy, and any shared-memory shortcut. Cancel, completion, or revoke
releases that invocation's internal payload ownership without promoting
borrowed views and without invalidating already delivered caller-owned
copies. These rules stay consistent with bounded
byte/queue/backpressure budgets and with the prohibition on invoking
JavaScript from arbitrary native helper threads.

In-process Node-API variants are a separate future and require supported
thread-safe/async dispatch plus independent Bun qualification. Portable Wasm
core and guest Wasm remain separate tracks. Node/Deno/macOS/ARM stay
unqualified. Activate local adapters only after version negotiation, bridge
protocol, and provider/adapter qualification pass. Until then, the
diagnostics package refuses callback and real-execution requests as
unsupported/unavailable. Required future fixtures live in Section 11.2.

Package CI runs typecheck/lint/unit tests, Node UDS/HTTPS fixtures, browser
fetch/proxy fixtures, generated-contract compatibility, stream/AbortSignal
tests, error/idempotency/generation negative cases, and package tarball
smoke. Future Bun-local CI adds library-only helper ownership, host-folder
then SQLiteFS guest-filesystem conformance, and callback
failure/revoke/queue/cleanup, abort-scope, epoch-rejection, and byte-ownership
tests, independently of Node/Deno/browser
qualification. Release publishes an identified tarball only after its API
version, SBOM/provenance, and integration suite match the promoted server
artifact. No cross-platform claim based only on interfaces.

### 8.2 Required WebAssembly interfaces

WebAssembly has two deliberately separate uses. Neither is an alternative to
the Linux launcher, VM, cgroup, broker, or server authentication boundary:

1. **Portable SDK core:** `packages/zig-sandbox-core-wasm/` is a planned
   `wasm32-freestanding` trusted codec, validation, and state-transition
   helper shared by TypeScript/browser consumers where useful.
2. **Guest workloads:** `guest/wasm/` is a planned, image-pinned Wasm runtime
   profile that runs *inside* a qualified Linux VM. It is how a tenant's Wasm
   command executes, never a reason to run it in the API process or on the
   client host.

No portable Wasm package, guest Wasm runtime/profile, or published production
SDK exists today. Unqualified private Bun TS0 source exists as a local-helper
and remote-diagnostics package; it does not complete those tracks. The
TypeScript production client, portable core, and in-VM guest workload profile
are all required delivery tracks before production promotion; they are not
optional substitutes for one another.
The initial portable core imports no functions and returns typed effects for
its authorized embedder to perform; it never imports a Linux launcher, host
filesystem, network, KVM, credentials, or a process executor. That boundary
matches WebAssembly's portability model: Wasm itself provides no OS APIs or
syscalls, while imported host functions define authority. [WebAssembly
portability](https://webassembly.org/docs/portability/)

**Proposed portable ABI:** the module exports its linear memory as `memory`
and versioned `zk_wasm_v1_*` functions: `abi_version() -> u32`,
`alloc(len: u32, align: u32) -> u32`, `free(ptr: u32, len: u32,
align: u32) -> u32`, and
`call(input_ptr, input_len, output_ptr, output_capacity, result_ptr) -> u32`.
Pointer zero is reserved as the null/alloc-failure sentinel; `free` returns a
status, and an invalid free leaves all existing allocation ownership unchanged.
The nonzero `call` return is an ABI/argument failure. On a zero return,
`result_ptr` addresses a caller-owned, fixed 16-byte little-endian descriptor:
`result_status: u32`, `written: u32`, `required_length: u32`, and a
zero reserved word. This makes JavaScript status parsing unambiguous.
`written` is actual output length; capacity is an input only. All input,
output, descriptor, and error bytes are caller-owned: the core allocates no
response, retains no pointer, and gives no callee-owned buffer to free.

The contract fixes UTF-8 or byte encoding per field, pointer bounds and
alignment, ownership transfer, zero-length buffers, overflow rejection, and
serialized calls. Every range, including the descriptor, is checked before
dereference; invalid alignment, overlap, out-of-memory range, overflow, or
invalid/double free fails without retained state. A short output buffer reports
`buffer_too_small` in `result_status`, `written = 0`, and the required
length; it writes no output and commits no effect/state transition. Errors use
the same caller-owned output/descriptor rule. The initial profile declares a
hard 64 MiB linear-memory maximum (1,024 Wasm 64-KiB pages) in the module and
qualification verifies that ceiling; it has no shared memory or threads and
enforces finite step/input/output limits. JavaScript refreshes typed-array
views after `memory.grow`, terminates a dedicated Worker for a hung
asynchronous invocation, and documents that `AbortSignal` cannot interrupt
a synchronous Wasm loop. The core may validate a response shape or a requested
transition; it cannot authenticate a principal, authorize an export, mint a
fence, or substitute for server-side checks.

| Wasm surface | Proposed contract and fail-closed rule |
| --- | --- |
| TypeScript integration | `@zig-sandbox/sdk` may load the version-pinned portable core for codec/validation only. It retains the Section 8.1 Node/browser transport rules, uses the same generated types/errors, and falls back to a reviewed JavaScript implementation only for equivalent local protocol processing, never for host execution. |
| Browser containment | Browser loading uses same-origin assets with integrity/version checks. It receives no UDS, mTLS private key, internal broker/FD/launcher handle, ambient browser credential, or cross-origin authority. A server-authorized opaque export resource ID may be used only through the normal mount API. A Worker termination reports a local SDK error and does not imply remote execution cancellation. |
| Guest module profile | The initial proposed profile is `wasm-core-p1`: a core module using the pinned `wasi_snapshot_preview1` runtime adapter shipped in the immutable Linux image. `wasm-component-p2` is a separate future capability with an explicit Component Model/WIT adapter, not auto-detection. A Zig `wasm32-wasi` build does not silently provide either profile. Runtime/image/adapter digest and supported ABI/world are part of the image capability record. |
| Guest authority | WASI filesystem access is restricted to explicit preopened guest directories with rights, not ambient host paths. Arguments, environment, clocks, random, network, and custom imports are separately declared capabilities. WASI's Component Model/WIT worlds define interfaces such as CLI command and HTTP proxy; profile selection pins the exact release rather than calling a release “latest.” [WASI releases](https://wasi.dev/releases/wasi-p2) |
| Guest containment | Per instance enforce memory/table/stack and input/output limits, fuel or epoch interruption where the runtime supports it, serialized host calls, and an independent host watchdog. A trap, malformed module, import denial, quota exhaustion, or cancellation yields a bounded terminal operation; it never routes to host execution. |
| Guest data/network | Module filesystem authority is the guest workspace or authorized guest mount only; a preopen cannot name an unregistered server folder. Network imports are absent in offline profiles and use the qualified Section 9.4 proxy/egress policy otherwise. Live host exports retain their Section 9.3 fence and RO/RW semantics. |

WP1 pins the `wasm-core-p1` ABI, adapter digest, and Linux image/runtime
version before its qualification corpus runs. If a later `wasm-component-p2`
capability is added, it must name its WIT world and adapter independently.
WASI 0.2 is described as stable but superseded by 0.3; this plan does not
label it the latest release or assume any toolchain implements it merely by
targeting `wasm32-wasi`. The browser embedding contract pins only qualified
features of the published [WebAssembly JavaScript API Level 2 Candidate
Recommendation Draft](https://www.w3.org/TR/wasm-js-api-2/); it does not
assume every current or future draft feature is available.

Required conformance covers malformed binaries/custom sections, validator and
ABI fuzzing, pointer/alignment/length/ownership and `memory.grow` cases,
effect denial, Worker hang/termination, version mismatch, and no ambient
imports for the portable core. Guest qualification covers hostile modules,
traps, recursive/flooding output, CPU/memory/table exhaustion, preopen
traversal/rights, network/import denial, egress enforcement, cancel/reset/
pause/stop/start/expiry races, and proof that a module cannot cross the VM or
invoke a host tool. A backend advertises Wasm only after this exact profile
passes; unsupported Wasm requests return `unsupported`, never a transparent
fallback.

## 9. Guest, workspace, images, egress, secrets

### 9.1 Protocol and ABI

Use versioned length-delimited CBOR or equivalently specified binary frames over
private serial initially. Vsock is a later, separately tested choice. Bound
frame size, field count, nesting, request IDs, sequence, total buffers, and
text validation before allocation.

Required messages: hello, ready, exec, started, stdio, exit, cancel, file put,
file get, file metadata, heartbeat, protocol error. Exec carries generation and
fencing token. Duplicate IDs replay accepted/terminal result; wrong generation
fails. Guest limits/times are observations only; host derives terminal result.

The experimental `zk-abi-v1` native profile remains static x86_64 ELF64 with
direct argv/workspace cwd and explicitly implemented syscalls; it rejects
dynamic/interpreter ELFs and unsupported operations. The required Linux
workstation profile accepts qualified dynamic executables/interpreters and
normal process semantics under its immutable image/package policy; malformed or
unsupported inputs still fail without crashing the host controller.

PTY/stdin/resize are required for the Linux workstation profile and feature
gated only for experimental/native profiles. Their protocol defines bounded
terminal dimensions/control input, client ownership, output escaping,
disconnect behavior, and a hostile-terminal test suite.

### 9.2 Workspace and images

Each image is an immutable raw guest base. Each generation receives a new
host-bounded writable block image connected only as a QEMU virtio-block device;
the guest formats/mounts it as its workspace. The host must never mount a
guest-controlled filesystem, expose ambient host root, bind-mount a client path,
or parse guest filesystem paths for authorization. Explicit user-authorized host
exports are a separate brokered capability described below.

Host `openat2`/dirfd rules apply only to service-owned image manifests, raw
base files, per-generation block files, and bounded staging inodes. The host
creates those objects under a service root with no tenant-selected components.
`O_NOFOLLOW` alone does not prevent hard-link aliases; staging must be a newly
created regular inode with trusted directory provenance, link count one,
validated type/ownership/mode, and no tenant ability to create links in its
parent. A missing safe Linux primitive fails closed.

Upload writes only to bounded host staging while hashing. After durable staging
record, host sends a framed `file_put` to the guest service; the guest writes
inside its own workspace, replies with path/size/digest, and host records commit
only after matching ACK. Download is framed `file_get` from guest service into
bounded host staging, hash-verified, then streamed to client. A client never
supplies a host path. Crash before host/guest commit leaves reclaimable staging;
crash after ACK reconciles against durable request/guest metadata. Active
mutation during execution is rejected by default; an explicitly approved future
concurrent-write mode needs per-file locking/fencing and tests.

Quota covers raw writable disk allocation, guest quota, staging, transfer,
metadata, retained output, snapshots, and cleanup reservation. Reset/destroy/
expiry remove the generation disk after kill/reap; timeout/cancel preserves the
disk when the state remains valid, as defined in the lifecycle table.

### 9.3 Authorized host-folder exports

The server host registers a folder through a trusted `HostExportBroker` using
an already-open source directory FD, not a remote path string. Policy records
owner, immutable export ID, source device/inode, allowed principal, mode,
quota/capabilities, and expiry; it returns an opaque export handle. A sandbox
may attach only that handle to an approved guest target such as
`/workspace/project`. Read-only is default; read-write is an explicit owner
authorization, and host changes are limited to the registered export.

NativeHostExport uses a dedicated sandboxed virtiofsd or bounded FSRPC guest
bridge. It applies per-export UID/capability policy, read-only enforcement,
range/operation quotas, source-FD validation, and mount fencing. It must not
expose sibling directories, host root, devices, special mounts, ambient host
PATH/environment/credentials, or arbitrary filesystem types; unsupported
requests return `unsupported`. The host never mounts the guest filesystem.

The shared FS adapter contract defines namespace handles, open/read/write/seek/
stat/readdir/create/unlink/rename/flush/locks, capability negotiation, inode
identity, errors, durability acknowledgment, and declared symlink/hard-link/
cross-mount semantics. Tests cover RO denial, symlink escape, hard-link/race,
sibling hiding, source replacement/revocation, and reset/destroy races. Future
Bun host-folder and Bun SQLiteFS adapters implement this same contract with
declared features; missing operations return typed `unsupported`. Guest use
still requires the qualified mount bridge above. Callback completion is not
mount proof, and `bun:sqlite` is not a POSIX filesystem or host-folder
fallback.

Live export data survives sandbox reset, destroy, and expiry: revoke/fence the
mount capability before VM teardown, but never delete the host folder. Copy-in
upload is separate from live export: it copies bytes into internal workspace
and is resettable. A remote client folder is not a server folder; use copy-in
or an explicitly enabled authenticated, scoped client-export agent bridge.

Image manifest contains image ID/digest, ABI, provenance, QEMU compatibility,
creation metadata, and qualification-artifact reference. Runtime accepts only
allowlisted digests and never fetches tenant-supplied image URLs.

Snapshots/forks, if approved later, are distinct bounded features: immutable
base plus copy-on-write ownership, depth/count/storage quotas, lease/fence
rules, cleanup, cross-tenant prohibition, and recovery tests. They are not
implied by reset.

### 9.4 Egress and secrets

Default network capability is offline: enforce `-nic none` plus network
namespace. A qualified allowlist network profile is required before G11 can
claim apt/pip/npm/package-install workflows. Add WP10a Network profile before
WP12: an engine-owned network adapter/proxy/DNS enforcement module with
destination/TLS/protocol/method policy, DNS rebinding defense, IP-literal and
IPv4/IPv6 metadata-range blocks, proxy credential isolation, redirect policy,
connection/bandwidth limits, audit, and SSRF/package-install corpus. The Linux
image capability advertises either `offline` or the qualified allowlist profile;
“no network requested” is not enforcement.

Secrets are excluded initially. A later feature must define typed secret
references, principal authorization, single-execution delivery, redaction,
revocation, zeroization limits, audit metadata, and no default persistence in
environment, CLI, request records, images, events, or logs.

### 9.5 Normal Linux developer-workstation acceptance

Production acceptance requires the qualified Linux guest profile to behave as a
normal constrained developer workstation, not merely execute static ELF.

| Required behavior | Qualification evidence |
| --- | --- |
| Bash shell, Python/Node, Git/ripgrep/common toolchains, dynamic linker/libc and approved package managers | Build/test representative projects using exact image lockfiles and package policy. |
| Fork/exec/subprocess/signals/job control, pipes, PTY/stdin/resize | Interactive and noninteractive process-tree/signal/terminal corpus. |
| POSIX files advertised by profile: locks, atomic rename, mmap, flush/durability, notifications | Native disk, SQLiteFS, and host-export adapter conformance with feature/capability truth. |
| Offline and approved-network profiles | Offline package/build runs; allowlisted TLS/package install runs with DNS/proxy/metadata controls. |
| Internal workspace and authorized host exports | Persist/reset/recovery, RO/RW export, revoke, and host-change preservation tests. |
| Writable guest root/home/tmp | Immutable base plus bounded per-session COW root; reset wipes root-layer changes while RW live export changes persist. |
| Stop/start persistence | Stop/reap then start preserves qualified internal package/COW disk state and export origins, but starts fresh processes and re-reserves running capacity. |
| Developer workflow | Git status/edit/build/test on mounted project, apt/pip/npm install and run under scoped egress, with observed authorized host changes. |
| Live pause/resume | Mid-build PTY subprocess with authorized mount pauses as one session; counters stop/continue as declared, resume continues same execution/event cursor without rerun. |
| Web development ingress/observability | Declared loopback guest port publish and revoke, scoped ingress, health/metrics/logs, with no ambient host-network listener. |

Define OS/runtime image, package source/locks, interpreter/libc/linker, update/
CVE process, and supported tuple. Build reproducible immutable images with
signed/digested provenance. The Linux profile is not advertised until the full
matrix passes exact promoted artifacts; the Zig-native profile remains
experimental until it passes the same matrix.

The guest supplies an explicit normal user, home, tmp, PATH, and sanitized
environment. A guest-root/sudo capability may be offered inside the VM only; it
never conveys host privilege. The profile states device/GUI/GPU/browser limits
honestly: headless/browser workloads are accepted only when their image profile
qualifies them. “Normal computer” means this explicit constrained workload
matrix, not unrestricted hardware, host root, or every unqualified OS feature.

Guest-local CI (act) is a **separate** planned gate:
[sandbox-local-ci.md](../docs/sandbox-local-ci.md). Pinned nektos/act, dockerd,
job/action/service containers, cache, and artifacts must run **inside** the
sandbox Linux guest. Mounting the host Docker socket is never a qualification
path. **L1** (qualified Linux VM provider + act) is independent of **N1**
(native zig-kernel replacement of the same fixtures). Neither is implemented.

### 9.6 Enabling host tools safely

“Run a host tool in the sandbox” means run a guest-compatible copy of that
tool inside the VM; the original host process remains on the host. A Windows PE
tool cannot execute under the Zig ELF ABI, and matching command names/syscall
labels do not create Linux compatibility. Git, ripgrep, Python, Node, dynamic
libraries, interpreters, package data, and CA material therefore require a
qualified Linux guest image, or a separately ported custom-ABI tool.

| Contract | Guest tool adapter (recommended) | Host capability adapter (optional, explicitly authorized) |
| --- | --- | --- |
| Registry input | Tool manifest: ID, image digest, guest executable, exact argv/env/cwd/stdin, limits, network policy | Typed capability, allowed object/action, caller principal, limit, audit purpose. |
| Execution | `ToolRegistry` maps tool call to `ToolExecutor` Sandbox API; it never inherits host PATH/env/mounts/`/usr/bin`/credentials. | `HostCapabilityBroker` performs only declared RPC; it is a host operation, never VM-isolated execution. |
| Packaging | Build bundle with transitive libraries/interpreter/data/CA; verify architecture, ABI, and digests; install in immutable `/tools` image or upload through framed workspace protocol. | No arbitrary shell/exec, path, QEMU option, or credential pass-through; permission/object/limit checked per call. |
| Failure | Reject unsupported tool/image/missing dependency before exec; never host-fallback. | Reject absent/unauthorized capability; never substitute it for missing guest execution. |

**Proposed guest workflow:** publish the immutable qualified tool image/bundle;
register manifest against its image digest; create sandbox; wait ready; upload
input if needed; execute exact guest argv; inspect/wait operation; stream bounded
output; download declared result files; destroy/reset by session policy. A future
CLI may expose `zig-sandbox tools run TOOL -- …` only after this contract exists;
the current bootstrap returns 501 and runs no tool.

The ToolRegistry and ToolExecutor are swappable engine contracts with
capability/version negotiation. Conformance and negative tests cover manifest
digest/ABI/dependency mismatch, unsupported image/tool, inherited-environment
attempt, argv/path injection, guest timeout/output/disk pressure, ownership/
generation fencing, and proof that unavailable guest tools do not invoke host
exec. HostCapabilityBroker tests also cover every denied permission/object/
limit and audit record. SQLiteFS stores workspace bytes; it does not isolate or
execute tool processes.

## 10. Ordered work packages

| WP | Depends | Owner files | Deliverable | Acceptance | Findings |
| --- | --- | --- | --- | --- | --- |
| WP1 Contract freeze | none | OpenAPI, ABI, `model.zig`, adapter contracts | Versioned lifecycle/limits/errors/capabilities/CLI and adapter interfaces | Schema and CLI/model tables agree; no false Linux claim | F01,F04,F07,F08 |
| WP2 Build/argv/harness | WP1 | build files, `qemu_argv.zig`, scripts | Server/client targets, package paths, safe argv, deterministic QEMU test | Boundary/fuzz no overflow; expected exits captured; pinned QEMU manifest | F14,F15,F22,F23 |
| WP3 Engine/store | WP1 | `engine.zig`, `store*.zig`, migrations | SQLite/WAL, IDs, leases, idempotency, audit/events, adapter registry | Crash-point/concurrency and state-store conformance produce one fence winner | F06,F09-F12,F17 |
| WP4 Server/auth | WP1,WP3 | server/http/sse/auth/service | UDS SO_PEERCRED, optional mTLS, bounded API | Cross-UID denial, parser/slow-client bounds, SSE resume | F01,F07,F09,F10 |
| WP5 Linux launcher | WP1-WP3 | `linux/*`, runtime, jail | Applied cgroup/ns/UID/FD/seccomp/QEMU and rollback | Child inspection proves every control; injected failures clean up | F02,F03,F05,F13,F17 |
| WP5b Cross-platform providers | WP1-WP4,WP5 | `providers/{macos,windows}/*`, provider contract/tests | Hypervisor.framework and selected Hyper-V/WHPX local-provider implementations | AP4 provider capability, tenant lifecycle, pause/recovery, and no-host-fallback suites pass | F01,F03,F07 |
| WP6 Lifecycle/recovery | WP3,WP5 | engine/process/recovery tests | Fenced cancel/reset/destroy/TTL/restart/pause-resume | ESRCH/reap, paused cancel/reset/expiry, snapshot capability, crash/duplicate/orphan matrix passes | F11-F13,F15 |
| WP7 Workspace/images/exports | WP1,WP3,WP5 | workspace/image/export contracts, native/SQLiteFS/HostExport adapters | Guest disk/COW root, transfer, mount catalog, quota, registry | Adapter and export revoke/RO/RW/race conformance; no host escape. Same guest FS vectors later apply to qualified Bun host-folder and Bun SQLiteFS adapters (WP10b); callback completion is not mount proof | F06,F16 |
| WP8 Guest profiles/VM | WP1,WP5,WP7 | Linux profile/VM backend plus x86_64/proc/agent source | Linux developer profile implementation and native experimental parity path | Guest unit/boot/ABI backend tests pass; native promotion additionally closes F04/F08/F18-F21 | F04,F05,F08,F18-F21 |
| WP9 End-to-end/tools | WP4-WP8 | guest link/engine/runtime/tool registry/tests | Framed exec/files/mounts/output, pause acknowledgement, and guest ToolExecutor | Frame/silence/flood/reset/export/pause/tool negative cases bounded | F03,F07,F08 |
| WP10 CLI | WP1,WP4,WP9 | CLI/client/docs | Remote client and `--local` worker mode | UDS/TLS/JSON/signals/retry/TTY/platform negative tests | F01,F07 |
| WP10b TypeScript SDK | WP1,WP4,WP9 | `packages/zig-sandbox-client/*`, OpenAPI fixtures, package CI | Typed Node/browser remote SDK, Bun `/local` library, and versioned package contract | Remote transport/auth/stream/AbortSignal/idempotency/generation/package-tarball tests pass; no host fallback. **Future Bun-local (not TS0):** a Bun app imports `/local`, registers a real host-folder FS adapter then a SQLiteFS adapter, runs the same guest FS conformance without a user-managed API or broker service, and passes callback failure/revoke/queue/cleanup, abort-scope, epoch-rejection, byte-ownership, plus identity-separation tests; no host-exec fallback; remote parity of observable contracts | F01,F07,F09,F10 |
| WP10c WebAssembly interfaces | WP1,WP4,WP8,WP9,WP10b | `packages/zig-sandbox-core-wasm/*`, `guest/wasm/*`, runtime image/profile fixtures | Portable Wasm SDK core plus in-VM guest-Wasm runtime/ABI profile | Portable ABI/import/Worker corpus and exact guest runtime/WASI/hostile-module corpus pass; no host-exec or ABI fallback | F01,F04,F07,F08 |
| WP10a Network/ingress profile | WP4-WP9 | network adapter/proxy/DNS/ingress/observability policy, image capabilities, tests | Offline default, qualified allowlist package network, declared loopback port publishing | DNS/proxy/SSRF/package-install/ingress revoke/metrics-log corpus passes before WP12 can use egress | F07 |
| WP11 Ops/qualification harness | WP2-WP10c | service docs, CI, release harness | install/metrics/backup/upgrade rehearsal and non-promoting artifact harness | Upgrade/rollback rehearsal and hash-linked evidence collection; no promotion occurs here | F06,F23 |
| WP12 Workstation qualification | WP8-WP11,WP10a | Linux image/corpus/VM adapters | Required Bash/Python/Node/toolchain/package/PTY/process/export profile | G11 exact-artifact normal-workstation matrix passes | Native-parity F04/F08 only; not Linux-profile blockers |
| WP13 Container/adapters | WP1,WP5,WP7,WP11 | Dockerfile, container docs, `tests/adapter/*` | API container image and all adapter conformance suites | Container fails closed without KVM/cgroup delegation; every selectable adapter passes contract/negative/crash tests | F02,F06,F07,F16 |
| WP14 Final release/promotion | WP11-WP13 | release manifest, promotion tooling, operations sign-off | Promote exact qualified binary/image/broker manifests | G1-G11, including mandatory G8W, and release hash equality reviewed before one-way promotion | F06,F23 |

## 11. Operations, upgrades, and promotion

**Proposed prerequisites:** supported Linux/kernel, cgroup v2 delegation, KVM
policy, pinned QEMU, suitable filesystem, service account/group, and TLS key
provider if remote listener enabled. Missing prerequisites fail closed; no TCG
or host-exec substitution.

Service manager configuration owns a private runtime dir, restricted writable
paths, control-plane resource reserve, restart policy, audit retention, and
health probes. Metrics cover capacity, transitions, watchdog causes, parser
rejections, reconciliation, QEMU launch, and cleanup without raw sandbox IDs,
commands, or principal labels.

### 11.1 API container delivery

The requested Dockerfile is a delivery artifact, not an isolation boundary.
**Current delivery:** [Dockerfile](../Dockerfile) builds the Linux-musl
`zig-sandbox` bootstrap and starts `--host=0.0.0.0 --port=8080`. Its only
truthful surface is health 200, ready 503, capabilities `execution:false`, and
501 sandbox operations. It needs neither KVM nor broker privileges. Reproduce
with the [README](../README.md#sandbox-api-diagnostics) commands
(`docker build -t zig-sandbox-bootstrap:local .` and loopback
`-p 127.0.0.1:HOST:8080`). Internal listener and healthcheck port are fixed at
8080; only the published host port varies. It is an API bootstrap smoke only,
never a runnable sandbox demonstration. It implements neither execution nor
mount/export handling. There is **no** currently published or reproducible
release-image digest. Historical 2026-09-13 audit digest
`sha256:f5787133b2b0a2f6d067bf74b1c275babd43f28e12ccf9182be3ba5188c66310`
is E1b snapshot only.

The [README Sandbox API (diagnostics)](../README.md#sandbox-api-diagnostics)
section documents this diagnostic surface and its Node capability example; it
does not claim that the bootstrap executes sandboxes. [README Roadmap](../README.md#roadmap)
describes private Bun TS0 draft diagnostics; the full production SDK and both
Wasm tracks remain planned. Planned package names remain Sections 8.1-8.2.

**Proposed production container contract:** pin base-image/build-input digests;
use multi-stage build; create non-root service UID/GID; use read-only root;
declare only service-owned control-state/runtime mounts; expose remote TLS only
when configured; and contain no tenant images, mutable guest database,
credentials, KVM device, or Docker socket.

The production API container remains unprivileged and talks over a dedicated
authenticated Unix socket to a narrowly scoped Linux `HostLauncher` broker.
The broker, outside the API container, owns systemd transient workers, KVM,
cgroup delegation, namespaces, seccomp, raw image/block files, and guest
storage. It accepts only typed leased image/limit/workspace handles and returns
structured lifecycle outcomes; it never accepts generic exec, arbitrary QEMU
arguments, Docker API access, or tenant paths. QEMU remains below the broker’s
transient-unit cgroup. A separate internal-systemd deployment profile would
need its own complete qualification and is not assumed by the container.

Container bootstrap acceptance for this tree is the diagnostic HTTP record in
[sandbox-api-implementation.md](../docs/sandbox-api-implementation.md)
(non-root UID 999, read-only root, capabilities dropped, healthcheck healthy,
15/15 diagnostic HTTP checks). It does not establish production broker
isolation and does not pin a release image digest. Production broker
qualification separately proves socket authentication, handle validation,
QEMU descendant cgroup, and G2-G11 including G8W on exact API/broker/image
manifests. Neither
a container database nor a filesystem adapter replaces host isolation.

### 11.2 Adapter conformance

Each selectable adapter passes a common contract suite plus its domain suite:
capability/version negotiation; malformed input; permission/opaque-handle
checks; limit/quota exhaustion; cancellation; concurrent fencing; crash
before/after commit; restart reconciliation; metrics/audit redaction; and
unsupported feature behavior. Filesystem adapters additionally test directory
ordering/pagination, byte-range reads/writes, atomic same-adapter rename,
cross-adapter copy semantics, fsync/durability acknowledgement, permissions,
regular-file-only policy, symlink/hardlink policy, quota reservation, and
staging cleanup. The same test vectors run against the common native guest VFS
and SQLiteFS guest VFS behavior, not merely host staging. A future qualified
Bun host-folder adapter and Bun SQLiteFS adapter must pass those same guest
vectors through a qualified mount bridge (virtiofs, 9p, virtio-block, or
bounded FSRPC per provider). Callback completion is not mount proof.

**Required future Bun-local fixtures (not TS0, not current G10).** These close
WP10b/AP5 local acceptance after version negotiation, bridge protocol, and
provider/adapter qualification. They do not change today's diagnostic
capabilities.

| Fixture | Evidence required |
| --- | --- |
| Bun library-only integration | Fresh application imports `/local`, supplies adapters, opens and owns helper/dispatcher/provider, runs operations, closes; no user-managed API or broker process/socket is required |
| Common filesystem suite on actual guest calls | Same vectors through native guest disk, explicitly approved host folder, Bun filesystem callback, and Bun SQLiteFS: dirs/list/pagination/ranges/atomic rename/durability/quota/permissions/link semantics; unsupported features are truthful |
| SQLiteFS persistence distinction | Guest creates/renames/reads bytes through the callback bridge, closes/reopens the adapter, verifies persistence and crash outcome; control Store and isolation are independently qualified |
| Native folder authority | RO/RW/masks, symlink swap/path traversal/outside-root handles, revoke and generation races; no exposure beyond approved roots |
| Network/policy injection | Equivalent allow/deny decisions on named profiles; callback cannot widen egress, credential, or resource ceilings; deny adapter remains swappable |
| Callback protocol/lifecycle | Interleaved engine reply and callback, bounded queue/flood, byte-stream backpressure, slow/throwing/reentrant callback, timeout; wait/stream abort of an unrelated waiter leaves registered FS/network adapters and the running operation usable; per-callback cancel versus whole-runtime close/death/whole-registry revoke; explicit revoke of one FS export leaves an unrelated network adapter/export in the same runtime usable; late/duplicate response after cancel; helper/Bun death; no deadlock or orphan success |
| Callback byte ownership | Caller mutates its submit buffer after enqueue without changing the in-flight snapshot; a received copied/transferred byte result remains unchanged after completion, later runtime close/revoke, and producer reuse or mutation of its source buffer; late callback/return cannot observe or write borrowed caller/native buffers after completion/cancel, and a late canceled callback cannot publish a new result; qualified Worker transfer/detach leaves the sender without access and cleans up; no SharedArrayBuffer/shared-memory shortcut; ownership remains consistent with byte/backpressure/native-thread limits |
| Identity separation | Cross-runtime/cross-sandbox/stale-generation/prior-epoch callbacks rejected; a new runtime/rebind/restart/revoke never promotes old handles; remote transport never launches a local helper or inherits a local callback/path/credential grant |
| Durable side effect | Crash before/after SQLiteFS or other adapter commit returns success only when its contract permits; retries respect operation IDs/fences and reconcile uncertain commit |
| Tarball and platform | Actual Bun package consumer and helper artifacts on each claimed host, independent from Node/Deno/browser qualification; no cross-platform claim based only on interfaces |
| TS0 negative boundary | Diagnostics package refuses callback/real-execution requests as unsupported/unavailable until the complete configured bridge/provider gate passes |

Upgrade: stop admission; drain/fence work; cancel/finish by policy; snapshot
and verify database; migrate under singleton lock; start new binary; reconcile;
readmit. Rollback requires tested database compatibility or restore, not merely
an older binary.

Promotion: build identified bytes once; produce binary/image/manifest hashes;
qualify exact bytes on exact Linux/QEMU/KVM profile; preserve raw logs/config;
review gate evidence; promote same hashes. Rebuilding after tests invalidates
qualification.

## 12. Qualification gates

| Gate | Required checks | Pass condition |
| --- | --- | --- |
| G1 Contract | Schema/API/CLI/model consistency and negative cases | One versioned contract, server-derived identity, no implied Linux ABI. |
| G2 Host | cgroup/KVM/QEMU discovery; launcher failure injection | Required control observed or startup fails closed. |
| G3 Isolation | IDs, namespaces, FDs, cgroups, seccomp, no-new-privs, QEMU argv | Per-session process conforms with no unexpected host resource. |
| G4 Abuse | CPU/memory/fork/output/disk/frame/slow HTTP/SSE | Control plane responsive and bounded terminal result. |
| G5 Storage/identity | Traversal/link/race/digest/cross-user/stale-generation/export revoke | No cross-sandbox or host access outside authorized exports; RO/RW policy is respected and rejection auditable. |
| G6 Lifecycle | stop/start/cancel/reset/destroy/TTL/pause/resume/snapshot/VM crash/server crash each durable phase | No orphan; correct fence/idempotency/terminal record and fail-closed external-resource handling. |
| G7 Guest | CPL3/long-mode/W^X/preemption/ELF/syscall/agent corpus | Guest failure cannot hang/crash controller; ABI programs work. |
| G8 Server/CLI/TypeScript SDK | UDS/mTLS/parser/SSE/CLI/Node/browser transport-auth/stream-abort/version/package tests, including required G8W and sandbox-api AP4 providers | Supported interfaces are bounded, usable, contract-compatible, and cross-platform provider-qualified. |
| G8W WebAssembly (mandatory G8 subgate) | Portable-core ABI/import/Worker tests plus exact in-VM `wasm-core-p1` runtime/WASI hostile-module corpus | Wasm interfaces remain portable and bounded; a qualified guest profile cannot escape or silently fall back to host execution. |
| G10 Adapters/container | Native/SQLiteFS contract suite; API container prerequisite/identity/cgroup tests | Every configured adapter and the container digest satisfy their declared contract or fail closed. |
| G11 Normal workstation | Linux guest shell/toolchains/package manager/process/PTY/POSIX/COW/export/offline+egress/live-pause corpus, including dev server plus second terminal/tool | Exact profile completes the declared developer workflow with constrained capabilities, same-exec pause/resume, and observed authorized host changes. |
| G9 Final release | Runs only after G8W/AP4/G10/G11: full required gates on exact binary/image/QEMU/kernel/broker manifest | Evidence hashes equal promoted artifact hashes and WP14 promotion input. |

E5/E6/E7 are useful regressions and boot signals only. They do not satisfy
G2-G11, including mandatory G8W, as a production sandbox qualification.

## 13. Traceability

| Requested result | Plan coverage |
| --- | --- |
| Production agent sandbox | Sections 3-12; WP1-WP14; G1-G11, including mandatory G8W. |
| Server | Sections 5-7, 11; WP3-WP6/WP11/WP14. |
| CLI | Section 8; WP10/G8. |
| TypeScript SDK | Section 8.1; `packages/zig-sandbox-client/`; WP10b/G8. |
| WebAssembly portable core and guest workloads | Section 8.2; `packages/zig-sandbox-core-wasm/` and `guest/wasm/`; WP10c/G8W. |
| Shared remote/local core | Engine architecture, durable lifecycle, local worker mode. |
| Linux/macOS/Windows local providers | Sections 1, 7, 8; WP5/WP5b/G2. |
| Windows/macOS clients and providers no fallback | Section 8; WP5b/WP10/G8. |
| Zig-native route retained as experimental | Sections 5.2/9.1; WP8-WP9/G7/G11. |
| Normal Linux Bash/Python/Node workstation | Section 9.5; WP8/WP12/G11. |
| Docker API delivery | Section 11.1; WP13/G10. |
| Current README/API integration guide | Section 11.1 and [README diagnostics](../README.md#sandbox-api-diagnostics); current diagnostic record in [sandbox-api-implementation.md](../docs/sandbox-api-implementation.md). Historical E1b image digest is not a current release. |
| Planned README SDK/Wasm integration | [README Roadmap](../README.md#roadmap); Sections 8.1-8.2/WP10b-WP10c. |
| Checkpoints vs dirty-page capture | Section 5.1/5.3; [sandbox-checkpoints.md](../docs/sandbox-checkpoints.md); [smolvm-features.md](smolvm-features.md). |
| Act-in-guest (L1 vs N1) | Section 9.5; [sandbox-local-ci.md](../docs/sandbox-local-ci.md). |
| Swappable host/guest-boundary subsystems | Section 5.1; WP1/WP3/WP7/WP13/G10. |
| Safe host-tool workflow | Section 9.6; WP9/G7-G11. |
| Authorized host-folder mounts | Section 9.3; WP7/WP9/G5/G11. |
| Pause/resume and snapshots | Sections 5.1, 7.2, 8; WP6/WP9/G6. |
| Complete ordered plan | Section 10 plus Section 12. |

## 14. Proposed deployment defaults and release configuration

The implementation plan can proceed using these defaults; an operator chooses
the concrete configuration at deployment/release review, not by treating
silence as an approval of a new workflow.

| Configuration point | Proposed default | Release check |
| --- | --- | --- |
| Linux provider exposure | Linux/Unix UDS only; remote listener disabled | Socket permissions/SO_PEERCRED mapping tested. |
| macOS provider exposure | launchd-managed local IPC and owned signed helper; remote listener disabled | Native peer identity, helper signature, lifecycle, and AP4 provider tests pass. |
| Windows provider exposure | Service-owned named pipe with restrictive ACL/SID mapping; remote listener disabled | Pipe impersonation/ACL, service identity, lifecycle, and AP4 provider tests pass. |
| Remote access | TLS 1.3 mTLS only when explicitly enabled | Client chain and principal mapping negative cases pass. |
| Linux local runner | Linux systemd transient worker | Worker `Type=exec`/`RuntimeMaxSec`/`KillMode` and cgroup cleanup inspected. |
| macOS local runner | launchd-supervised VM provider and owned helper | VM/process containment, lease/reap/recovery, resource accounting, and AP4 pass; unavailable prerequisites fail closed. |
| Windows local runner | Windows service plus Job Objects and selected Hyper-V/WHPX provider | VM/process accounting, kill/reap/recovery, named-pipe identity, and AP4 pass; unavailable prerequisites fail closed. |
| Linux host support | Pinned Linux/kernel/QEMU/KVM manifest | G2/G3 run on that manifest; no TCG fallback. |
| macOS/Windows host support | Pinned OS/build/architecture/virtualization manifests | AP4 proves selected provider and capabilities; no claim of Linux cgroups/namespaces/seccomp. |
| Identity | Operator-managed UID/GID allowlist and mTLS principal mapping | Cross-principal negative tests and audit records pass. |
| Persistence | Local SQLite WAL/FULL and service-owned backups | Power/restart/crash-point tests and restore rehearsal pass. |
| Limits | Calibrated per host/provider class, reserving VM/control-plane headroom | G4 and AP4 confirm configured limits, accounting, and no host starvation. |
| Images | Allowlisted immutable digest/provenance only | Promoted image/binary hashes equal final G9 test manifest. |
| Egress/secrets | Disabled | Any enablement requires its separate Section 9.4 capability gates. |
| Compatibility | Qualified Linux workstation profile; `zk-abi-v1` native profile remains experimental | Bash/Python/Node appears only after WP12/G11 evidence. |

Until G1-G11, including mandatory G8W and AP4, pass on promoted hashes, describe the
repository as a sandbox design and host-policy prototype, not a production
agent sandbox.
