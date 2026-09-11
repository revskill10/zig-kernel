# zig-kernel Sandbox — Production Isolation Plan (P0–P7)

Status: plan of record for production qualification. `sandbox.md` holds the
contract; this doc holds the delivery plan and the truth matrix.

## 0. Ground truth at start

| Claim | Reality |
|---|---|
| QEMU boots | ELF32/i386 demo kernel, multiboot, serial demo output. Real CPU boundary, no orchestration, no user execution. |
| Hosted tests | 58 kernel + 19 supervisor unit tests. Policy objects only — no process is actually confined. |
| Supervisor | No daemon, no VM spawn/kill/reap, no durable state, no authenticated transport. |
| CI | Hosted tests + QEMU smoke pass; supervisor tests not run in CI; QEMU timeout accepted as success; artifact arch not asserted; OpenAPI not validated. |

Hosted syscall simulation does not intercept arbitrary programs. None of the
current tests establish isolation.

## 1. Threat model (P0)

- **TCB (trusted)**: Linux host kernel + KVM, unprivileged supervisor process,
  privileged launcher (smallest possible step), QEMU process config, immutable
  base image, host cgroup/namespace/MAC configuration.
- **Untrusted**: the VM in its entirety (zig-kernel guest, guest agent, guest
  programs), guest serial protocol messages, uploaded files, program output.
- **Adversary**: hostile static ELF64 program; hostile guest kernel compromise.
- **Assets**: host filesystem/credentials, other sessions, host network
  position, audit integrity.
- **Trust rule**: guest messages never grant host permission or relax limits.
  All enforcement (time, memory, storage, output, network, lifetime) lives
  outside the guest.

## 2. Capability → enforcement matrix (P0)

| Capability | Enforcement point | Currently exists? |
|---|---|---|
| CPU/memory ceiling | host cgroup v2 (`cpu.max`, `memory.max`) per QEMU process | no |
| Execution deadline | host-side watchdog kills QEMU | no |
| Output bound | supervisor caps stream bytes; over → terminate | no |
| Workspace bound | fixed-size per-session image, host-enforced | no |
| Network none | QEMU `-nic none` (no user-mode net at all) | partial (CI uses user-mode net) |
| FS confinement | guest + host `openat2` restriction; no shared host dirs | no |
| Process lifetime | supervisor PID-safe kill + reap + crash reconciliation | no |
| Identity/auth | Unix peer credentials on control socket | no |
| Guest privilege boundary | x86_64 CPL3 + page protection in guest kernel | no (32-bit kernel-only) |
| Audit | durable journal of lifecycle + policy + termination reason | no |

A capability advertised in the API may only ship when its matrix row exists in
code. Otherwise the API must refuse with `unenforceable`.

## 3. Delivery phases

| Phase | Deliverable | Gate |
|---|---|---|
| P0 | This doc frozen; threat model + matrix + status | every advertised capability maps to an enforcement mechanism |
| P1 | Truthful CI baseline | supervisor tests run; QEMU timeout fails; `-nic none` verified; ELF32 arch asserted; OpenAPI validates |
| P2 | Linux supervisor runtime + hardened QEMU launcher | exact argv (no shell), PID-safe kill/reap, per-session UID, closed FDs, cgroup v2, namespaces, seccomp, crash reconciliation |
| P3 | x86_64 long-mode guest execution | real CR3/PTEs, NX/W^X, GDT/TSS, CPL3 transition, timer preemption, syscall entry/return, guarded user-copy |
| P4 | ELF64 loader + guest control service | segments copied/zeroed and executed; malformed ELF/pointers fail without kernel crash; bounded versioned control protocol |
| P5 | Isolated workspace | immutable image + fixed-size per-session storage; no shared host dir; traversal/race tests; reset destroys prior state |
| P6 | Authenticated durable API | Unix peer creds first; persistent idempotency/events/audit; ownership checks; restart-safe lifecycle |
| P7 | Linux/KVM qualification + release | hostile payloads, exhaustion, crash, reset races, cross-session isolation, fuzz, soak on the exact release artifact |

## 4. Hardened QEMU posture (P2+, reference)

```text
qemu-system-x86_64
  -nodefaults -no-user-config -display none
  -nic none                       # until egress is a feature
  -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
  -object memory-backend-memfd,... # no host file mmap of guest RAM
  (run as dedicated UID/GID, empty env, closed stdio, cgroup v2 scope,
   mount/pid/net namespaces, no_new_privs + seccomp allowlist)
```

Host file ops: descriptor-relative (`openat2` with
`RESOLVE_NO_SYMLINKS|RESOLVE_BENEATH`), never string-normalized paths.

## 5. Fail conditions (any one blocks "production")

- Qualification run under TCG, or on a different commit/artifact than release.
- Guest user code touches kernel pages, makes W+X mappings, executes privileged
  instructions, or defeats preemption.
- Guest silence / spin / memory growth / output flood / storage exhaustion not
  stopped from the host.
- Any configured limit stored only in an in-memory policy object.
- QEMU can reach host credentials, unrelated host files, network, or other sessions.
- Reset/restart leaves orphan VM, socket, cgroup, UID, or image.
- API identity taken from the caller instead of authenticated peer creds.
- QEMU timeout accepted as success.
- Release bytes rebuilt after qualification instead of promoting the qualified artifact.

## 6. Branch discipline

Each phase ships as one PR from `origin/main`:
`prod/p1-ci-truth`, `prod/p2-qemu-jail`, `prod/p3-x86_64-ring3`,
`prod/p4-guest-agent`, `prod/p5-workspace`, `prod/p6-api-durability`,
`prod/p7-kvm-qualification`. No direct pushes to `main`. CI gates above apply
to every PR. `prod/*` features stay behind a compile-time feature flag until
P7 passes.
