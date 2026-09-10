# zig-kernel Agent Sandbox — Master Doc

Status: M1-M7 hosted contracts and policy foundations implemented. Production
Linux supervisor and guest qualification remain outstanding.
Contracts: `sandbox-api.openapi.yaml` (public API) + `sandbox-abi.md` (zk-abi-v1 + guest protocol).

## 1. Baseline

- Hosted kernel qualification: 58/58 direct test cases pass; supervisor: 19/19.
- QEMU artifact builds: `kernel-baremetal` 45496B via `zig build qemu-bin`.
- Tree clean at `f5c5edc` (signal RT fix included).
- Linux CI/QEMU runtime qualification is still pending; Windows is not the
  production supervisor target.
- Current bare-metal target is **32-bit**: kernel-only GDT entries, identity paging.
  No isolated user execution yet. This is Milestone 2's job.
- Hosted syscall simulation does not intercept arbitrary programs (no gVisor-style trap).

## 2. zig-kernel inventory (sandbox relevance)

- `src/main.zig`: hosted simulation. Init order mm → sched → vfs → driver → caps → net →
  socket → proc. Demo tasks: idle, logger, net_watch.
- `src/syscall.zig`: ~60 handlers registered, table size 450. No filter — any task
  calls any handler.
- `src/arch/x86_64/entry.zig`: table of function pointers. `Ring` enum is a label only
  in hosted mode. No hardware rings.
- `src/sched/sched.zig`: 32 tasks, priority preempt, slice 3, vruntime, cpu_time.
  No quotas, no groups.
- `src/proc/proc.zig`: 64 processes. uid/euid/gid fields copied on fork, never enforced.
  ELF32 loader + `src/proc/elf.zig` ELF64 loader. `execve` simulated. No clone/namespaces.
- `src/mm/mm.zig`: 4096 pages (16 MiB), VMA + COW + 256-page reserve.
  No user/kernel split in hosted mode. `src/arch/i386/paging.zig` bare-metal only.
- `src/vfs/vfs.zig`: ramfs, 128 inodes / 128 dentries / 256 files / 16 mounts.
  mount/umount exist. No chroot jail, no read-only enforcement, no overlay.
- `src/net/net_core.zig`: global RX queue (32). e1000 + virtio_net loopback only.
  AF_UNIX / AF_INET / STREAM / DGRAM / RAW sockets. No net namespace, no egress rules.
- `src/security/caps.zig`: 38 caps as global bools with root-like grants.
  No per-process sets. LSM hook is a stub.
- `src/baremetal.zig`: multiboot + Xen note, COM1 serial, GDT/IDT/paging,
  QEMU `-kernel` load at 0x100000. Real CPU boundary, no orchestration.

Missing for sandbox use: namespaces, seccomp filter, resource limits, FS jail,
net policy, snapshot/reset, timeout kill, guest agent API, audit.

## 3. Peer research (sources inline)

- **Firecracker**: separate guest kernel on KVM. Jailer sets up cgroup + chroot, drops
  privs, execs unprivileged. Seccomp limits host calls. virtio net/block rate limiters.
  Boot ~125 ms, ~5 MiB overhead. Users: Lambda, Vercel Sandbox.
  Source: `github.com/firecracker-microvm/firecracker` docs/design.md,
  `fly.io/learn/firecracker-vs-gvisor`.
- **gVisor**: userspace kernel (Sentry, Go). Intercepts syscalls, serves ~237 itself,
  ~53 host calls only. Gofer mediates filesystem. Own netstack. `runsc` OCI runtime.
  Users: Cloud Run, GKE Sandbox, OpenAI, Anthropic.
  Source: same fly.io piece, `safeguard.sh` 2026-04-02.
