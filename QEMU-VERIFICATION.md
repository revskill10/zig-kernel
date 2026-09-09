# QEMU Verification Guide for zig-kernel

## Overview

This guide explains how to verify zig-kernel using QEMU virtualization. 
zig-kernel now includes a **bare-metal build target** that produces a 32-bit ELF executable 
suitable for loading via QEMU's `-kernel` option (direct boot, no bootloader required).

## Current State

**Hosted Simulation (Ready)**
```bash
cd zig-kernel
zig build run    # Runs as native executable
zig build test   # Runs unit tests
```

**Bare-metal Target (Ready for QEMU)**
```bash
# Build bare-metal kernel ELF
zig build qemu-bin

# Verify ELF properties (see ELF Verification section below)
# Run in QEMU (if QEMU is installed):
#   ./run-qemu.sh x86_64
```

## ELF Verification

The bare-metal build produces a valid 32-bit ELF executable:

- **Magic**: 7F 45 4C 46 (ELF)
- **Class**: 32-bit
- **Data**: LSB (Little Endian)
- **Version**: 1 (current)
- **OS ABI**: 0 (System V)
- **ABI Version**: 0
- **Type**: Executable (2)
- **Machine**: Intel 80386 (3)
- **Entry point**: 0x00100034 (matches linker script . = 0x100000 + _start offset)

This matches the expectations for a bare-metal x86 kernel loaded by QEMU at 0x100000.

## QEMU Setup

### 1. Build Configuration for Bare-Metal

The build.zig already includes a bare-metal target:
```bash
zig build qemu-bin          # Builds kernel-baremetal ELF
# Or explicitly:
zig build -Dtarget=x86_64-freestanding-none -Doptimize=ReleaseFast
```

### 2. Bare-Metal Entry Point

The entry point is in `src/baremetal.zig`:
- `_start` naked function sets up stack and calls `kmain`
- `kmain` initializes serial and enters hlt loop
- Serial configured on COM1 (0x3F8) for QEMU stdio output

### 3. Linker Script

`linker.ld` configures the ELF for direct load:
```ld
OUTPUT_FORMAT(elf32-i386)
ENTRY(_start)
SECTIONS
{
  . = 0x100000;  /* QEMU -kernel loads at 1MB */
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) *(COMMON) }
}
```

## QEMU Command Line

### Using the provided script

```bash
./run-qemu.sh x86_64
```

### Manual QEMU invocation

```bash
qemu-system-x86_64 \
    -kernel zig-out/bin/kernel-baremetal \
    -initrd initramfs.cpio.gz \
    -append "console=ttyS0,115200 root=/dev/ram0 rw" \
    -m 512M \
    -nographic \
    -no-reboot \
    -serial mon:stdio
```

### Create initramfs for testing

```bash
mkdir -p /tmp/initramfs-root
echo "Hello from zig-kernel QEMU!" > /tmp/initramfs-root/hello.txt
echo "Kernel booted successfully at $(date)" > /tmp/initramfs-root/boot.log
cd /tmp/initramfs-root
find . | cpio -o -H newc | gzip > initramfs.cpio.gz
```

## Expected Output in QEMU

When booted, you should see:
```
Booting zig-kernel bare-metal (x86 freestanding)...
arch: x86  layout: monolithic  zig: 0.16.0
subsystems: sched | mm | vfs | drivers | net | security
serial: COM1 0x3F8 ready
e1000: simulated NIC eth0 mac 52:54:00:12:34:56
virtio_net: simulated NIC eth1 mac 52:54:00:AB:CD:EF
VFS: ramfs /hello.txt ready
Kernel alive - hlt loop. Power off via QEMU monitor.
```

## Infrastructure Delta

Compared to hosted simulation, bare-metal adds:
- `src/baremetal.zig` (_start assembly, serial init, hlt loop)
- `linker.ld` (ELF format, entry point, load address)
- Build target in `build.zig` (qemu-bin step)
- No runtime dependency on hosted environment (no std.exe.args, etc.)

## Verification Checklist

- [x] `zig build qemu-bin` compiles successfully
- [x] ELF binary produced and verified (32-bit LSB executable)
- [x] Entry point matches linker script (_start at 0x100034)
- [x] Serial initialization code present
- [ ] QEMU boot test (requires QEMU installation)
- [ ] Serial output capture in QEMU
- [ ] VFS test: `/hello.txt` readable via syscall
- [ ] Network test: socket loopback works
- [ ] Scheduler runs (would see timer ticks if implemented)
- [ ] Memory subsystem allocates pages

## Next Steps

1. Install QEMU to complete end-to-end verification
2. Test serial output and initramfs loading
3. Implement interrupt handling (beyond hlt loop) for real testing
4. Add automated QEMU testing to CI workflow
5. Verify against vinix reference implementation

## Current Progress (as of 2026-09-09)

- [x] Hosted simulation build and test working
- [x] Bare-metal build target defined in build.zig
- [x] Linker script updated for bare-metal ELF
- [x] Bare-metal entry point `_start` exported
- [x] Serial infrastructure implemented in `baremetal.zig`
- [x] ELF binary verification completed
- [ ] QEMU launch script tested (requires QEMU install)
- [ ] Initial QEMU boot testing pending

**Note**: The bare-metal build and ELF verification are complete. 
QEMU testing is pending QEMU installation on the host system.