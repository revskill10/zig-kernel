# Zig Kernel

Zig 0.16.0 hosted kernel simulation, i386 QEMU demo, native x86_64 UEFI
bootstrap, and supervisor component tests. Companion to
`@12-factor-agents/linux-kernel-architecture.md`. Hosted models are not
Linux ABI or hardware qualification.

## Functionality

| Surface | Today | Planned / not runnable here |
| --- | --- | --- |
| Hosted `zig-kernel` | Native sim: paging, VFS, loopback net, scheduler | Linux ABI, hardware, production isolation |
| i386 QEMU | `qemu-bin` ELF32 demo | Linux userspace |
| Native x86_64 UEFI | PE32+ loader, ELF64 payload, FAT16 ESP, smoke initramfs | CPL3 userspace, Linux ABI, Alpine rootfs, desktop, production isolation |
| Supervisor | Hosted tests: policy, session, workspace, API, QEMU args | Process lifecycle, Unix-socket server, guest qualification |

## Quick start (Zig 0.16.0)

```sh
zig build run    # hosted sim (Windows/Linux, no QEMU)
zig build test
zig build        # zig-out/bin/zig-kernel
zig build test-supervisor
```

`run` prints a VFS read of `/hello.txt` (33B) and an e1000 loopback recv (72B).
The e1000 path is a hosted simulation of descriptor rings and `netif_rx`, not a
real PCI/MMIO hardware driver.

i386 QEMU (not Linux userspace):

```sh
zig build qemu-bin -Doptimize=ReleaseSmall   # zig-out/bin/kernel-baremetal
bash scripts/qemu-x86_64.sh                  # Linux with QEMU
```

Guide: [docs/qemu-verification-guide.md](docs/qemu-verification-guide.md).
The image is a standalone freestanding kernel demo. It does not boot Linux
userspace or provide production isolation.

## Native x86_64 UEFI bootstrap

Opt-in first slice: PE32+ UEFI loader, ELF64 payload at 2 MiB, 64 MiB FAT16
ESP, and a 108-byte `INITRMF1` smoke envelope. It does **not** enter CPL3,
implement a Linux ABI, boot Alpine or any other rootfs, or provide desktop
or production isolation. Hosted `zig build` / `zig build test` remain the
default simulation path above.

```sh
zig build native-image
zig build native-tools
zig build test-native
zig build test-native-qualification
```

`native-image` installs `BOOTX64.efi`, `zk-kernel`, `native/initramfs.bin`, and
`native/esp.img`. `native-tools` builds `mkinitramfs`, `mkesp`, and `imginfo`.
`test-native` is hosted contract tests (no QEMU). `test-native-qualification`
runs host fixtures for the public qualifier (no guest).

The public qualifier (`scripts/qualify-native/qualify.py`) requires the exact
pinned verifier image and OVMF hashes in `scripts/qualify-native/probe.py`. A
missing Docker daemon, missing pin, or a fresh unpinned image is
**unavailable**, not a pass. This repository does not publish or rebuild that
image. See [docs/native-bootstrap.md](docs/native-bootstrap.md) for ESP paths,
QEMU TCG expectations, and the current qualification boundary.

## Roadmap

Not in this checkout: sandbox server and client CLI, execution providers,
TypeScript and embedded Wasm SDKs and workloads, pluggable filesystems, host
mounts, host tools, pause/resume, and Linux/Alpine/Vinix/desktop/Photon
products.

## Docs

- [architecture](docs/architecture.md) — hosted layering and data flow
- [driver guide](docs/driver-guide.md) — simulated e1000 walk
- [native bootstrap](docs/native-bootstrap.md) — UEFI/ELF slice and qualifier
- [QEMU](docs/qemu-verification-guide.md) — i386 demo verification