- **nsjail / bubblewrap**: OS jails. Namespaces (UTS MOUNT PID IPC NET USER CGROUP TIME).
  chroot/pivot_root, read-only mounts. rlimits + cgroup v1/v2. Kafel seccomp-bpf
  (`ALLOW {read write} DEFAULT KILL`). No API, no lifecycle. Shared kernel = escape path.
  Source: `github.com/google/nsjail`, `nsjail.dev`, `pandastack.ai/blog` 2026-06-17.
- **E2B**: Firecracker fleet, control/data split. Per-node orchestrator. envd in-VM agent:
  process start/list/kill, stdout/stderr stream, PTY, filesystem API. Snapshot resume,
  COW rootfs over NBD, UFFD lazy pages, per-slot netns + NAT + nftables SNI egress filter.
  `Sandbox.create()` → `runCode()`.
  Source: `github.com/e2b-dev/infra` docs/ARCHITECTURE.md, `docs.e2b.dev`.
- **Kata Containers**: pod per VM (QEMU / Cloud Hypervisor / Firecracker backends),
  confidential SEV/TDX, GPU passthrough.
  Source: `rywalker.com/research/container-vm-runtimes`.

Common sandbox anatomy: boundary + syscall gate + filesystem overlay + net policy +
limits + lifecycle/snapshot + in-guest agent + audit.

## 4. Decisions (blocking questions resolved)

| Question | Decision |
|---|---|
| Threat model | Generated code and dependencies treated as potentially hostile. Protect host and other sessions even if guest kernel compromised. |
| Isolation | One VM per sandbox session. Deadlines, ceilings, network restrictions enforced outside guest. |
| Deployment | Linux x86_64 + KVM. Windows = dev/client only; QEMU emulation for functional tests. Host availability is an implementation prerequisite, not a plan blocker. |
| First workload | Stateful sessions: upload files, execute, capture output, retrieve artifacts, reset, destroy. |
| Initial executable support | Static ELF64 programs against documented zig-kernel ABI. Bash/Python/Node/`zig build` = explicit later compatibility milestones. |
| VM backend | QEMU first. Firecracker evaluated after guest boot + device compat proven (its documented supported path uses Linux guests). |
| Persistence | Session files persist until reset/expiry/destroy. Memory snapshots + forks later. |
| Network / secrets | Network disabled initially; later host-enforced egress. No inherited host creds, env, or mounts. |

Corrections to earlier report: bare-metal target is 32-bit (not a 64-bit user/kernel split);
hosted mode has no program interception (not gVisor-like).

## 5. Architecture

Three parts:

1. **Host supervisor (trusted)**: owns VM lifecycle, policy, limits, file transfer,
   event stream, audit. Runs on Linux host.
2. **VM (untrusted)**: zig-kernel + execution service (envd analog) on serial/vsock.
3. **Guest programs (hostile)**: run in guest user mode under validated ELF64 loader.

Rule: guest messages never grant host permissions or relax limits.

## 6. Public API proposal (v1, HTTP/JSON + SSE)

Local Unix socket on Linux host first; remote access requires authenticated transport.
Every operation checks sandbox ownership.

| Endpoint | Contract |
|---|---|
| `GET /v1/capabilities` | Backends, guest ABIs, image IDs, features, resource ceilings. |
| `POST /v1/sandboxes` | Create session from immutable image + explicit policy/limits. |
| `GET /v1/sandboxes/{id}` | State, generation, effective limits, expiry, usage. |
| `POST /v1/sandboxes/{id}/executions` | Start executable: argv, cwd, env, deadline. |
| `GET /v1/sandboxes/{id}/executions/{execId}` | State, exit result, termination reason, usage. |
| `GET /v1/sandboxes/{id}/events?after={cursor}` | Ordered output + lifecycle events. |
| `POST /v1/sandboxes/{id}/executions/{execId}/cancel` | Idempotent termination request, host-escalated. |
| `PUT /v1/sandboxes/{id}/files?path=…` | Bounded upload into writable workspace. |
| `GET /v1/sandboxes/{id}/files?path=…` | Bounded workspace download. |
| `POST /v1/sandboxes/{id}/reset` | Terminate execution, recreate session from original image. |
| `DELETE /v1/sandboxes/{id}` | Idempotent destroy of VM + writable storage. |

