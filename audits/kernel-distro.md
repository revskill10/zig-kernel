# Native Zig Kernel, Vinix Parity, and Distro Plan

**Status:** evidence-backed implementation and qualification plan. This is not
a claim that zig-kernel is a production kernel, a Linux-compatible kernel, a
Vinix-compatible kernel, or an Omarchy-equivalent distribution.

**Publication rebaseline:** 2026-09-14 against selected accepted tree
`6c8c8ca0611005e7776f437f381c55a866a67e3c`.

**Current product (this checkout):** hosted Zig simulation; i386 QEMU demo;
bounded native x86_64 UEFI bootstrap (PE32+ loader, ELF64 payload, FAT16 ESP,
108-byte `INITRMF1` smoke envelope — **not** CPL3, Linux ABI, Alpine, desktop,
or Photon); hosted/native-compile user-VM page-table constructor with **no**
CR3 switch; diagnostic sandbox API (`execution:false`, `/readyz` 503,
lifecycle 501); pinned SQLite amalgamation wrapper not wired into Store.
Linux replacement, Alpine, GUI/Photon, full control Store, providers, auth,
and SDK/Wasm are **not** qualified. Public native record:
[native-bootstrap.md](../docs/native-bootstrap.md).

**Audit date:** 2026-09-13 (original); rebaseline 2026-09-14.

**Scope:** native Zig-kernel completion; bounded Vinix source/UAPI comparison;
bounded Linux ABI and distribution compatibility; boot, root filesystem, init,
packages, installer, updates, recovery, desktop, and workload qualification.

**Non-substitutions**

* A Linux guest used by the sandbox plan is not evidence that the native Zig
  kernel can boot or run that workload.
* A hosted Zig executable is not a kernel, an interrupt/DMA implementation, or
  a userspace ABI.
* Matching a syscall name or a table slot is not Linux, libc, ioctl, or binary
  compatibility.
* A practical Linux-kernel-backed distro does not retire native Zig-kernel
  milestones.
* The checked-in waku-os tree is a separate Buildroot external tree, not an
  Omarchy implementation. It may inform reproducible ISO/QEMU/SBOM methods,
  not desktop or kernel parity.

Statements marked **Proposed** are defaults requiring implementation and
qualification. They are not observed facts.

## 1. Assessment

The repository contains useful Zig modules and hosted tests, an i386
bare-metal QEMU demo, and a bounded native x86_64 UEFI bootstrap smoke.
Current evidence does not establish a native x86_64 kernel with protected
userspace (CPL3), SMP, persistent storage, real device DMA and interrupt
handling, POSIX/Linux binary compatibility, or a bootable distro.

Two distinct tracks must remain separate:

1. **Track L, Linux reference/accelerator:** a pinned Linux-kernel-backed
   image and userspace profile. It enables early user-workflow and reference
   validation, but cannot complete the native goal.
2. **Track Z, native kernel:** a Zig x86_64 kernel delivered through
   independently gated boot, hardware, UAPI, userspace, and workload stages.

Track L is an optional accelerator/reference and may host the sandbox plan's
qualified Linux workload profile. Track Z is mandatory for the native goal and
may host that workload only after independently passing it. Neither track
inherits the other's result.

## 2. Evidence and limits

