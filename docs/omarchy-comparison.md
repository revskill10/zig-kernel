# Comparison: zig-kernel vs vinix vs Omarchy QEMU Profiles

## Executive Summary

| Component | zig-kernel | vinix | Omarchy |
|-----------|------------|-------|---------|
| Language | Zig 0.16 | V (vlang) | Bash/Makefile/Buildroot |
| Architecture | Hosted simulation | Bare-metal native | Buildroot-based |
| Syscalls | 66 entries (host sim) | 66 entries (kernel) | Linux userspace |
| Testing | Unit tests (KUnit) | QEMU + serial | Integrated system tests |

## QEMU Infrastructure Comparison

### Build Systems

#### zig-kernel
```
build.zig (Zig-native)
- Single-file build definition
- Two targets: hosted | freestanding
- No external dependencies
- Cross-compilation via Zig std.Build
```

#### vinix
```
GNUmakefile
- Make-based build system
- Multiple architectures: aarch64, x86_64
- Limine bootloader integration
- Custom toolchain configuration
```

#### Omarchy
```
Buildroot 2026.05.2
configs/waku_qemu_x86_64_defconfig
board/waku/qemu/grub.cfg
- External toolchain (glibc)
- Package management (br2-external)
- ISO9660 rootfs with GRUB2
- Firmware: OVMF EFI + SeaBIOS fallback
```

### Kernel Boot Flow

#### zig-kernel (Hosted Simulation)
```
main.zig → boot.earlyBoot() → init subsystems → run demo
- No real GDT/IDT setup needed
- Simulated MMU via RAM arrays
- Serial output via stdout
```

#### vinix (Bare-metal)
```
boot.s → limine Brocker → kernel_entry → module init
- Full GDT/IDT setup in arch/x86_64
- Real paging via cr0/cr4
- Serial/console via UART/MMIO
```

#### Omarchy (QEMU ISO)
```
OVMF (UEFI) → GRUB → vmlinuz → initramfs → systemd
- UEFI firmware initialization
- GRUB2 with multiboot support
- Kernel command line parsing
- User-space initialization via systemd
```

## Hardware Emulation Support

### QEMU Machine Config

#### zig-kernel Target
Compatible with Omarchy's `waku-qemu-bios-diagnostic.sh`:

```bash
# qemu-system-x86_64 flags used:
-machine q35,accel=tcg    # Omarchy uses same
-cpu qemu64              # Omarchy: qemu64/default
-smp 1                   # Omarchy: configurable
-m 512                   # Omarchy: 512M
-boot order=d,menu=off   # Omarchy: from GRUB config
-cdrom rootfs.iso        # Omarchy: ISO9660
-nographic               # Omarchy: serial stdio
-no-reboot               # Omarchy: for diagnostics
-d guest_errors          # Omarchy: error logging
```

### Network Device

#### zig-kernel
- E1000 emulated at MMIO 0xFEB80000 (simulated)
- Descriptor rings in RAM
- Loopback via memcpy

#### vinix
- E1000 driver (kernel/modules/dev/net/e1000.v)
- Real PCI enumeration
- DMA via IOMMU

#### Omarchy
- Virtio-net (primary) via `CONFIG_VIRTIO_NET=y`
- e1000 available as fallback
- Bridge networking via TAP/virtual switch

### Storage

#### zig-kernel
- ramfs: in-memory filesystem
- Files created in `vfs.init()`
- No persistent storage

#### vinix
- initiramFS: cpio archive
- ext2/ext4 support
- Block device abstraction

#### Omarchy
- ISO9660 (read-only root)
- overlay filesystem
- persistent storage via host directory binding

## Syscall Parity Analysis

### Slot-by-Slot Comparison

