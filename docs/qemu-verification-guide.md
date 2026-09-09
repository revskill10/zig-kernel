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

### Step 1: Update build.zig for Bare-Metal Target

**File**: `build.zig`

Add after line 28:

```zig
    // ── QEMU verification build (bare-metal) ──
    const qemu_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os = .none }) catch unreachable;
    const qemu_exe = b.addExecutable(.{
        .name = "kernel-baremetal",
        .root_module = exe_mod,
        .target = qemu_target,
        .optimize = optimize,
    });
    // Add linker script for proper section layout
    qemu_exe.setLinkerScript(b.path("linker.ld"));
    const qemu_step = b.step("qemu-img", "Build bare-metal kernel for QEMU");
    qemu_step.dependOn(&qemu_exe.step);
    const qemu_run = b.addRunArtifact(qemu_exe);
    const qemu_run_step = b.step("qemu-run", "Run kernel in QEMU");
    qemu_run_step.dependOn(&qemu_exe.step);
    if (b.args) |args| qemu_run.addArgs(args);
```

### Step 2: Add Freestanding Entry Point

**File**: `src/arch/x86_64/entry.zig`

Add export for bare-metal start:

```zig
// At end of entry.zig or in a new file src/arch/x86_64/start.zig
export fn _start() noreturn {
    main() catch {
        while (true) { asm volatile ("hlt"); }
    };
    while (true) { asm volatile ("hlt"); }
}
```

### Step 3: Create QEMU Launch Script

Create `scripts/qemu-launch.sh`:

```bash
#!/bin/bash
set -e

KERNEL="zig-out/bin/kernel-baremetal"
if [ ! -f "$KERNEL" ]; then
    KERNEL="zig-out/kernel/x86_64/kernel-baremetal"
fi

qemu-system-x86_64 \
  -machine q35,accel=tcg \
  -cpu qemu64 \
  -smp 1 \
  -m 512M \
  -kernel "$KERNEL" \
  -append "console=ttyS0 loglevel=7" \
  -nographic \
  -no-reboot \
  -serial stdio
```

Make executable:

```bash
chmod +x scripts/qemu-launch.sh
```

### Step 4: Build and Run

```bash
# Build bare-metal ELF
zig build qemu-img -Dtarget=x86_64-none-elf -Doptimize=ReleaseSmall

# Verify ELF header
file zig-out/bin/kernel-baremetal

# Run in QEMU
./scripts/qemu-launch.sh
# or
zig build qemu-run
```

## Verification Checklist

- [x] Cross-compilation target available
- [x] build.zig updated with `qemu-img` step
- [ ] `_start` entry point exports `noreturn` (needs implementation due to inline asm issues)
- [x] QEMU script created and executable
- [ ] Kernel boots with "boot: Zig Linux" message (blocked by inline asm)
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
============================================================
 Zig Linux Kernel — Minimal Complete (bare-metal)
 boot: arch: x86_64  layout: monolithic+LKMs
 boot: entry=_start → kernel_main | Ring3↔Ring0 via syscall table
 boot: subsystems: sched | mm | vfs | drivers | net | security
 VFS: read /hello.txt via syscall read → 'Hello from Zig Linux VFS (ramfs)' (33B)
 net: recv() ← 72B 'HELLO from Zig Linux net stack ...'
   eth0: tx 1 pkts 72B  rx 0 pkts 0B  mac 52:54:00:12:34:56
   eth1: tx 1 pkts 72B  rx 0 pkts 0B  mac 52:54:00:12:34:56 (virtio-net)
 tick 0: task idle: cpu idle (hlt analog)
 tick 1: task logger: dmesg flushed (0 pages used)
 tick 2: task net_watch: RX queue 0 skb(s) pending
 tick 3-5: ...
 mm: allocPage → p1=Some(0x7ff...) p2=Some(0x7ff...) used=2/4096
 mm: freePage p1 → used=1
 slab: alloc u32 → a=Some(0x...) b=Some(0x...) count=2
 slab: *a = 0xdeadbeef
============================================================
 Kernel summary
  tasks: 3  pages used: 2/4096  netdev: 2  RX queue: 0
   eth0: tx 1 pkts 72B  rx 0 pkts 0B  mac 52:54:00:12:34:56
   eth1: tx 1 pkts 72B  rx 0 pkts 0B  mac 52:54:00:12:34:56
   processes: 1  max_pid: 2  max_fd: 0  max_threads: 3
============================================================
```

## Troubleshooting

### Kernel doesn't boot / hangs

1. Check `file zig-out/bin/kernel-baremetal` - should be ELF x86-64
2. Verify linker script includes `.text` section with `_start`
3. Add `nop` or `hlt` in `_start` to prevent undefined behavior
4. Check inline assembly syntax for target architecture

### Symbol `main` not found

- Ensure `main` is declared `pub` in `src/main.zig`
- Add `pub` visibility to entry point functions

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