| ID | Evidence | Established | Not established |
| --- | --- | --- | --- |
| K1 | [README](../README.md), [build.zig](../build.zig), [hosted main](../src/main.zig) | Default `zig build` / `zig build test` path is hosted simulation. | Privilege, faults, DMA, arbitrary-program interception, or native isolation. |
| K2 | [src/baremetal.zig](../src/baremetal.zig), [linker.ld](../linker.ld); historical 2026-09-13 i386 KVM smoke (logs not in this checkout) | Historical QEMU 8.2.2/KVM i386 demo: 45,496-byte ELF32, SHA-256 `a2fc881b6a36b83b299cf3dd3ae614e26b349205c20648f12faf36bc722e9d0b`, debug-exit 3. That is **historical i386** evidence only. | x86_64 long mode as a userspace kernel, CPL3, real userspace, storage, networking, or distro boot. |
| K2b | [native-bootstrap.md](../docs/native-bootstrap.md), [src/native/main.zig](../src/native/main.zig), [boot/uefi/main.zig](../boot/uefi/main.zig), `zig build native-image` / `test-native` | Bounded native x86_64 UEFI slice: PE32+ loader, ELF64 payload at 2 MiB, 64 MiB FAT16 ESP, 108-byte `INITRMF1` smoke. Public qualifier TCG smoke and hosted native contracts as recorded in that document. `linux_replacement_qualified` is false. | CPL3, Linux ABI, Alpine rootfs, desktop, Photon, production isolation. Native CR3 probe is a separate publication and is **not** in this checkout. |
| K3 | Historical 2026-09-13 kernel-distro tests.log (not in this checkout); current published counts in [sandbox-api-implementation.md](../docs/sandbox-api-implementation.md) and [native-bootstrap.md](../docs/native-bootstrap.md) | **Historical snapshot:** 9/9 steps, 85/88 tests, three Linux skips (kernel 58, supervisor 25/28, bootstrap 2). **Current published:** 75/75 `test-sandbox`; 78/78 `test-native`; 54/54 qualifier host fixtures; 58/58 hosted kernel; 26/26 `test-supervisor`. | Native-kernel userspace qualification. Hosted/component tests are not QEMU userspace. |
| K4 | [syscall model](../src/syscall.zig), [entry model](../src/arch/x86_64/entry.zig), [uaccess](../src/uaccess.zig) | Entry capacity is 450 (`SYSCALL_MAX`); current static source registers 57 handlers with custom Vinix-style numbers and four arguments; hosted models exist. | Linux amd64 syscall ABI, Vinix ABI, stable process entry, or fault-contained copyin/copyout. |
| K5 | [VFS](../src/vfs/vfs.zig), [ext4 code](../src/fs/ext4.zig), [virtio block](../src/drivers/block/virtio_blk.zig) | Ramfs and storage-shaped source exist. The ext4 code uses a custom fixed inode/directory layout and virtio block is a static 64-sector RAM image. | Real ext4 parsing, writable durable media, cache/writeback, or recovery. |
| K6 | [scheduler](../src/sched/sched.zig), [MM](../src/mm/mm.zig), [GDT](../src/arch/x86_64/gdt.zig) | Model components exist. Native GDT/IDT/PMM hosted fixtures exist under `src/arch/x86_64/native/`. | AP bring-up, TLB/IPI protocol, real scheduling, or SMP correctness. |
| K7 | [net core](../src/net/net_core.zig), [TCP model](../src/net/tcp.zig), [e1000](../src/drivers/net/e1000.zig), [virtio net](../src/drivers/net/virtio_net.zig) | Hosted loopback-oriented network models exist; TCP is not imported by the main root, so the ordinary kernel suite does not establish TCP test coverage. | Real DMA/IRQ/wire networking, TCP interoperability, or network security. |
| K8 | [sandbox plan](sandbox.md#2-contract-evidence-and-limits) | Sandbox planning has a distinct Linux guest baseline and native experimental profile. | Any native kernel userspace or sandbox-guest progress. |
| K9 | [comparison](../docs/comparison-vinix-omarchy.md), [parity report](../docs/parity-report.md), [QEMU status](../docs/qemu-verification-status.md) | Existing documents record analogies and hosted/demo evidence. Those files still contain broad “parity” wording that is **not** current-tree evidence. | Broad parity, complete, functional, production, or QEMU claims in those documents. |
| K10 | Historical local inspection of waku-os README and Omarchy `version` (workspace siblings; not in this checkout) | Waku-os is a Buildroot external tree; local Omarchy checkout then reported 4.0.0.alpha and is Arch-based. | An upstream-current Omarchy state, Omarchy desktop parity, or a production distro. |

### 2.1 Prioritized findings

| ID | Priority | Condition | Required closure |
| --- | --- | --- | --- |
| KD1 | P0 | Default target and many subsystems are explicitly hosted simulation. | Track Z gates Z1-Z8. |
| KD2 | P0 | Historical QEMU evidence is an i386 demo. This tree adds a bounded native x86_64 UEFI **bootstrap smoke**, still without CPL3. | Z1 remainder (systemd-boot/initramfs userspace) through Z3 x86_64 CPL3 evidence. |
| KD3 | P0 | Existing docs use broad parity and production wording. | Staleness review; replace each claim with exact artifact, command, environment, and limit. |
| KD4 | P0 | A 66-entry table/model is described as Vinix parity. | V1-V5 generated ABI and differential gates. |
| KD5 | P0 | Storage, VFS, drivers, network, and security are model paths. | Z4-Z7 real implementation and fault gates. |
| KD6 | P0 | Waku-os or Omarchy references are treated as a distro comparison target. | L1-L8 bounded Linux distribution profile; do not call waku-os Omarchy parity. |
| KD7 | P1 | Sandbox Linux guest work could be mistaken for native progress. | Cross-track rules in Section 4. |
| KD8 | P1 | Page cache, block, and filesystem code use small synchronous/static or custom models. | Z4 fault, durability, and interoperability corpus before claiming filesystem/block support. |

Following review, audit stale affirmative claims in the comparison, parity,
QEMU-status, architecture, and Omarchy comparison documents. Do not add a
generic disclaimer beneath unsupported checkmarks; replace each with an
evidence-scoped statement.

### 2.2 Grounded source hazards

| Source evidence | Consequence | Required closure |
| --- | --- | --- |
| [page cache](../src/mm/page_cache.zig) read path can evict a dirty victim without writeback and can overwrite valid cached bytes after a partial reader failure. | It is not safe durability or read-consistency behavior. | Z4 implements dirty-victim policy, writeback ordering, partial-I/O preservation, and injected-fault tests. |
| [block queue](../src/drivers/block/blk_queue.zig) is a static 16-request synchronous model. | It is not a concurrent device queue or completion/error model. | Z4 adds bounded asynchronous ownership, cancellation, reset, timeout, flush, and recovery. |
| [ext4 code](../src/fs/ext4.zig) is a custom synthetic fixed-layout parser. | It must not be called an ext4 parser or used for arbitrary ext4 media. | Z4 selects a filesystem/profile and tests malformed/corrupt media. |
| Entry capacity is 450 but static source registers 57 custom-number/four-argument handlers; historical local Vinix was pre-alpha and uses ELF/interpreter plus mlibc. | Capacity/source resemblance is not Vinix or Linux amd64 binary ABI. | V1-V5 and LNX0-LNX3 compare generated ABI/layout/loader semantics. |
| Historical 2026-09-13 qemu-bin record matched i386 smoke SHA `a2fc881b…` (logs not in this checkout). | It renews confidence in that **historical i386** demo artifact, not in x86_64 userspace. | Z1 userspace/initramfs still requires a current x86_64 exact-artifact serial boot of a real root; the published UEFI smoke is K2b, not CPL3. |

## 3. Reference build manifest and compatibility vocabulary

### 3.1 Reference Build Manifest

**Proposed:** each qualification candidate has an RBM containing:

| Input | Pin and evidence |
| --- | --- |
| Zig | Version, source/download digest, target triple, options, and cache policy. |
| Zig native image | Kernel, boot assets, initramfs/rootfs, config, driver/ABI features, and artifact digests. |
| Vinix | Commit/tag digest, architecture, build configuration, UAPI inventory, and selected corpus. |
| Linux | Source tag/commit, config, toolchain, bootloader, firmware, modules, and image digest. |
| Distro profile | Package snapshot/keyring, rootfs, installer media, desktop configuration, update channel, and SBOM. |
| Emulator/hardware | QEMU/KVM version/options or board/firmware/microcode plus serial capture. |
| Workloads | Input/source digest, expected behavior, limits, output, and trace digest. |

An RBM pins a bounded comparison. Claims such as all Linux, all Vinix, all
Omarchy, all hardware, or all applications are not acceptance targets.

### 3.2 Local source inventory at audit start

These identities are **historical local inspection** from the 2026-09-13 audit.
They are not files in this checkout and are not installed dependencies.

| Reference | Historical local path | Observed revision metadata | Boundary |
| --- | --- | --- | --- |
| zig-kernel (audit-start tree) | then-repository root | 06bec31c2e38ab9c9de326656631ff5c75ef1c7b | Revision metadata is not a content hash; this publication tree is `6c8c8ca0611005e7776f437f381c55a866a67e3c`. Future RBM uses source-archive SHA-256 plus selected-source manifest. |
| Linux | `linux` (workspace sibling) | 28924df2a08f440c73991b83028032c901de2ae4; local Makefile identified 7.3.0-rc2 | Local self-identification is not upstream authenticity, completeness, build, or test proof. |
| Vinix | `vinix` (workspace sibling) | e4b95129e6ac12d1ec84f060c5becd6e390db85a | Local README called Vinix pre-alpha; source is comparator, not a production compatibility spec. |
| Omarchy | `omarchy` (workspace sibling) | 590d7d1cf6b61bdada16ca6e6e9d1bf7d1d18da2; version 4.0.0.alpha | A local Arch-based checkout is not an upstream-current or equivalent release claim. |
| Torkbot Sandbox | `torkbot-sandbox` (workspace sibling) | 641cbc5fb63fbdb0930dcf1583bbdf7d3ecfbb12 | Cross-platform application API reference only; it does not prove native kernel ABI or isolation. |

A historical local `kernel-distro-audit/reference-manifest.json` (not in this
checkout) recorded SHA-256 values for 52 selected local reference files. That
receipt made the original audit's source selection reviewable; it is not
complete source-archive provenance and is not published product evidence. A
future RBM carries full archive digests, dependency closure, and build output.

### 3.3 Compatibility vocabulary

| Term | Required evidence |
| --- | --- |
| Source analogy | Named design/source relationship only. |
| UAPI compatibility | Exact constants, layouts, alignment, calling convention, errors, and semantics pass tests. |
| Linux source compatibility | Declared source package compiles against the stated headers/libraries and tests pass. |
| Linux binary compatibility | Declared ELF programs, interpreters, and libraries run under the stated ABI. |
| Vinix parity | Selected pinned Vinix interfaces/workloads pass side-by-side comparison. |
| Distro profile parity | Selected pinned user workflows pass on the exact image. |
| Production readiness | All applicable hard gates pass on exact RBM bytes. |

### 3.4 Swappable seam rules

| Seam | Stable contract | Rule |
| --- | --- | --- |
| Kernel VFS | Handles, namespace, I/O, metadata, locking, rename, durability, error semantics | A filesystem adapter is interchangeable only after the common conformance/fault suite. |
| Block layer | Request ownership, ordering, flush, timeout, reset, completion, capacity | A static RAM model cannot stand in for a durable device implementation. |
| Network | Packet ownership, address/route/socket semantics, backpressure, error, observability | A loopback model cannot stand in for a NIC or wire protocol. |
| Platform | Boot memory map, interrupt/timer, SMP, clock, entropy, power/reset | Architecture backends require per-build validation; privileged internals are not runtime hot swaps. |
| Credentials/security | Identity, credentials, permissions, capabilities, audit, key material | Policy adapters cannot weaken kernel/user or device boundaries. |
| Sandbox API/storage | Typed image/ABI/capability/agent records and durable control state | SQLite control state is not a hardware, kernel VFS, block, or isolation substitute. |

### 3.5 Local reference source map

Paths below are **historical local inspection** relative to workspace siblings
that are not in this checkout. Public Linux documentation used as method
references is linked separately in §11.1.

| Reference | Historical local source used by this plan | Planning use only |
| --- | --- | --- |
| Linux entry/UAPI | `linux/arch/x86/entry/syscalls/syscall_64.tbl`, `entry_64.S`, `include/uapi/linux/kvm.h`, `include/uapi/drm/drm.h`, `include/uapi/linux/input.h` | Baseline ABI dimensions: Linux syscall register entry, KVM API, DRM/KMS, and input events. |
| Linux execution/storage | `linux/fs/binfmt_elf.c`, `linux/fs/exec.c`, `linux/kernel/fork.c`, `linux/fs/ioctl.c`, `linux/fs/ext4/super.c` | Comparator for loader/process/ioctl/filesystem work; not source to copy blindly. |
| Linux testing/docs | `linux/Documentation/dev-tools/kselftest.rst`, `linux/tools/testing/selftests/Makefile`, procfs/sysfs/ABI docs under `linux/Documentation/` | Select testable interfaces and a pinned selftest subset. Public method docs: [kselftest](https://docs.kernel.org/dev-tools/kselftest.html). |
| Vinix architecture | `vinix/kernel/main_amd64.v`, `main_arm64.v`, `vinix/kernel/modules/elf/elf.v` | Comparator for boot/architecture and ELF scope. |
| Vinix UAPI/process | `vinix/kernel/modules/syscall/table/syscall_table.v`, `linux_table_amd64.v`, `vinix/kernel/modules/sched/sched.v` | Inventory inputs; source-level comparison is not compatibility proof. |
| Vinix filesystem/network | `vinix/kernel/modules/fs/vfs.v`, `procfs.v`, `sysfs.v` | Selected VFS/proc/sys semantics for V1-V5 inventory. |
| Omarchy profile | `omarchy/version`, `omarchy/install/omarchy-base.packages`, `omarchy/install/post-install/pacman.sh`, `omarchy/default/wayland-sessions/omarchy.desktop`, `omarchy/themes/lumon/hyprland.lua` | Local content inputs for profile inventory, never a blanket parity claim. |
| Omarchy lifecycle | `omarchy/install/login/sddm.sh`, `omarchy/install/post-install/all.sh`, `omarchy/install/provisioning/omarchy-system-factory-reset-finish.service`, `omarchy/manual/50-dual-boot-install.md`, `omarchy/manual/51-unattended-installs.md` | Installer/login/recovery workflow inventory. |

The local Linux source includes substantial implementation, but this is neither
a proof of a complete reference build nor permission to copy it. Linux source
and tests have their own licenses; UAPI headers can have distinct syscall-note
or other exceptions. Record provenance and license review per selected input;
do not treat an interface comparison as authorization to copy implementation or
test code.

## 4. Track separation and sandbox service contract

| Consumer | Track L, Linux-backed profile | Track Z, native Zig kernel |
| --- | --- | --- |
| Sandbox normal-computer profile | May be the qualified Linux VM baseline described in [sandbox audit](sandbox.md#9-guest-workspace-images-egress-secrets). | Experimental until equivalent guest and kernel evidence passes. |
| VM, CLI, SDK service | Receives typed image digest, ABI/profile, capability set, and guest-agent protocol. | Same contract only after native qualification. |
| Host exports and tools | Host enforcement remains in the sandbox broker. | No ambient host authority; guest must pass the same protocol/export contract. |
| Corpus reuse | Inputs/expected observables may be shared. | A Linux pass never closes a native gate. |

Native self-hosting requires a separate host profile. The native kernel must
first qualify its own VM-host path: KVM or an explicitly selected hypervisor,
namespace/cgroup/seccomp-equivalent containment where supported, device
delegation, VM lifecycle, guest-agent transport, and recovery. A native guest
running a workload does not establish that it can safely host sandbox tenants.
That future host profile shares service contracts with sandbox.md but has its
own threat model, isolation tests, and promotion gate.

### 4.1 Cross-platform Torkbot Sandbox API reference

Historical local inspection of `torkbot-sandbox/README.md` (workspace sibling,
revision `641cbc5f…`, not in this checkout) showed a TypeScript-facing
contract for rootfs, host-controlled workspace/state, network policy, mounts,
boot, and exec. Treat it as an application/service API reference to inventory:
lifecycle, image/rootfs, storage, files/mounts, network and secret policy,
streams, errors, capability discovery, and cross-platform client semantics.
See [sandbox-api.md](sandbox-api.md) for the planned remote mapping.

**Proposed integration rule:** define an adapter from the qualified sandbox
server API in [sandbox-api.md](sandbox-api.md) and sandbox.md to the selected
Torkbot surface only after a route/type/error/timeout/cancellation matrix is
generated and tested. Portable SDK/HTTP access is distinct from required
qualified local providers on Linux, macOS, and Windows: each advertises an
actual VM backend such as KVM, Hypervisor.framework, WHPX, or WSL2 and fails
closed when unavailable. A Windows host may run a Linux VM guest; it does not
thereby run native Windows binaries or establish Linux ABI/native Zig-kernel
parity. The adapter maps errors through the planned common envelope carrying a
stable code, request ID, retryability, and bounded detail, with the same
vectors as sandbox-api.md. It uses capability discovery and never swaps an
unavailable remote/local provider for arbitrary host execution.

## 5. Target profiles

### 5.1 Track L practical Linux distribution

**Proposed initial scope:** x86_64 QEMU/KVM first; a pinned Linux
kernel/configuration; systemd init; signed Btrfs root with LUKS2 encryption
and snapshot rollback; glibc dynamic userspace; and the declared Wayland
desktop/session profile. It does not promise arbitrary hardware, proprietary
drivers, GPU compute, or every Omarchy package.

The profile declares firmware/boot mode, disk/encryption/recovery policy,
kernel modules, early userspace, repository snapshots/keyring, rootfs and
update model, supported device classes, desktop session, service graph,
network modes, serial diagnostics, and unsupported behavior.

### 5.2 Track Z native kernel

**Proposed baseline:** x86_64 UEFI with systemd-boot, QEMU/KVM, serial console,
one CPU before SMP, GPT plus LUKS2/Btrfs root with declared subvolume/snapshot
semantics, signed initramfs, and virtio console/blk/net/rng/gpu/input/snd.
The Z-U0 bootstrap begins static; Z-U3 and Z9 require a pinned glibc dynamic
loader tuple compatible with the declared Arch package profile, or an audited
ported-package plan that provides the same named workflows. The graphical
baseline is DRM/KMS virtio-gpu, GEM/dma-buf/fences, Mesa userspace, evdev/udev,
ALSA, systemd, D-Bus, logind, polkit, PAM, Wayland, Hyprland, and Quickshell.
Linux/Vinix compatibility arrives in tiers, not at first boot.

Progression is x86_64 boot and traps; one fault-contained user process;
durable VFS/block and bounded multiprocess userland; SMP/devices/network/
security; selected Vinix and Linux tiers; then required Z9 native
normal-computer distro delivery. KWP1 may amend a baseline only through a
recorded RBM design decision and requalification of every dependent gate.

## 6. Native Zig-kernel work packages

### Z1 Boot, traps, and diagnosis

**Owner seams:** architecture boot, paging, GDT, entry, new IDT/trap/APIC/
serial modules, linker assets, and native-qualification scripts.

Deliver a UEFI PE/COFF boot stub compatible with the baseline systemd-boot
chain, initramfs acquisition, GetMemoryMap and ExitBootServices retry handling,
boot-services lifetime/ownership rules, and a defined handoff into the native
kernel. Then establish early allocator, page-table ownership, GDT/TSS/IDT,
exception-frame layout, serial log, timer, and halt/reboot/panic policy. Page
fault, double fault, GP, invalid opcode, and machine-check paths must save safe
diagnostics and avoid recursive failure. The raw ELF demo is not a
systemd-boot handoff format.

**Acceptance:** exact RBM emits a valid EFI image, systemd-boot loads it with
the selected initramfs, and declared QEMU/KVM profiles reach the native handoff.
Serial names artifact and stages; bad-page, invalid-opcode, and user/kernel
protection probes produce controlled traces. i386 demo evidence does not close
Z1.

### Z2 Privilege, interrupt, and one-process execution

**Owner seams:** Z1 plus proc, uaccess, syscall, MM, and scheduler modules.

Deliver CPL0/CPL3 transitions, selected syscall entry, per-process address
spaces, guarded stacks, fault-contained user copy, timer preemption,
signal/exception handling, exit/wait/reap, and safe terminal process state.
Host pointer dereference cannot substitute for fault recovery.

**Acceptance:** static x86_64 ELFs run bounded hello, file, fault, signal,
fork/exit/wait, and preemption corpus. Bad pointer/opcode/stack/page tests
cannot corrupt kernel or another process.

### Z3 MM and SMP

**Owner seams:** MM, scheduler, atomics/locks, and architecture APIC/trap/
paging modules.

Replace global/hosted assumptions with physical-page accounting, page tables,
COW/fork policy, demand fault policy, TLB invalidation, per-CPU state, AP
startup, IPI protocol, per-CPU run queues, lock/RCU policy, and OOM behavior.

**Acceptance:** one-CPU corpus passes first; then a declared two-vCPU corpus
proves AP online/offline, wakeup, TLB shootdown, fork/exit, allocator pressure,
and lock diagnostics. Simulated per-CPU data cannot close Z3.

### Z4 VFS, block, and durable storage

**Owner seams:** VFS, ext4, block driver, new buffer/page-cache, partition,
virtio-pci/blk, and filesystem modules.

Define object lifetimes, namespace/mount scope, path resolution, credentials,
locking, poll readiness, cache/writeback, fsync ordering, block timeout/retry,
flush/barrier, and crash semantics. The first native profile may support one
declared writable filesystem and virtio-blk only.

**Acceptance:** install a bounded rootfs, mount it, create/rename/link/unlink/
fsync across reboot, inject torn writes/timeouts, and run selected filesystem
recovery checks. A ramfs or reader-only path is not closure.

### Z5 Process, POSIX, and UAPI tiers

**Owner seams:** syscall/entry/proc/signal/time/stat modules, generated
headers/manifest, and UAPI tests.

Publish generated manifests for syscall numbers, argument widths, structs,
alignment, errno, restart behavior, signal frames, threads, fd lifecycle,
poll, time, ioctl families, filesystem semantics, and unsupported errors.

| Tier | Promise |
| --- | --- |
| Z-U0 | Static native ELF tools with serial stdio, files, and exit. |
| Z-U1 | Selected POSIX-like source ABI: process, pipe, signal, mmap, directory and file semantics. |
| Z-U2 | Selected Vinix syscall/ioctl/header/workload parity. |
| Z-U3 | Selected Linux syscall/libc/dynamic-loader/workload profile. |

Unlisted features are unsupported and return documented errors. They are never
advertised as working stubs.

### Z6 Devices, network, and observability

**Owner seams:** drivers, net, time, and new PCI/virtio/IRQ/DMA/observability
modules.

Start with virtio console, block, net, RNG, and balloon. Define DMA/IOMMU
assumptions, descriptor ownership, interrupt acknowledgement, pressure,
watchdog/reset, and hot-unplug errors. Network delivery requires real packets
and an explicit IPv4/IPv6/TCP/UDP/routing/DNS/firewall profile.

**Acceptance:** packet capture proves guest-peer exchange, loss/reorder/MTU/
queue pressure, driver reset, and no DMA corruption. Serial/persistent logs,
crash record, and redacted health data survive failures.

### Z7 Security

**Owner seams:** security, credentials, process/VFS/device modules, boot and
image signing, crash/recovery tooling.

Define real uid/gid/groups, permissions, mounts, capability/LSM policy,
W^X, address separation, module/driver signing, selected secure-boot chain,
entropy, audit, crash dump, and emergency-shell policy. Hosted global allow
behavior cannot be promoted.

**Acceptance:** credential/file/memory/ELF/driver/input/image-tamper corpus
passes on exact RBM hardware/emulator profiles.

### Z8 Image lifecycle

Produce reproducible kernel/rootfs artifacts, SBOM/provenance, boot health
marking, A/B or equivalent recovery, signed update metadata, recovery media,
and field diagnostics.

**Acceptance:** clean install, interrupted update, failed boot, rollback,
recovery boot, evidence export, and downgrade/upgrade corpus pass.

### Z9 Required native normal-computer distro

This is a delivery stage, not an architecture decision. The native profile
must implement or integrate and qualify: DRM/KMS, GEM and dma-buf/fence
semantics, an approved Mesa userspace profile, evdev/udev device discovery,
ALSA audio, netlink, procfs, sysfs, cgroups, systemd, D-Bus, logind, polkit,
PAM, Wayland, Hyprland, Quickshell, browser/editor/terminal/file-manager, and
the declared language/toolchain/package workflows. The native root filesystem
must state whether it provides exact Omarchy Btrfs/LUKS/snapshot semantics or a
functional alternative; a functional alternative has different name, recovery
rules, and acceptance cases.

**Owner seams:** kernel DRM/input/audio/netlink/proc/sys/cgroup modules; native
rootfs/toolchain/systemd integration; distro session/desktop/package
configuration; installer/update/recovery; and end-to-end test fixtures.

**Acceptance:** exact native RBM passes clean install, encrypted boot, login,
Wayland desktop, input/audio/display hotplug, browser/editor/terminal tools,
package install, developer build/test, suspend/reboot, update/rollback,
snapshot/recovery, and disconnected diagnostics. Linux-backed Track L passes
are reference results only and cannot close Z9.

### Z11 Native sandbox-host profile

**Owner seams:** new hypervisor, host-isolation, guest-agent, image/volume,
egress/export, and native-host test modules. The accountable VM/isolation lead
owns this stage with the sandbox service lead. It implements the native host
side of the sandbox contract, not merely a native guest image.

**Acceptance:** on an exact native-host RBM, boot a declared VM and guest
agent; exercise create/exec/stop/destroy and pause/resume when advertised;
inject VM, agent, and host-service crashes; prove kill/reap/restart and durable
fencing; reject cross-tenant access; prove default-deny egress and selected
authorized export policy. It must meet the corresponding sandbox lifecycle,
storage/identity, abuse, and provider gates in sandbox.md, with no arbitrary
host-execution fallback.

### Z10 ARM64 and declared non-goals

ARM64 is a required roadmap track after Z1-Z5 have architecture-neutral
contracts: boot protocol, exception/vector entry, MMU/page-table policy, GIC
interrupts, timer, SMP/PSCI, serial, virtio, ELF ABI, toolchain, and the same
UAPI/workload corpus. It has independent RBMs and gates; x86_64 success is not
an ARM64 pass.

The initial release explicitly excludes hypervisor hosting, Xorg, proprietary
drivers, GPU compute, gaming, arbitrary external hardware, and unqualified
Wi-Fi/Bluetooth/printing. Each remains a versioned backlog profile with
hardware, license, security, update, and workload acceptance before it can be
advertised.

## 7. Vinix source and UAPI parity

Vinix is a source and behavior comparator, not a specification copied by
syscall-name count. Select a pinned Vinix commit, architecture, build profile,
and usable test corpus first. Generate inventories from both trees and classify
each selected item as equivalent, divergent, unsupported, or untested.

| Dimension | Required comparison |
| --- | --- |
| Architecture | Boot protocol, page size, exception entry, privilege, SMP, boards. |
| UAPI | Syscalls/errors/constants/structs/unions/alignment and ABI probes. |
| Process/signal | fork/thread/exec/wait, groups, frames, restart, scheduler observables. |
| VFS/storage | path/link/mount/permission/locking/poll/rename/durability under faults. |
| IPC/time | pipes, sockets, futex/events, clocks/timers/cancellation. |
| Network/devices | Declared virtual hardware and protocol observables. |
| Userland | Named Vinix applications/test programs under exact profile. |

| Gate | Deliverable | Pass condition |
| --- | --- | --- |
| V1 | Generated versioned inventory | Each selected Vinix item has a Zig status, owner, and evidence link. |
| V2 | ABI probe suite | Selected layouts, calls, constants, and errors agree or divergence is tested. |
| V3 | Differential semantics harness | Selected process/VFS/IPC/time/network behavior agrees observably. |
| V4 | Userland corpus | Named source/binary workloads pass. |
| V5 | RBM report | Only this selected profile is called Vinix parity. |

## 8. Linux ABI, libc, and binary compatibility

Linux binary compatibility needs more than syscalls: ELF loading, auxv/TLS/
vDSO expectations where selected, dynamic linker and libraries, signals,
threads, device/virtual filesystem assumptions, and ioctl behavior. Start
bounded and compare against the pinned Linux RBM.

| Stage | Declared scope | Required evidence |
| --- | --- | --- |
| LNX0 | Static native tools | Toolchain, ELF loader, syscall subset, rejection cases. |
| LNX1 | Selected static Linux-ABI tools | Named static utility/file/process corpus and trace comparison. |
| LNX2 | Dynamic libc profile | One libc/loader/interpreter tuple; auxv/TLS/errno/signal/thread corpus. |
| LNX3 | Package/workstation profile | Pinned runtimes, package managers, toolchains, and build/test workflows. |

A stage failure is a documented incompatibility or implementation item. It is
never hidden by executing the host binary.

## 9. Track L Linux-backed distribution plan

### L1 Product/profile contract

Define architecture, firmware, disk target, network modes, locale/input,
session/desktop, application bundles, repositories, driver policy, telemetry,
privacy/security policy, offline mode, recovery, and support boundaries.
Map each claimed user workflow to packages/configuration rather than a label.

### L2 Reproducible image and boot

Build rootfs from pinned repositories and verified keys. Emit bootloader,
kernel/initramfs, rootfs, manifest, SBOM, provenance, and checksums. Verify
only selected BIOS/UEFI and serial/graphical paths.

### L3 Init, login, and desktop

Define init graph, service accounts, user creation, login/session, compositor/
window manager, portals, sound, network manager, power/time, mount policy, and
accessibility/input. Each service needs readiness, failure/restart, diagnostic,
and disable/repair behavior.

### L4 Packages and apps

Publish a bounded package manifest: shell, terminal, editor, browser, file
manager, network tools, language runtimes/toolchains, Git, package managers,
fonts, and integrations. Require signed repository metadata, offline cache,
conflict/removal policy, and snapshot/lock. User installs use only the
declared profile and recovery rules.

### L5 Installer, update, rollback, recovery

Define installer UI/CLI, partition constraints, destructive-operation consent,
encryption/key recovery, first boot, update transaction, power-loss safety,
boot counting, rollback, rescue media, diagnostic export, and factory reset.
The installer cannot report success before its target is durable and bootable.

### L6 Hardware, network, and security

Start with QEMU/KVM virtio hardware. Publish each extra hardware class only
after driver/firmware/license/security acceptance. Define offline/LAN/internet
profiles and least-privilege desktop services without build-secret inheritance.

### L7 Operations and release

Operate repository mirrors, signing keys, build workers, update/vulnerability
process, advisories, telemetry policy, crash triage, channels, support window,
and rollback availability. Promotion binds exact image, installer, repository
snapshot, and evidence.

### L8 Bounded distro qualification

On exact RBM images, run clean install, boot/login/desktop, persistent user
files, suspend/reboot/shutdown, offline/wired network, package install/update/
rollback/recovery, browser/terminal/editor/file manager, language build/test,
declared device attach, and serial/graphical diagnostics. Compare selected
workflows with the local Omarchy reference through a pinned content manifest;
the local revision alone is not a content hash. Waku-os can validate
Buildroot/QEMU methodology only.

## 10. Ordered work packages

| WP | Depends | Proposed owner paths | Deliverable | Acceptance |
| --- | --- | --- | --- | --- |
| KWP1 Evidence/spec | none | audits, docs/uapi, tests/rbm, CI manifests | RBM, profiles, stale-doc inventory | Every claim maps to artifact and gate. |
| KWP2 Native boot | KWP1 | src/arch/x86_64, linker assets, scripts/qualify-native | Z1 | Exact x86_64 boot/trap corpus passes. |
| KWP3 Native process/MM | KWP2 | src/mm, src/proc, src/sched, src/uaccess.zig, src/syscall.zig | Z2-Z3 | User-fault and two-vCPU gates pass. |
| KWP4 Native VFS/block | KWP2,KWP3 | src/vfs, src/fs, src/drivers/block, tests/native-storage | Z4 | Reboot/fault/writeback corpus passes. |
| KWP5 Native UAPI | KWP3,KWP4 | include/zk-uapi, docs/uapi, tests/uapi | Z5 tiers | Layout/error/semantic probes pass. |
| KWP6 Native device/net/security | KWP3-KWP5 | src/drivers, src/net, src/security, tests/native-io | Z6-Z7 | Real emulated I/O/security/crash corpus passes. |
| KWP7 Native lifecycle | KWP2-KWP6 | images/native, scripts/release-native, tests/recovery | Z8 | Install/update/power-loss/rollback corpus passes. |
| KWP8 Vinix parity | KWP1,KWP3-KWP6 | tests/vinix, tools/uapi-inventory | V1-V5 | Pinned matrix passes. |
| KWP9 Linux ABI | KWP1,KWP3-KWP6 | tests/linux-abi, toolchains/linux-profiles | LNX0-LNX3 | Each advertised stage passes exact RBM. |
| KWP10 Distro foundation | KWP1 | distro/profiles, distro/rootfs, distro/boot, distro/keys | L1-L2 | Reproducible image/boot matrix passes. |
| KWP11 Distro lifecycle | KWP10 | distro/init, distro/desktop, distro/installer, distro/update, tests/distro | L3-L7 | Install/login/package/update/recovery pass. |
| KWP12 Distro profile | KWP10,KWP11 | tests/distro, tests/rbm, release evidence | L8 | Selected workflow matrix passes. |
| KWP13 Native normal-computer distro | KWP7-KWP9 | src/drm, src/input, src/audio, src/procfs, src/sysfs, src/cgroup, native-rootfs, native-desktop, tests/native-distro | Z9 native workstation/distro implementation | Exact native RBM passes Z9; no Linux-backed result substitutes. |
| KWP14 ARM64 and extended profiles | KWP3-KWP9,KWP13 | src/arch/aarch64, platform/arm64, profiles/hardware, tests/arm64 | Z10 ARM64 plus separately qualified extension backlog | ARM64 RBM and each enabled extension pass their own gates. |
| KWP15 Native sandbox-host profile | KWP6-KWP9,KWP13 | src/hypervisor, src/host-isolation, src/guest-agent, tests/native-host | Z11 native host lifecycle/isolation integration | Exact native host RBM passes tenant escape, lifecycle, recovery, and service-contract gates. |

**Accountable owner roles:** release/spec lead owns KWP1 and final evidence;
architecture lead owns KWP2/KWP14; kernel runtime lead owns KWP3/KWP5;
storage lead owns KWP4; device/network/security leads own KWP6; image and
recovery lead owns KWP7; compatibility lead owns KWP8/KWP9; distribution lead
owns KWP10-KWP12; and native desktop/userland lead owns KWP13. Ownership is
assigned before implementation; the VM/isolation lead jointly with sandbox
service lead owns KWP15. A source-directory label alone is not an owner.

## 11. Hard gates

| Gate | Required proof | Blocks |
| --- | --- | --- |
| Z1 | x86_64 boot/trap/serial evidence | Native kernel claim |
| Z2 | CPL3, fault, preemption, process/reap corpus | Native userspace |
| Z3 | AP, TLB, scheduler, allocator concurrency | SMP/multiprocess claim |
| Z4 | Durable rootfs and block-fault recovery | Persistent native distro |
| Z5 | Generated ABI and semantics tests | Vinix/Linux compatibility wording |
| Z6 | Real virtio/DMA/IRQ/network corpus | Native device/network claim |
| Z7 | Credential/memory/boot/hostile input corpus | Native security claim |
| Z8 | Update/rollback/recovery corpus | Native production profile |
| Z9 | Native normal-computer distro/desktop/install/update/recovery matrix | Native Zig Omarchy-profile claim |
| Z10 | ARM64 boot/UAPI/workload matrix, or explicit profile exclusion | ARM64 claim and enabled extensions |
| Z11 | Native sandbox-host hypervisor/isolation/guest-agent/recovery matrix | Native sandbox-host claim |
| V1-V5 | Pinned Vinix report | Vinix parity wording |
| LNX0-LNX3 | Pinned Linux stages | Linux ABI/binary wording |
| L1-L8 | Linux distro image/workflows | Distro profile wording |
| R1 | Exact RBM hash equality and evidence review | Promotion |

### 11.1 Proposed quantitative release defaults

These are finite starting gates to calibrate per RBM, not performance SLAs:

| Check | Proposed minimum evidence |
| --- | --- |
| Boot | 100 consecutive cold/reboot cycles for each declared firmware/device profile, with serial artifact identity and no unexplained failure. |
| Soak | 24-hour one-CPU and 72-hour declared-SMP workload/idle/network/storage soak, with leak, lockup, watchdog, and crash accounting retained. |
| Fault | Each supported block, network, process, filesystem, and update fault point is injected at least once before and after durable commit; no expected test is marked pass by skip. |
| Upgrade | One successful upgrade and one rollback from every supported prior release edge, including an interruption before boot health marking. |
| Hardware | Every advertised device class has an RBM machine/firmware/driver tuple and the matching boot, I/O, suspend/resume or hotplug tests; untested hardware stays unsupported. |
| Distro desktop | 24-hour logged-in graphical session plus the Z9 install/update/recovery workflow on the declared display/input/audio profile. |

Linux kernel selftests are a useful reference method: build/install/boot the
selected kernel, then run selected userspace tests, retaining configuration and
dependencies. The plan uses a pinned subset and never treats a skipped test as
a pass. [Linux kselftest documentation](https://docs.kernel.org/dev-tools/kselftest.html)
Linux internal interfaces are not stable compatibility contracts; generated
comparison targets use selected UAPI and observable behavior rather than
copying internal implementation interfaces. [Linux stable API guidance](https://docs.kernel.org/process/stable-api-nonsense.html)

## 12. Workload matrix

| Workload | Track L initial target | Track Z target |
| --- | --- | --- |
| Boot/recovery | Linux image and recovery media | Z1/Z8 |
| Shell/process | Pinned shell/core utilities | Z-U0 then Z-U1 |
| Files | Declared rootfs/home semantics | Z4/Z-U1 |
| Network | Offline/LAN/approved internet | Z6 |
| Developer tools | Pinned compiler/runtimes/build project | LNX2/LNX3 |
| Desktop/apps | Declared compositor/browser/editor/file-manager | Z9 native implementation and evidence |
| Sandbox guest | Linux VM profile per sandbox audit | Only after equivalent native gates |

## 13. Release language

Until remaining gates pass, describe this checkout as: hosted Zig kernel
model; i386 QEMU demo; **bounded native x86_64 UEFI bootstrap smoke** (no
CPL3/Linux/Alpine/desktop/Photon); diagnostic sandbox API
(`execution:false`); planned Linux-backed distro profile; selected Vinix
comparison in progress; selected Linux ABI profile in progress; native Zig
kernel userspace profile in progress. Do not use production, complete,
Linux-compatible, Vinix parity, Omarchy parity, SMP, desktop distro, or
normal computer without matching RBM and gate evidence. Do not describe the
UEFI smoke as a Linux replacement.

## 14. Traceability

| Requested result | Plan coverage |
| --- | --- |
| Production Linux path | Track L, Section 9, KWP10-KWP12, L1-L8/R1. |
| Native Zig kernel | Track Z, Section 6, KWP2-KWP7, Z1-Z8/R1. |
| Vinix source/UAPI parity | Section 7, KWP8, V1-V5. |
| Linux binary/syscall/ioctl/libc parity | Section 8, KWP9, LNX0-LNX3. |
| Linux distro installer/update/recovery/desktop/apps | Section 9, KWP11-KWP12. |
| Required native distro/Omarchy-profile delivery | Z9, KWP13, Z9/R1; Track L is reference only. |
| ARM64 and extended hardware/desktop profiles | Z10, KWP14, Z10/R1. |
| Native sandbox-host profile | Section 4, KWP15, Z11/R1; guest workload evidence is insufficient. |
| Sandbox relation | Section 4 and [sandbox audit](sandbox.md). |
| Honest documentation | Section 2.1 and KWP1. |
| Required native desktop ISO / calculator evidence | Section 16 and [desktop distro plan](../docs/desktop-distro.md); Z9/KWP13 detail only. Calculator does not close Photon. |
| Required native Photon Studio Flatpak (PHOTON-1) | Section 16.4, [photon-studio.md](../docs/photon-studio.md), [desktop distro plan](../docs/desktop-distro.md), [acceptance manifest](../tests/native-distro/photon-studio/manifest.json); production release blocker. **Not implemented / not run.** |

## 15. Alpine Linux profile (planned; not in this checkout)

**Pinned release (plan input):** docker.io/library/alpine:3.24.1  
**Index:** sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b  
**amd64 manifest:** sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f  

This profile is an unimplemented future work package. It would provide a
**minimal OCI base** (shell target) and a **separate sandbox API target**
using the official Alpine 3.24.1 release, plus a native musl/apk userland
profile for KWP9/KWP13 alongside existing glibc/Omarchy requirements. Alpine
OCI packaging, host qualification drivers, and native musl userland are **not**
in this checkout and are **not** qualified. It does **not** replace native
kernel work.

### 15.1 Three independent products (never conflated)

1. OCI Alpine base shell: musl, BusyBox, apk, signed keys, TLS certs. Usable with `FROM` and `docker run -it ... sh`.
2. OCI Alpine sandbox API: derives from base, adds the actual `zig-sandbox` binary, runs nonroot, healthcheck present, preserves `execution:false`, 503 ready, 501 sandbox mutations.
3. Native Zig musl/Alpine userland profile (KWP9/KWP13 track): unmodified musl loader + BusyBox + apk + pinned corpus must run on a *booted Zig kernel artifact*. Host-Linux-container results (any OCI) never close native gates.

A fourth concern (bootable OpenRC distro) is separate; containers do not run OpenRC as PID1 or boot their own kernel.

### 15.2 Architecture and build constraints

- [build.zig](../build.zig) `sandbox-api` target is `x86_64-linux-musl`:
  ```zig
  .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl
  ```
  The `zig-sandbox` binary is always x86_64-linux-musl bytes. Do not retag arm64 output.
- zig-builder stage (amd64) in the published [Dockerfile](../Dockerfile) runs the official glibc-linked Zig 0.16 tarball (checksum `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`).
- A future Alpine image would use its own Docker context. Root `.dockerignore` is untouched. That packaging lane is **not in this checkout**.
- [build.zig.zon](../build.zig.zon) currently lists `src`, `supervisor`, `boot`, `linker`, `tools`, `tests`, `scripts`, `docs`, `engine`, `schemas`, `vendor/sqlite`, `Dockerfile`. Alpine packaging still requires later integration.
- arm64 base layer selectable via platform + index pin. API arm64 image is not produced.

### 15.3 Package operations, corpus, signed rejection

apk must support (root in base/build, rejected for service UID):
- update / add --no-cache / del / fix / upgrade / info
- dependency resolution, triggers, signature verification

**Exact workload corpus (developer profile):**
- C + pthread dynamic (build-base, compile, run)
- C++ link
- Python3 + sqlite3 + HTTPS
- Node (availability noted per release)
- SQLite CLI
- wget/curl + verified HTTPS + DNS
- BusyBox tools, ldd, file, readelf, ps

**Signed rejection:** tampered index or package must fail with non-zero exit and leave package db unchanged. Never `--allow-untrusted`.

### 15.4 FROM / run / mount / WORKDIR / USER behavior

- Base supports ordinary `FROM my-base`, `docker run -it base sh`, `ENV`/`WORKDIR`/`USER`/`VOLUME`.
- API: nonroot, `--read-only` + explicit tmpfs for cache, bind mounts, exec as chosen uid.
- Examples and matrix are recorded at qualification time; none exists in this checkout.

### 15.5 Architecture gates (two)

1. **amd64** — build + full offline smoke + network package lane + API negative + size/startup/RSS measured vs same pinned official amd64 baseline.
2. **arm64** — base layer only via platform (unqualified until real arch-specific runtime + package behavior matrix executed on arm64 Linux). No API arm64 image.

macOS/Windows Docker always runs Linux containers via VM; never counts as native userland.

### 15.6 Measurement and truth rules

- Size = actual compressed registry + unpacked (measured); never website estimates.
- Startup/RSS measured under identical commands against the pinned 3.24.1 image.
- `execution:false` is preserved verbatim in the API image (see bootstrap + contract).
- Host container success ≠ Zig kernel parity. Native profile requires booted Zig kernel + unmodified userland binaries.

### 15.7 Qualification lanes (separate)

- **Offline smoke:** identity, musl interpreter, BusyBox shell/pipes/exit, ca/keys, writable volume vs read-only-root rejection, downstream FROM build, nonroot API + exact diagnostic responses (200/503/200/501).
- **Network package:** live signed apk + corpus + tampered rejection + DNS/TLS + compile/run samples.
- Qualification tests are not in this checkout. No host package installs. Results recorded only after pass.

### 15.8 Current status (this publication tree)

Alpine OCI/native userland is **not implemented** and **not qualified** in
this checkout. Full qualification, size numbers, package snapshot hashes,
tampered-rejection logs, arm64 base matrix, and native-track cross-checks
remain pending. Host-container success would still not be Zig-kernel parity.

Native Zig kernel roadmap (Z1–Z11, KWP9/KWP13) is unchanged. This Alpine
profile states the mandatory minimal musl/apk surface for those work
packages without substituting for them.

## 16. Native desktop distro ISO plan

**Detail:** [desktop distro plan](../docs/desktop-distro.md) (Z9/KWP13 detail: baselines, products/media, chain, protocols, packages, named apps, calculator vectors, governance, stages S0–S12+S8a/b **+ S13 PHOTON-1**, quantitative gates §7.1, bibliography §8, Photon Flatpak overlay). Photon contract: [photon-studio.md](../docs/photon-studio.md).

**Historical local inputs (labeled references, not Markdown links; not in this checkout):** Vinix revision `e4b95129e6ac12d1ec84f060c5becd6e390db85a` — `vinix/README.md` (pre-alpha, Alpine minirootfs, no mlibc bootstrap), `vinix/desktop/README.md` (fb0/pointer/terminal-keyboard, VAPP v3 per-process apps, VSF1, Xvfb bridge, aarch64 Hyprland layer), `vinix/build-desktop-amd64.sh`, `vinix/run-desktop-amd64.sh` (q35, std VGA, 4 vCPU, KVM/TCG), `vinix/build-support/build-amd64-iso.sh` (Limine comparator), `vinix/build-userland-amd64.sh` (Alpine 3.21.7), `vinix/build-support/init-amd64/desktop-init` + `alpine-init`, `vinix/desktop/app_process.v` / `framebuffer.v` / `input.v` / `vinix_surface.v` / `calculator_app.v`, `vinix/tests/wine/calculator.c` (div-zero returns `0.0`), `vinix/build-support/vinix-pkg` (Alpine 3.21 tracking), `vinix/build-x11-aarch64.sh` line 33 (xorg-server **21.1.16**). Omarchy revision `590d7d1cf6b61bdada16ca6e6e9d1bf7d1d18da2` — `omarchy/version` 4.0.0.alpha, `omarchy/install/omarchy-base.packages` (chromium:16, foot:42, nautilus:85, omacalc:95 required-later compatibility target, quickshell:112, portals:143-144), `omarchy/default/wayland-sessions/omarchy.desktop` (uwsm Hyprland). These are comparator notes, not files in this checkout.

**Current truth (as of selected head `6c8c8ca0611005e7776f437f381c55a866a67e3c`):** No native CPL3 userspace, desktop, ISO, calculator, or Photon/Flatpak run. Bounded native x86_64 UEFI bootstrap is recorded in [native-bootstrap.md](../docs/native-bootstrap.md): PE32+ loader, ELF64 payload, FAT16 ESP, 108-byte `INITRMF1` smoke; hosted native contracts and qualifier host fixtures as documented there; `linux_replacement_qualified` is false. Diagnostic sandbox API remains `execution:false` / `/readyz` 503 as recorded in [sandbox-api-implementation.md](../docs/sandbox-api-implementation.md). Native CR3 probe is a separate publication and is not in this checkout. Host-container evidence closes nothing native. Photon facts are static header observation only (application not executed).

### 16.1 Binding decisions (D1 repaired)

Native Zig EFI loader + BootInfo contract with systemd-boot chain retained as baseline (parent §5.2, §6 Z1); Vinix Limine ISO recipe is a comparator, with any Limine-boot adapter a separately gated profile (named handoff adapter + retained EFI tests + extra acceptance). Initial planned root: cpio/newc read-only subset with exactly `/init` + manifest; the current 108-byte smoke envelope (64-byte `INITRMF1` header + 44-byte fixed payload, this checkout `src/native/initramfs.zig` + `tools/mkinitramfs.zig`) is not a filesystem. x86_64 QEMU/KVM first, ARM64 separately gated (Z10). First compositor: custom framebuffer, software canvas, per-process apps over own versioned pipe IPC (own magic, not VAPP bytes; source/license provenance is ordinary RBM/SBOM inventory; parity = ported app behavior). Omarchy profile: Wayland primary — pinned Hyprland via uwsm, Quickshell, portals; Xwayland only as separately verified bridge. Three ABI profiles never mixed: P-boot (static), P-musl/Alpine-apk (Vinix parity), P-glibc/Arch-pacman (Omarchy parity). Calculator: C1 native `zk-calc-d1` (immediate-execution, sticky-`Error` div-zero); C2 proposed own-app GTK4 `zk-calculator` on Wayland; required later compat rows for `omacalc` behavior, Wine amd64-direct, Wine ARM64-translated, Cocoa/Mach-O (port-vs-binary labelled per row, own-clone success never closes them); Wine sample keeps frozen `0.0` div-zero.

### 16.2 What Z9/KWP13 now requires (D2–D6 repaired)

Reproducible hybrid live/install ISO with P0 preview / P1 QEMU candidate / P2 production profiles (finite hardware scope per profile); ordered chain with framebuffer/input drivers in S6 and S8 split into S8a (C1a boot/interactive, P0) + S8b (C1b persistence/install, needs S7, P1); D2 protocol inventory split into Wayland wire / X11-Xwayland / D-Bus-portal / native IPC / kernel-device boundaries with per-row provider, pin location, and test; desktop-path decisions for native VAPP-equivalent, direct Xorg, embedded Xvfb, Wayland/Hyprland, Xwayland, **Flatpak+OSTree+bubblewrap (PHOTON-1)**, Wine amd64-direct vs ARM64-translated, Cocoa required-later parity; named app matrix (§5 of detail doc: foot/nautilus/chromium/zk-calculator/omacalc-compat/nvim-in-foot/editor/settings/installer/session/compat **and Photon Studio** rows with owner, manifest location, test); corrected Wayland registry/child identifiers with IME as gated feature; provenance preconditions restored before vectors; calculator vectors V1–V8 with exact results (64-digit bound, 65th → sticky `Error`; `theme=dark` preserved across remove/reinstall, purge resets `light`), clipboard roundtrip via foot/nvim, disconnect bounds (5 s deadline, 50 cycles, 0 leaks, ΔRSS ≤ 1 MiB), evidence bundles under `tests/native-distro/calculator/<run-id>/`; Photon contract under `tests/native-distro/photon-studio/` (acceptance spec, **no run evidence**); bibliography with labeled sibling inspection references; quantitative gates adopting parent [§11.1](#111-proposed-quantitative-release-defaults) plus GUI bounds (launch ≤ 15 s, input→result ≤ 1 s median, skip = FAIL) and Photon proposed bounds in the Photon contract. **S13/PHOTON-1** is an additional stage; D1-only/Wayland-only previews cannot close it.

### 16.3 Governance

C1a/C1b/C2 close only their slices. PHOTON-1 closes only the Photon Flatpak contract. Production needs full Vinix matrix, desktop suite, installer/update/rollback/recovery, integrity/security/soak/reproducibility/hardware passes + R1 **and PHOTON-1**. All Z9/V/LNX/R1/PHOTON-1 gates stay open. No plan-as-evidence: this section, `docs/desktop-distro.md`, and `docs/photon-studio.md` are plan/contract, not implementation. Never claim Photon already runs.

### 16.4 Photon Studio Flatpak mandatory production gate (PHOTON-001, added 2026-09-13)

**Detail:** [photon-studio.md](../docs/photon-studio.md). **Acceptance artifact:** [tests/native-distro/photon-studio/manifest.json](../tests/native-distro/photon-studio/manifest.json) (status `not_run` / `blocked_prerequisites` only). **Desktop plan:** Photon rows in [desktop-distro.md](../docs/desktop-distro.md) §0/§2/§3.2/§4/§5/§7 S13.

**Artifact (public identity):** basename `Photon-Studio-0.1.5-linux-x64.flatpak`; `282701144` bytes; SHA-256 `49db545b57e9f6c01c063a7f90e774c446a20d10f95b2943263ae5154c077f6a`; header ref `app/com.tenzen.photon/x86_64/stable`. Observed header (raw scan, not a run): app `com.tenzen.photon`; runtime `org.freedesktop.Platform/x86_64/25.08`; SDK `org.freedesktop.Sdk/x86_64/25.08`; base `app/org.electronjs.Electron2.BaseApp/x86_64/25.08`; command `electron-wrapper`; shared `network;ipc;`; sockets `x11;pulseaudio;`; devices `dri`; filesystems `home;/media;/run/media`; debug extension `com.tenzen.photon.Debug` autodelete/no-autodownload true. SDK/BaseApp are **not** automatic extra launch-runtime installs. Platform/GL/font/locale **commits unknown** until dependency resolution; do not invent them. Bundle is app payload, not a kernel or full runtime closure. Filename version is not signed provenance. x86_64 only; ARM/Windows/Mac not proven. Electron/Chromium versions unknown. Honor declared permissions; **do not add** `--no-sandbox` or extra `--filesystem=host` as an acceptance shortcut; no extracted-binary shortcut. Wrapper internals unknown.

**Launch lane:** real Xorg or Xwayland inside the native compositor session. Pure Wayland/D1-only cannot close PHOTON-1. PulseAudio socket or verified PipeWire-Pulse. DRI request ≠ hardware acceleration; declare and test the selected lane (real device/driver or labelled software-GL, no hardware claim on software). `home` is granted — do not claim home isolation; test denials on **selected protected host paths** outside authorized host mounts (not every path outside home/media; `/app`, `/usr`, and necessary VFS mounts are valid). Withdrawing a permission may be graceful degradation, not a mandatory whole-app exit.

**Host libc:** musl P-musl does not automatically run this glibc Flatpak; glibc-compat profile required. Namespaces/seccomp and related UAPI: unsupported required isolation fails closed. Filesystem adapters for Flatpak deploy/persist are swappable contracts (permissions/links/xattrs/atomic rename/mmap/durability); no silent host-fs bypass of a selected virtual/SQLite mount; no Photon pass on a profile that lacks those semantics.

**Acceptance-shortcut policy:** do **not add** `--no-sandbox` or extra `--filesystem=host`. Wrapper internals unknown; do not invent a proven Chromium-inner sandbox. Flatpak outer containment must enforce declared grants.

**Status:** not implemented, not run, production blocker. Calculator remains mandatory and does not close Photon. C1/C2/D1/D2 stages preserved. Do not redistribute the 282701144-byte blob (282.7 MB / 269.6 MiB) into the repo or ISO without a license/distribution basis. Advisor static-only inspection is complete as a static report; it is not an authenticated signature or complete OSTree/ELF/runtime scan. Inspection-container missing Platform 25.08 is not proof that static OSTree checkout inherently requires a runtime. Staging commit `7f32496a238d3c92259f82e9231a010ea0c2bcff3dcb34c352500d2853750915` is provisional, not a verified installed app commit.