Creation request (proposed defaults, not measured capacities):

```json
{
  "image": "zig-native-v1",
  "limits": {
    "vcpus": 1,
    "memory_mib": 128,
    "workspace_mib": 32,
    "processes": 16,
    "execution_timeout_ms": 60000,
    "session_ttl_seconds": 900,
    "output_bytes": 1048576
  },
  "network": {"mode": "none"}
}
```

Execution request:

```json
{
  "generation": 1,
  "argv": ["/workspace/tool", "--input", "/workspace/input.json"],
  "cwd": "/workspace",
  "env": {"LANG": "C"},
  "stdin_base64": "",
  "timeout_ms": 30000
}
```

Contract rules:

- Create returns `202` + ID. Exec accepted only when session `ready`.
- Args passed directly. Shell syntax only via explicitly supported shell.
- Mutating requests carry idempotency keys; key reuse with different content → conflict.
- Reset increments `generation`; stale exec/file requests fail. Reset completes only after
  old VM + storage destroyed.
- Events: seq no, generation, exec ID, type, payload. Byte-safe bounded output;
  over budget → terminate with `output_limit`.
- Terminal results: `exited` | `cancelled` | `timeout` | `resource_limit` | `guest_failure`.
  Exit codes nullable when no normal exit.
- Path confinement enforced at actual FS operation incl. symlinks. No client host paths.
- Unsupported feature / unenforceable limit → explicit failure. Policy immutable per session.
- Audit: identity, image digest, policy, lifecycle, termination reason. Output = untrusted
  data; creds + file contents not logged by default.

## 7. Implementation sequence

Each milestone ends with acceptance checks + scoped commit.

| # | Deliverable | Acceptance gate |
|---|---|---|
| 1. Contract freeze | OpenAPI schema, lifecycle transitions, error codes, guest protocol, image manifest, ABI definition. | Walkthrough: normal exec, retries, disconnects, cancel, reset races, expiry — no ambiguous outcomes. |
| 2. Protected execution | x86_64 boot path; user/kernel mappings; TSS + privilege transitions; timer preemption; syscall entry; checked user-memory copy. | User program runs, faults safely on kernel-memory access, cannot disable preemption or run privileged ops. |
| 3. Real programs | Validated ELF64 loader, user stack, argv/env, minimal ABI, exit/wait, separate stdout/stderr. | Uploaded static program executes via loader. Malformed ELF + invalid pointers rejected without kernel crash. |
| 4. Host supervisor | QEMU lifecycle, private control channel, host deadlines/quotas, admission control, crash cleanup. | Infinite loops + unresponsive guest killed externally. Partial creation + supervisor restart leave no orphan VM. |
| 5. Isolated workspaces | Immutable base image, bounded writable storage, file transfer, reset, cross-session separation. | Traversal/symlink escapes fail; disk exhaustion contained; reset removes prior files + processes. |
| 6. Public API | Auth, ownership, idempotency, event streaming, bounded retention, cancel, audit. | Full create → upload → exec → stream → download → reset → destroy via public interface. Concurrent sessions + stale requests tested. |
| 7. Qualification | Adversarial integration suite, reproducible image, release archive, checksums, ops guide. | Memory exhaustion, process storms, output floods, malformed control msgs, guest crashes, expiry, cleanup — on Linux/KVM. |

After baseline: host-controlled egress → executable compat (selected agent workloads) →
snapshots/forks. Firecracker = separate backend qualification.

Bash/Python/Node note: either tested Linux-ABI subset in zig-kernel or explicitly ported
userland. Ordinary Linux binaries not assumed compatible (similar syscall names ≠ compat).
If general-purpose agent execution needed urgently: Linux guest behind same API is shorter —
but does not count as zig-kernel compat.
