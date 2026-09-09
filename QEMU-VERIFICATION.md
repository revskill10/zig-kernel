# QEMU Verification Guide for zig-kernel

## Overview

This guide explains how to verify zig-kernel using QEMU virtualization. Currently, zig-kernel is built as a **hosted simulation** that runs natively on Windows/Linux. For bare-metal QEMU verification, additional build targets are required.

## Current State

**Hosted Simulation (Ready)**
```bash
cd zig-kernel
zig build run    # Runs as native executable
zig build test   # Runs unit tests
```

**Bare-metal Target (In Progress)**
To run in QEMU as a proper kernel image, we are implementing a freestanding build target.

## QEMU Setup

### 1. Build Configuration for Bare-Metal

Create a freestanding build target by modifying `build.zig`:

```zig
pub fn build(b: *std.Build) void {
    // Add bare-metal target
    const bare_metal = b.resolveTargetQuery(.{
        .cpu_arch = "x86_64",
        .os = "freestanding",
        .abi = "none",
    }) catch return;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main_baremetal.zig"),
        .target = bare_metal,
        .optimize = .ReleaseHost,
    });

    const exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = exe_mod,
        .target = bare_metal,
        .optimize = .ReleaseHost,
    });

    // Output as ELF
    exe.setOutputDir(".zig-out/kernel");
    b.installArtifact(exe);
}
```

### 2. Bare-Metal Entry Point

Create `src/main_baremetal.zig`:

```zig
// Bare-metal entry point for QEMU verification
const std = @import("std");
const boot = @import("arch/x86_64/boot_baremetal.zig");
const entry = @import("arch/x86_64/entry.zig");

// Import all kernel modules (same as main.zig)
const printk = @import("lib/printk.zig");
const mm = @import("mm/mm.zig");
// ... other imports ...

// Bare-metal entry - replaces hosted main()
export fn _start_baremetal() void {
    // Assembly entry point would call this
    boot.baremetal_init();
    kmain();
}

fn kmain() void {
    // Initialize boot structures
    boot.baremetal_init();
    
    // Rest of kernel initialization (same as hosted)
    mm.init();
    // ... same initialization as main.zig ...
}
```

### 3. Bare-Metal Boot (arch/x86_64/boot_baremetal.zig)

```zig
pub fn baremetal_init() void {
    // GDT setup for QEMU
    setup_gdt();
    
    // IDT setup (32 entries for interrupts)
    setup_idt();
    
    // Enable paging (identity map kernel space)
    enable_paging();
}

fn setup_gdt() void {
    // 512-byte GDT with null, code, data segments
    asm volatile (
        "\\\\lgdt %0"
        :
        : "m" (gdt_descriptor)
        : "memory"
    );
}
```

## QEMU Command Line

### Omarchy-style QEMU invocation

Based on Omarchy's `waku-qemu-bios-diagnostic.sh`:

```bash
#!/bin/bash
# qemu-build.sh - Build kernel for QEMU

KERNEL="zig-out/kernel/kernel.elf"
INITRD="initramfs.cpio.gz"

# Build with freestanding target
zig build -Dtarget=x86_64-freestanding-none -Doptimize=ReleaseFast

# Run in QEMU
qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "console=ttyS0,115200 root=/dev/ram0 rw" \
    -m 512M \
    -nographic \
    -no-reboot \
    -serial mon:stdio
```

### Configuration from Omarchy Waku OS

| Setting | Omarchy Value | zig-kernel Adaptation |
|---------|---------------|----------------------|
| Machine | q35 | pc (or q35) |
| CPU | qemu64 | qemu64 or host |
| Memory | 512M | 512M |
| Boot | cdrom | kernel |
| Console | ttyS0@115200 | same |

## Comparison: Omarchy vs zig-kernel QEMU Setup

| Aspect | Omarchy Waku OS | zig-kernel |
|--------|-----------------|------------|
| Build System | Buildroot | Zig Build |
| Kernel | Linux 6.18.7 | Custom Zig (hosted sim → bare-metal) |
| Target | ELF binary via Buildroot | Direct Zig cross-compilation |
| Initramfs | Built-in rootfs | Needs custom initramfs |
| Storage | ISO9660 | Kernel image + optional initramfs |
| Bootloader | GRUB2 | None (direct kernel load) |
| Testing | Full desktop environment | Kernel subsystems test |

## Running Tests in QEMU

1. Build bare-metal kernel
2. Create test initramfs with `/hello.txt` and test programs
3. Boot with console output captured

Expected output:
```
VFS: read /hello.txt via syscall read → 'Hello from Zig Linux VFS (ramfs)' (33B)
net: recv() ← 72B 'HELLO from Zig Linux net stack ...'
```

## Infrastructure Delta

Based on Omarchy analysis:

```
Hosted simulation → Bare-metal additions:
├── arch/x86_64/boot_baremetal.zig  (+GDT/IDT setup)
├── linker.ld modifications (entry point)
├── build.zig cross-compilation target
├── memory paging initialization (PML4)
└── stack setup (no RTS/RSP in hosted)
```

**Delta size: ~80-100 lines** (as documented in README.md)

## Verification Checklist

- [ ] `zig build -Dtarget=x86_64-freestanding-none` compiles
- [ ] Kernel boots in QEMU without error
- [ ] Serial output captured
- [ ] VFS test: `/hello.txt` readable
- [ ] Network test: socket loopback works
- [ ] Scheduler runs 6+ ticks
- [ ] Memory subsystem allocates pages

## Next Steps

1. Implement bare-metal boot infrastructure
2. Create initramfs with test files
3. Add CI workflow for automated QEMU testing
4. Verify against vinix reference implementation

## Current Progress (as of 2026-09-09)

- [x] Hosted simulation build and test working
- [x] Bare-metal build target defined in build.zig
- [x] Linker script updated for bare-metal ELF
- [x] Bare-metal entry point `_start_baremetal` exported
- [x] GDT/IDT boot infrastructure implemented in `boot_baremetal.zig`
- [ ] Bare-metal kernel (`main_baremetal.zig`) initialization in progress
- [ ] QEMU launch script created
- [ ] Initial QEMU boot testing pending

**Note**: The bare-metal build currently encounters compiler errors with inline assembly syntax that are being resolved. The core infrastructure is in place.