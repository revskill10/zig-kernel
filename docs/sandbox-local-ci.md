# Sandbox local CI — act inside a Linux guest

**Status:** planned implementation and acceptance. `zig-sandbox` cannot run
act, Docker, or jobs today (`execution: false`, `/readyz` 503, lifecycle 501;
see [sandbox-api-implementation.md](sandbox-api-implementation.md)).

**Date:** 2026-09-14.

**Does not change:** OpenAPI, runtime capabilities, the pinned act tree, or
Dockerfiles in this slice.

Checkpoint interaction: [sandbox-checkpoints.md](sandbox-checkpoints.md) §10.
SmolVM inventory: [audits/smolvm-features.md](../audits/smolvm-features.md).

## 0. User acceptance, in one sentence

Run the pinned **nektos/act** implementation **inside** a sandbox Linux guest,
with Docker daemon, job containers, service containers, action containers,
cache, and artifacts **inside that guest**. Mounting the host Docker socket
is never a qualification path.

## 1. Required topology

```text
outer host
  → qualified sandbox VM provider
    → Linux guest kernel + rootfs
      → guest `act` process
        → guest Docker API (unix:///var/run/docker.sock)
          → guest dockerd / containerd / runc
            → job / service / action containers
```

Containers share the **guest** Linux kernel. That needs kernel namespaces,
cgroups, seccomp, overlay (or an explicitly tested storage driver), and
guest networking. It does **not** need hardware VM nesting (`/dev/kvm` in
the guest) for ordinary act jobs. Nested virtualization is a separate
optional profile.

Guest `/var/run/docker.sock` is a **guest resource** whose server is the
guest-owned daemon. It is not the host socket. A workflow that can talk to
that socket can control the guest daemon; that VM is one trust/resource
boundary and must not be shared across mutually untrusted tenants.

None of these meet acceptance:

- Outer-host `act` using Docker Desktop / host `dockerd`
- `act` in a container bound to the host Docker socket
- Proxied or forwarded host `docker.sock` into the guest
- Building a Docker image of `zig-sandbox` (the diagnostic API image is not
  a booted kernel and not a guest Docker host)

## 2. Two separate milestones

| Milestone | What passes | What it does not pass |
| --- | --- | --- |
| **L1 — Linux VM provider + act** | Pinned act + guest Docker stack runs on a qualified Linux guest (KVM, or another Linux-guest provider) | Native zig-kernel, GitHub-hosted image parity, macOS/Windows runners |
| **N1 — native zig-kernel replacement** | The **same** pinned guest artifacts and fixtures run on a booted zig-kernel with no hidden Linux execution fallback | Anything inferred from L1, hosted syscall tests, or ELF parsers |

Host Windows, macOS, and Linux all use a **Linux guest** for L1. Native
Windows or macOS GitHub-runner jobs are unsupported unless an actual
provider for those guest OSes exists. Mapping `runs-on: windows-*` or
`macos-*` to a Linux container is not those OSes.

## 3. Pins (required before any pass)

Record actual digests at qualification time. This document does not invent
image SHA-256 values.

