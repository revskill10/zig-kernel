# zig-kernel vs Omarchy: QEMU Verification Comparison

## Executive Summary

| Aspect | zig-kernel | Omarchy (Waku OS) |
|--------|------------|-------------------|
| **Build System** | Zig 0.16.0 native | Buildroot 2026.05.2 |
| **Kernel** | Custom Zig (hosted sim → bare-metal ready) | Linux 6.18.7 LTS |
| **Target** | Bare-metal ELF | Bare-metal bzImage |
| **Build Output** | `zig-out/kernel/{arch}/kernel` | `output/images/rootfs.iso9660` |
| **QEMU Profile** | Manual scripts | Buildroot config |
| **Network Driver** | e1000 simulation | virtio-net |
| **Boot Method** | Direct kernel | GRUB2 |

## QEMU Infrastructure Comparison

### Omarchy QEMU Configuration

**File**: `waku-os/board/waku/qemu/grub.cfg`
```cfg
linux __KERNEL_PATH__ root=/dev/sr0 rootwait rootfstype=iso9660 ro loglevel=6 earlyprintk=serial,ttyS0,115200 console=tty0 console=ttyS0,115200 systemd.show_status=auto
```

**File**: `waku-os/board/waku/qemu/linux.fragment` (Kernel Config Fragment)
```cfg
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_NET=y
CONFIG_E1000=y  (if enabled)
```

**File**: `waku-qemu-bios-diagnostic.sh` (Launch Script)
```bash
qemu-system-x86_64 \
  -L "$firmware_dir" \
  -machine q35,accel=tcg \
  -cpu qemu64 \
  -smp 1 \
  -m 512 \
  -boot order=d,menu=off \
  -cdrom "$iso" \
  -nographic \
  -no-reboot
```

### zig-kernel QEMU Configuration

**File**: `scripts/qemu-launch.sh`
```bash
qemu-system-x86_64 \
  -machine q35,accel=tcg \
  -cpu qemu64 \
  -smp 1 \
  -m 512M \
  -kernel zig-out/kernel/x86_64/kernel \
  -append "console=ttyS0 loglevel=7" \
  -nographic \
  -no-reboot
```

**Key Integration Points from Omarchy**:

1. **Serial Console Setup** (shared pattern):
   - Both use `console=ttyS0` for serial output
   - Both use `-nographic` for headless testing

2. **Network Configuration**:
   - Omarchy: virtio-net with TAP networking
   - zig-kernel: e1000 simulation (ring buffer loopback)

3. **Boot Receipt Pattern**:
   - Omarchy generates `receipt.json` with boot metrics
   - zig-kernel uses kernel summary output with structured metrics

## Build Integration Points

### From Omarchy to zig-kernel

1. **Firmware Directory** (OVMF/EDK2 support):
   ```bash
   # Omarchy uses BIOS firmware directory
   -L "$output/host/share/qemu"
   ```

2. **Gateway Proxy Pattern**:
   - File: `waku-os/scripts/qemu-gateway-proxy.py`
   - Pattern: Bridge TCP/UDP from host to guest for testing
   - zig-kernel alternative: Direct loopback via e1000 descriptors

3. **Kernel Config Fragments**:
   - Omarchy uses `.fragment` files for kernel config
   - zig-kernel equivalent: Compile-time options in build.zig

### QEMU Network Testing Strategy

| Feature | Omarchy | zig-kernel |
|---------|---------|------------|
| Network Backend | TAP (Linux), User (macOS/Windows) | User networking (simulation) |
| Device Model | virtio-net | e1000 (Intel) |
| Test Pattern | socketpair loopback | descriptor ring loopback |
| Verification | systemd-networkd logs | printk/netif_rx counters |

## Comparison Matrix

| Feature | zig-kernel | Omarchy | Notes |
|---------|------------|---------|-------|
| **Syscall Table** | 66 entries | Linux 6.18 | vinix parity achieved |
| **Process Management** | sched.Task (Zig) | struct task_struct | Same architecture |
| **Memory Management** | mm.Page/Slab (Zig) | struct mm_struct | Same design |
| **Network Stack** | net_core + e1000 | Linux netstack + virtio | Different implementation |
| **File System** | ramfs/vfs (Zig) | ext4/tmpfs/vfs | Similar VFS layer |
| **Security** | capabilities (Zig) | SELinux/LSM | Simplified caps model |
| **Boot** | Direct ELF | GRUB2 | Two-stage vs single-stage |

## Verification Commands

### Omarchy (from waku-qemu-bios-diagnostic.sh)
```bash
timeout 45s qemu-system-x86_64 \
  -L /usr/share/qemu \
  -machine q35,accel=tcg \
  -cpu qemu64 \
  -smp 1 \
  -m 512 \
  -boot order=d,menu=off \
  -cdrom images/rootfs.iso9660 \
  -nographic \
  -no-reboot
```

### zig-kernel (new workflow)
```bash
# Build
zig build qemu-img -Dtarget=x86_64-linux-gnu

# Run
zig build qemu-run -Dtarget=x86_64-linux-gnu

# Or use script
./scripts/qemu-launch.sh x86_64
```

## Next Steps

1. **Bare-metal boot extensions**: Add GDT/IDT/paging to `boot.zig`
2. **AHCI/Block driver**: Add storage support for initramfs
3. **ACPI/FDT parsing**: For memory map and SMP discovery
4. **More drivers**: virtio-net for realistic network I/O

## References

- [Omarchy QEMU Profile](./board/waku/qemu/)
- [Waku OS Buildroot Config](./configs/waku_qemu_x86_64_defconfig)
- [zink-kernel QEMU Guide](./docs/qemu-verification-guide.md)