| NR | zig-kernel | vinix | Match |
|----|------------|-------|-------|
| 0 | kprint | kprint | ✓ |
| 1 | mmap | mmap | ✓ |
| 2 | openat | openat | ✓ |
| 3 | read | read | ✓ |
| 4 | write | write | ✓ |
| 5 | seek | seek | ✓ |
| 6 | close | close | ✓ |
| 7 | set_fs_base | set_fs_base | ✓ |
| 8 | set_gs_base | set_gs_base | ✓ |
| 9 | ioctl | ioctl | ✓ |
| 10 | fstat | fstat | ✓ |
| 11 | fstatat | fstatat | ✓ |
| 12 | fcntl | fcntl | ✓ |
| 13 | dup3 | dup3 | ✓ |
| 14 | fork | fork | ✓ |
| 15 | exit | exit | ✓ |
| 16 | waitpid | waitpid | ✓ |
| 17 | execve | execve | ✓ |
| 18 | chdir | chdir | ✓ |
| 19 | readdir | readdir | ✓ |
| 20 | faccessat | faccessat | ✓ |
| 21 | pipe | pipe | ✓ |
| 22 | mkdirat | mkdirat | ✓ |
| 23 | futex_wait | futex_wait | ✓ |
| 24 | futex_wake | futex_wake | ✓ |
| 25 | getcwd | getcwd | ✓ |
| 26 | kill | kill | ✓ |
| 27 | sigentry | sigentry | ✓ |
| 28 | sigprocmask | sigprocmask | ✓ |
| 29 | sigaction | sigaction | ✓ |
| 30 | sigreturn | sigreturn | ✓ |
| 31 | getpid | getpid | ✓ |
| 32 | getppid | getppid | ✓ |
| 33 | readlinkat | readlinkat | ✓ |
| 34 | munmap | munmap | ✓ |
| 35 | unlinkat | unlinkat | ✓ |
| 36 | ppoll | ppoll | ✓ |
| 37 | rmdirat | rmdirat | ✓ |
| 38 | getgroups | getgroups | ✓ |
| 39 | socket | socket | ✓ |
| 40 | bind | bind | ✓ |
| 41 | listen | listen | ✓ |
| 42 | inotify_init | inotify_init | ✓ |
| 43 | mount | mount | ✓ |
| 44 | umount | umount | ✓ |
| 45 | signalfd | signalfd | ✓ |
| 46 | socketpair | socketpair | ✓ |
| 47-48 | vacant | vacant | ✓ |
| 49 | mprotect | mprotect | ✓ |
| 50 | clock_get | clock_get | ✓ |
| 51 | gethostname | gethostname | ✓ |
| 52 | sethostname | sethostname | ✓ |
| 53 | nanosleep | nanosleep | ✓ |
| 54-56 | vacant | vacant | ✓ |
| 57 | fchmod | fchmod | ✓ |
| 58 | linkat | linkat | ✓ |
| 59 | connect | connect | ✓ |
| 60 | getpeername | getpeername | ✓ |
| 61 | accept | accept | ✓ |
| 62 | recvmsg | recvmsg | ✓ |
| 63-64 | vacant | vacant | ✓ |
| 65 | new_thread | sched (sched_syscalls_new_thread) | ✓ |

### Parity Status: **100% Match**

All 66 syscall slots align between zig-kernel and vinix.

## Integration Path: QEMU Verification

To enable QEMU verification for zig-kernel:

1. **Add bare-metal target** in `build.zig`:
   - `os = .freestanding` instead of `.linux`
   - Link with `linker.ld` script
   - Set entry point to `arch/x86_64/boot._start`

2. **Extend boot.zig with real hardware setup**:
   - GDT (5 entries: null, code, data, stack, user)
   - IDT (256 entries, IRQ handler setup)
   - Paging (4-level, 512GB direct mapping)
   - UART/serial MMIO initialization

3. **Create initramfs** for testing files:
   - `/hello.txt` with expected content
   - Minimal `/proc`, `/sys`, `/dev`

4. **Adapt Omarchy QEMU script**:
   ```bash
   qemu-system-x86_64 \
     -machine q35,accel=tcg \
     -cpu qemu64 \
     -smp 1 \
     -m 512 \
     -bios /usr/share/ovmf/OVMF.fd \
     -kernel zig-out/baremetal/zig-kernel \
     -initrd initramfs.cpio \
     -nographic
   ```

## Next Steps

1. Implement `boot.zig` bare-metal additions (GDT/IDT/paging)
2. Create `qemu/` directory with ARM64 variant for aarch64
3. Add CI workflow using Omarchy's QEMU container image
4. Port e1000 loopback test to bare-metal verification

## References

- vinix: `kernel/modules/syscall/` and `kernel/modules/x86/`
- zig-kernel: `src/arch/x86_64/boot.zig`, `linker.ld`
- Omarchy: `waku-os/board/waku/qemu/`, `configs/waku_qemu_x86_64_defconfig`
- QEMU docs: `support/scripts/boot-qemu-image.py`