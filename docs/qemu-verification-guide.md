# QEMU Verification Workflow for Zig Kernel

## Quick Summary

**Current State**: Hosted simulation is fully functional (all demos pass). Bare-metal QEMU verification is in progress; inline assembly syntax issues in baremetal.zig are under investigation. Virtio-net driver has been implemented and tested in hosted simulation.

**Goal**: Enable bare-metal QEMU testing for zig-kernel with both e1000 and virtio-net drivers.

## Prerequisites

### 1. Cross-Compilation Toolchain

Zig includes built-in cross-compilation. For x86_64-linux-gnu target:

```bash
# Verify target availability
zig targets | grep "x86_64-linux-gnu"

# Expected output should include freestanding support
```

### 2. QEMU Installation

```bash
# Linux
sudo apt install qemu-system-x86

# macOS (via Homebrew)
brew install qemu

# Windows
choco install qemu
```

## Implementation Steps

### Step 1: Verify build.zig for Bare-Metal Target

**File**: `build.zig`

The build.zig already includes a bare-metal build step for QEMU verification:

```zig
    // Bare-metal build for QEMU verification
    // Usage: zig build qemu-bin            (defaults to freestanding x86_64)
    //    or: zig build qemu-bin -Dtarget=x86_64-freestanding-none -Doptimize=ReleaseSmall
    const bare_target_query: std.Target.Query = .{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
    };
    const bare_target = b.resolveTargetQuery(bare_target_query);

    const bare_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/baremetal.zig"),
        .target = bare_target,
        .optimize = .ReleaseSmall,
    });

    const bare_exe = b.addExecutable(.{
        .name = "kernel-baremetal",
        .root_module = bare_exe_mod,
    });

    bare_exe.setLinkerScript(b.path("linker.ld"));

    const qemu_bin_step = b.step("qemu-bin", "Build bare-metal kernel ELF for QEMU");
    qemu_bin_step.dependOn(&bare_exe.step);
```

The existing bare-metal target is configured for x86 freestanding (32-bit) and produces `kernel-baremetal` in `zig-out/bin/`.

### Step 2: Verify Freestanding Entry Point

**File**: `src/baremetal.zig`

The bare-metal entry point already exists in `src/baremetal.zig` with:
- `_start` function as the ELF entry point (exported)
- Serial port initialization and output
- Kernel main function that initializes subsystems and enters hlt loop
- Uses x86 inline assembly for port I/O

### Step 3: Verify/Create QEMU Launch Script

Check for existing script: `scripts/run-qemu.sh`

The `scripts/run-qemu.sh` script already exists and provides QEMU launching capability. It:
- Builds for x86_64 or aarch64 targets
- Checks for cross-compiler availability
- Creates initramfs if needed
- Launches QEMU with appropriate parameters

Make it executable if not already:
```bash
chmod +x scripts/run-qemu.sh
```

### Step 4: Build and Run

```bash
# Build bare-metal ELF (x86 freestanding, 32-bit)
zig build qemu-bin

# Verify ELF header (using alternative to 'file' command on Windows)
# The ELF magic bytes should be 7f 45 4c 46
# We can check with: [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes("zig-out/bin/kernel-baremetal")[0..3])

# Run in QEMU using the existing script
.\scripts\run-qemu.sh x86_64

# For aarch64 (if cross-compiler available)
.\scripts\run-qemu.sh aarch64
```

## Verification Checklist

- [x] Cross-compilation target available
- [x] build.zig updated with `qemu-bin` step
- [x] `_start` entry point exports `noreturn` (in baremetal.zig)
- [x] QEMU script created and executable
- [ ] Kernel boots with "Booting zig-kernel bare-metal (x86 freestanding)..." message (blocked by inline asm)
- [x] Hosted simulation boots with all demos (VFS, network, scheduler, MM)
- [x] e1000 driver verified in hosted simulation (loopback test passes)
- [x] virtio-net driver implemented and verified in hosted simulation (loopback test passes)
- [ ] Serial console output visible in QEMU (blocked by inline asm)
- [ ] VFS demo completes (ramfs read) in QEMU (blocked by inline asm)
- [ ] Network loopback test passes (e1000 xmit→netif_rx) in QEMU (blocked by inline asm)

## Omarchy Integration Notes

### Similarities

| Feature | Omarchy | zig-kernel |
|---------|---------|------------|
| Console | ttyS0 | ttyS0 |
| QEMU machine | q35 | q35 |
| Memory | 512M | 512M |

### Differences

| Feature | Omarchy | zig-kernel |
|---------|---------|------------|
| Kernel type | Linux bzImage | Custom ELF |
| Boot method | GRUB2 | Direct kernel |
| Network | virtio-net | e1000 (simulated), virtio-net (simulated) |
| Init system | systemd | Native tasks |

### Key Files from Omarchy

- `omarchy/waku-os/board/waku/qemu/grub.cfg` - Boot config pattern
- `omarchy/waku-os/scripts/qemu-gateway-proxy.py` - Network proxy (optional)
- `omarchy/.tmp/waku-qemu-bios-diagnostic.sh` - Launch script template

## Expected QEMU Output (when bare-metal build succeeds)

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

## Troubleshooting

### Kernel doesn't boot / hangs

1. Check that `zig-out/bin/kernel-baremetal` exists and is not empty
2. Verify linker script includes `.text` section with `_start`
3. Check inline assembly syntax for target architecture (known issue in baremetal.zig for Zig 0.16.0)
4. Ensure QEMU is properly installed and in PATH

### Symbol `main` not found

- The baremetal.zig does not depend on `main.zig`; it is standalone
- Ensure `main` is declared `pub` in `src/main.zig` for hosted simulation
- Add `pub` visibility to entry point functions if needed

### Network loopback fails

- Verify `skbuff` pool initialized
- Check `E1000Regs` or `VirtioRegs` memory-mapped simulation
- Ensure descriptor ring filling in `e1000_open` or `virtio_net_open`
- Confirm interrupt simulation works

## References

- `docs/architecture.md` - Layered structure diagram
- `docs/driver-guide.md` - e1000 end-to-end
- `docs/virtio-net-guide.md` - virtio-net end-to-end (to be created)
- `omarchy/waku-os/board/waku/qemu/` - Omarchy QEMU profile
- `omarchy/waku-os/output/.qemu-x86_64.staging/` - Built QEMU layout