| Pin | Source identity available now | Gate |
| --- | --- | --- |
| act revision | Inspected `VERSION` = `0.2.89`; `go.mod` module `github.com/nektos/act`, Go 1.25.0. Local HEAD `4f411281417e88660bea1c1a1749aa71ae0bd60f`. Upstream tag [v0.2.89](https://github.com/nektos/act/releases/tag/v0.2.89) (2026-06-01). act README's "Go 1.20+" is stale relative to `go.mod`. | Rebuild from that source; hash the binary |
| Guest kernel + rootfs | Not selected | Linux/amd64 first |
| dockerd / containerd / runc | Not selected | Record versions + storage driver |
| Runner image | act default map is **not** GitHub-hosted parity: `ubuntu-latest` → `node:16-buster-slim` ([cmd/platforms.go](https://github.com/nektos/act/blob/4f411281417e88660bea1c1a1749aa71ae0bd60f/cmd/platforms.go#L7-L13); [IMAGES.md](https://github.com/nektos/act/blob/4f411281417e88660bea1c1a1749aa71ae0bd60f/IMAGES.md)) | Explicit `-P` to a digest; never the interactive default prompt |
| JS action runtime | Source handles node12/16/20/24 **types** ([pkg/runner/action.go](https://github.com/nektos/act/blob/4f411281417e88660bea1c1a1749aa71ae0bd60f/pkg/runner/action.go)) | Image must actually contain the Node binary |
| Service / Docker-action bases | Workflow-defined | name@sha256 only |
| Cache/artifact servers | act process HTTP servers ([cmd/root.go](https://github.com/nektos/act/blob/4f411281417e88660bea1c1a1749aa71ae0bd60f/cmd/root.go#L117-L127)) | Bind guest-only; tenant-scoped paths |

A mutable `ubuntu-latest` label is a map to that digest. It is not a
GitHub-hosted VM clone and does not include the GitHub toolcache.

## 4. Source project into the guest

Default: copy the approved project into a **private writable guest
workspace** via the existing planned Fs/import contract (or an explicit
mount that is guest-private). Do not `--bind` the outer host directory for
the first gate.

`--bind` in act bind-mounts the working directory into the job container
([cmd/root.go](https://github.com/nektos/act/blob/4f411281417e88660bea1c1a1749aa71ae0bd60f/cmd/root.go#L84)).
If ever enabled, the path must be a **guest** path, with host RW exports
under existing mount policy only. Docker build contexts must not escape the
approved checkout; filter symlinks, ignored secrets, and Git credentials.
Do not inherit host `~/.docker/config.json`, `~/.ssh`, cloud tokens, or
host `DOCKER_HOST`.

## 5. Planned versus source-supported act flags

Flags below exist in act source
([cmd/root.go](https://github.com/nektos/act/blob/4f411281417e88660bea1c1a1749aa71ae0bd60f/cmd/root.go#L68-L133)).
They are **source-supported**, not zig-kernel-qualified. Do not invent
flags. Commands are **planned** until L1.

### 5.1 First smoke invocation (planned)

After pins exist and `RUNNER_IMAGE` is a recorded `name@sha256`:

```sh
# planned guest-local invocation — not implemented by zig-sandbox
DOCKER_HOST=unix:///var/run/docker.sock act push \
  -C /workspace/repo \
  -W /workspace/repo/.github/workflows/smoke.yml \
  -e /workspace/repo/event.json \
  -P "zk-act-linux-amd64=$RUNNER_IMAGE" \
  --container-architecture linux/amd64 \
  --container-daemon-socket - \
  --network none \
  --pull=false --rebuild=false --action-offline-mode \
  --no-cache-server --concurrent-jobs 1 --rm --json \
  --env-file /run/act-input/empty \
  --secret-file /run/act-input/empty \
  --var-file /run/act-input/empty \
  --input-file /run/act-input/empty \
  --action-cache-path /var/lib/sandbox-act/actions
```

Why those source flags (not new flags):

| Flag | Source default | Planned smoke choice | Reason |
| --- | --- | --- | --- |
| `--container-daemon-socket` | empty → job bind of `/var/run/docker.sock` | `-` | Disable **job** socket bind for smoke; act still uses `DOCKER_HOST`. `-` is source-supported. |
| `--network` | `host` | `none` for smoke | Source default `host` would mean the **guest** network namespace, not the outer host — still too wide for smoke. Service fixtures use act's bridge, not this default. |
| `--pull` / `--rebuild` | `true` | `false` | Offline; preloaded images. `--action-offline-mode` is not a firewall. |
| `--rm` | `false` | `true` | Cleanup on failure (source: `--rm` removes containers/volumes after **failure**) |
| `--reuse` | `false` | leave default | Do not keep job containers |
| `--bind` | `false` | leave default | Copy, don't bind, for first gate |
| `--privileged` | `false` | leave default | Do not grant privileged jobs unless a named profile |
| `--insecure-secrets` | `false` | never enable | Source-supported and forbidden here |
| `--concurrent-jobs` | 0 → CPU count | `1` for smoke | Bound to sandbox quota |
| `--container-architecture` | empty → daemon default | `linux/amd64` | Does not install emulation |
| `--json` | `false` | `true` | Machine-readable logs |

Force `DOCKER_HOST=unix:///var/run/docker.sock` inside the guest. Reject
inherited `tcp://`, `ssh://`, `npipe://`, and any outer-host endpoint
([pkg/container/docker_run.go](https://github.com/nektos/act/blob/4f411281417e88660bea1c1a1749aa71ae0bd60f/pkg/container/docker_run.go)
honors `DOCKER_HOST`, including remote helpers).

Isolate `HOME` / XDG / `.actrc` so copied host config cannot override
daemon, platform, or secrets. Record effective argv without secret values.

`--action-offline-mode` is not an egress firewall. Outer provider policy
denies egress for the smoke fixture. `--pull=false` plus preloaded image
identity must be checked.

Later fixtures may set `--container-daemon-socket` to the **guest** Unix
socket when the job itself must call Docker. That grants **guest-daemon**
control, not host access.

### 5.2 Source flags that remain unsupported or separately gated

| Flag / behavior | Plan |
| --- | --- |
| `--watch` | Out of first scope |
| `--privileged`, `--userns`, `--container-cap-add/drop` | Named profile only; outer VM is still the TCB |
| `--network host` | Only after proving it means guest-host netns and provider firewall still applies |
| Job `timeout-minutes` | Parsed/logged in source; **no observed enforcement**. Outer sandbox deadline always applies. Step `timeout-minutes` does install a context timeout. |
| Workflow concurrency groups, environment approvals, GITHUB_TOKEN scopes, OIDC | Not found as execution features; treat unsupported or externally provided |
| GitHub-hosted scheduling, webhooks, check runs | Out of scope |
| `--artifact-server-*` / `--cache-server-*` | Guest-local bind only; not GitHub storage parity |

## 6. Fixture sequence (keep failed gates visible)

Each fixture is a separate gate. Skipping is `unavailable`, not pass.

### 6.1 Smoke (first L1 slice)

No remote action, checkout download, service, or secret.

```yaml
name: sandbox-act-smoke
on: push
jobs:
  smoke:
    runs-on: zk-act-linux-amd64
    steps:
      - name: Container execution and output
        id: probe
        shell: bash
        run: |
          set -euo pipefail
          test "$ACT" = true
          test -f /.dockerenv
          test ! -S /var/run/docker.sock
          printf 'sandbox-act-ok\n' > proof.txt
          sha256sum proof.txt
          printf 'token=sandbox-act-ok\n' >> "$GITHUB_OUTPUT"
          uname -srm
      - name: Step output propagation
        shell: bash
        env:
          PROBE_TOKEN: ${{ steps.probe.outputs.token }}
        run: test "$PROBE_TOKEN" = sandbox-act-ok
```

Twin: a step `exit 7` must be nonzero at the act/job result; no leftover
owned containers/networks/volumes.

First smoke proves **logged** checksum (`sha256sum proof.txt`) and step
output only. `proof.txt` lives in the transient copy-in job workspace
(`--bind` left default/false, `--rm` on). It is not automatically in the
guest source checkout and is **not** retrieved by the files API in this
fixture.

### 6.2 Checkout JS step, then matrix / env / output / workspace

1. Local `actions/checkout`-shaped JS action **or** act's copy-in path, then
   a local `using: node20` (then `node24`) action with inputs,
   `GITHUB_OUTPUT` / `GITHUB_ENV` / `GITHUB_PATH`, masking, pre/main/post.
   Pin Node in the runner image; source action-type support does not supply
   the binary. Remote actions only in a later allowlisted-fetch gate, full
   commit SHA (short SHA rejection exists in act).
2. Jobs/needs/matrix: two independent jobs; 2×2 include/exclude with
   `max-parallel: 2`; job outputs into a needs-dependent job;
   failure/skip/always. Declared sandbox budget wins over workflow
   parallelism. Behavioral shape may follow act testdata (`matrix`,
   `evalmatrixneeds`); those files are references, not passed gates.

### 6.3 Workspace, artifacts, cache

Guest-local artifact and cache servers. First run miss, second same-tenant
hit, changed key miss.

Because first smoke is copy-in with `--rm`, job-workspace files (including
`proof.txt`) disappear with the container. This gate must **explicitly
upload or copy** artifact bytes to a **guest-owned export directory**
before job cleanup (source-supported `--artifact-server-*` bound
guest-local, or an equivalent copy into that guest path — no invented
flags). Then verify downloaded bytes/hash against that export. A later
host export, if any, copies from the same guest-owned path. The planned
files API retrieves that exported path, not the transient job workspace.

Corruption, oversize, retention, tenant separation, server cleanup.
No GitHub hosted storage protocol/quota/security parity. Do not weaken
`--rm` cleanup, change first-smoke topology/network, or substitute an
outer-host mount.

### 6.4 Docker action

Local pinned-base `Dockerfile` + `action.yml` built and run via **guest**
dockerd. Then `docker://name@digest`. If a step must invoke Docker CLI,
explicitly allow the guest socket bind in that profile.

### 6.5 Service health and network

Pinned service image (Postgres or equivalent) on the act-created **guest
bridge**; health check; service-name DNS; write/read; dependent job.
No host port exposure initially. Later: guest-published ports only through
the sandbox forwarding contract.

Act source: service jobs get an act-created bridge; other jobs use
`--network` (default `host`). "Host" must mean the Linux guest.

### 6.6 Failures, cancel, timeout, restart, cleanup

- Step timeout (source-enforced) and outer sandbox deadline (always).
- SIGINT graceful cancel, then SIGTERM/force; post hooks may run; `--rm`
  required for failure cleanup. Outer watchdog still owns VM teardown.
- Kill `act` and guest `dockerd` separately; supervisor restart reconciles
  by durable operation/run IDs; no orphan success.
- Full disk / OOM / CPU / PID deadlines.

### 6.7 Concurrency and quotas

`--concurrent-jobs` and workflow `max-parallel` are not GitHub
concurrency-group semantics. Bound both to sandbox CPU/memory/process
ceilings; the ceiling wins.

### 6.8 Secrets, network, credentials

Resolve secrets in the sandbox broker; stage only inside the guest with
restrictive permissions; mask logs; erase on teardown. Never
`--insecure-secrets`. Host `.env` / `.secrets` / `.actrc` defaults
overridden. Masking is not protection against a malicious workflow
exfiltrating a granted secret.

Offline smoke: no egress. Online workflows declare registry/DNS/proxy
allowlists; guest dockerd pulls are in scope of outer enforcement. Act
`--network` is Docker networking, not the provider firewall.

### 6.9 User-goal Python / threads / async / C compile **inside act**

After smoke, the same guest act run must execute **workflow steps** that
cover the user's ordinary-computer goals. Host Docker or a locally built
Python OCI image is not this gate.

| Goal | Planned act fixture (new under `tests/act-sandbox/fixtures/`, not present in this slice) |
| --- | --- |
| Threads | Job step: Python starts two threads, each increments a counter under a lock; assert final count |
| Async | Job step: `asyncio` gathers two tasks and asserts both complete |
| C compile | Job step: `cc` (or the pinned image compiler) builds a small C program that prints a known checksum; run it |

Copy exact scripts into that fixture tree when ACT0 lands. Do not treat a
host-kernel Python toolchain image, or `docker build` of this repository's
API image, as L1. Native zig-kernel remains N1.

Default: do not bake secrets into checkpoints of this job.

## 7. Exact inside-guest proof

A passing log line is insufficient. The outer qualifier binds:

| Proof | How |
| --- | --- |
| Guest kernel | `uname -srm` **and** provider boot identity / image digest |
| Guest proc | `/proc/1` or dockerd PID namespace is the guest, not the outer host PID |
| Guest cgroup | dockerd/job cgroup path under the guest; not the outer host's Docker cgroup |
| Daemon identity | guest dockerd PID, executable path, `docker info` cgroup/storage/OS, Unix socket inode |
| Job container | `docker inspect` ID/image digest inside guest; `/.dockerenv` in the job is necessary but not sufficient |
| Not on outer host | Outer host has no workflow job container and no job dockerd created for this run |
| Failed gates | Qualifier prints `unavailable` / `failed` with the gate id; never green-wash |

`uname` or `/.dockerenv` alone cannot establish VM locality.

## 8. Proposed API / CLI / SDK (not implemented)

Reuse planned sandbox operations; do not add a parallel CI control plane
in this slice.

| Surface | Planned use |
| --- | --- |
| `POST /v1/sandboxes` | Create from the pinned act-guest image/profile |
| `POST /v1/sandboxes/{id}/executions` | Start guest `act` with the recorded argv |
| `GET /v1/sandboxes/{id}/events` | Logs (JSON lines from `--json`) |
| `GET /v1/sandboxes/{id}/files` | Retrieve guest-owned **exported** artifacts, qualifier reports, and `proof.txt` only after the §6.3 export fixture has copied them out of the job workspace before cleanup |
| `POST /v1/sandboxes/{id}/executions/{exec}/cancel` | Cancel; outer deadline still applies |
| `GET /v1/operations/{id}` | Durable run id for restart reconcile |
| TypeScript SDK | Same routes; no host-process fallback |
| Wasm SDK | Delegate; no Docker-in-browser |

Planned CLI (label **planned** until L1):

```text
# planned
zig-sandbox ci run --sandbox sbx_... --workflow smoke.yml --event event.json
zig-sandbox ci logs --operation op_...
zig-sandbox ci artifacts --operation op_... --out ./out
# artifacts CLI reads the §6.3 guest-owned export path, not the job workspace
```

Building `docker build -t zig-sandbox-bootstrap:local .` remains the
**diagnostic listener** image in [README.md](../README.md). It is not this
CI guest.

## 9. Native Linux ABI gap (tied to act/Docker, not "a few syscalls")

Do not claim a short syscall list is Linux parity. L1 uses a real Linux
guest kernel. N1 (zig-kernel) must eventually provide the combined
environment that the **pinned** act + dockerd + containerd + runc + runner
+ job binaries actually use. Derive the final set from those versions and
traces.

Subsystem classes required for this stack (not exhaustive, not a pass
checklist):

| Class | Why act/Docker need it |
| --- | --- |
| Process/thread | Go act, dockerd, runc, Node, compilers, `clone`/`fork`/`exec`/`wait`, TLS |
| Signals / process groups | Cancel, timeout, job cleanup, SIGINT/SIGTERM path in act |
| Memory | mmap/mprotect, shared memory, futex, robust lists |
| Files / fd | limits, locks, sparse files, rename/link/fsync, inotify for some tools |
| ELF / libc | Dynamic loader; glibc or musl as selected by the pinned images |
| Time | monotonic clocks; timerfd |
| Event I/O | epoll, eventfd, signalfd, Unix sockets |
| Namespaces | mount, pid, uts, ipc, net; selected user + cgroup ns |
| cgroup v2 | daemon + job resource control; qualifier identity |
| Mount / overlayfs | Docker overlay2 (or a separately tested vfs driver, not reported as overlay2) |
| proc / sys / dev / devpts | inspect, cgroup, PTY |
| seccomp | runc default + workflow caps |
| Net: bridge, veth, netlink | act service network; docker0 |
| nftables/iptables + conntrack | Docker NAT/firewall as used by the pinned daemon |
| ioctl | block, tun/tap, namespace, tty, as traced |
| Random / xattr / ownership | image unpack, rootful dockerd first profile |

Rootful guest dockerd is the first profile. Rootless needs extra
userns/cgroup/network evidence.

Native zig-kernel currently lacks that combined environment. Incremental
ELF parsing or hosted syscall names do not enable Go/Docker/Node. Native
roadmap: static userspace → process/thread/signal ABI → dynamic
libc/toolchain → writable FS/net → namespaces/cgroups/seccomp → container
daemon → **exact L1 fixtures**. Never relabel L1 success as N1.

## 10. Checkpoint of a CI guest

See [sandbox-checkpoints.md](sandbox-checkpoints.md) §10.

Capture of guest Docker/job/process/data is allowed only for a **qualified
resource profile** and a consistent generation. Idle warm image (guest +
idle dockerd + preloaded images, no secrets) is the first profile.

External services and credential lifetimes need explicit
reconnect/rebind/quiesce. Resume of an in-flight job is not the same as
starting a new job on a restored warm image. Two restored copies must not
both complete the same CI operation.

Default: no secret baking into checkpoints.

## 11. Delivery order

| Gate | Deliverable | Pass evidence |
| --- | --- | --- |
| ACT0 | Pin act source/binary, guest image manifest, runner/action/service digests, offline fixtures | Image **build** on ordinary Linux is preparation only |
| ACT1 / L1 | Real provider VM; §7 identity; smoke + failure twin | Guest uname/proc/cgroup/daemon/job proof; no host socket |
| ACT1+ | §6.2–6.9 including Python/threads/async/C **as act jobs** | Each fixture separately; failed remain visible |
| CP2-act | Idle warm checkpoint of that guest | [sandbox-checkpoints.md](sandbox-checkpoints.md) §10 |
| ACT2 / N1 | zig-kernel runs the same artifacts | No Linux fallback |

Missing external qualification (provider VM, image digests, installed
libkrun/KVM, native ABI) remains a documented open gate. This plan does
not implement those features.
