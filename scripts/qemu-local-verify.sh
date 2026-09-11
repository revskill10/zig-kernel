#!/bin/bash
# Local QEMU verification (WSL) — mirrors CI truth gates without burning Actions minutes.
# Preconditions: kernel built via `zig build qemu-bin -Doptimize=ReleaseSmall`, initramfs via scripts/create-initramfs.sh
cd "$(dirname "$0")/.."
KERNEL_BIN=zig-out/bin/kernel-baremetal
test -f "$KERNEL_BIN" || { echo "run: zig build qemu-bin -Doptimize=ReleaseSmall first"; exit 1; }
if [ ! -f initramfs.cpio ]; then bash ./scripts/create-initramfs.sh; fi
echo "=== local QEMU run (nic none, iobase=0xf4) ==="
timeout 60 qemu-system-x86_64 \
  -kernel "$KERNEL_BIN" \
  -initrd initramfs.cpio \
  -append "console=ttyS0 loglevel=8" \
  -nographic -serial mon:stdio -m 256M -cpu qemu64 -smp 2 \
  -nic none \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
  -no-reboot -display none > qemu-output.log 2>&1
EC=$?
echo "QEMU_EC=$EC"
tail -20 qemu-output.log
# Truth gates (same as CI):
grep -q "Zig Linux Kernel" qemu-output.log || { echo "FAIL: no kernel banner"; exit 1; }
grep -q "hello.txt"        qemu-output.log || { echo "FAIL: VFS not working"; exit 1; }
grep -q "Demo complete"    qemu-output.log || { echo "FAIL: demos incomplete"; exit 1; }
grep -q "KERNEL_HALT"      qemu-output.log || { echo "FAIL: no halt"; exit 1; }
if [ "$EC" -eq 3 ]; then echo "VERDICT_LOCAL_QEMU_POWER_OFF_OK (exit 3 = kernel-requested isa-debug-exit)"; exit 0; fi
if [ "$EC" -eq 124 ]; then echo "VERDICT_WATCHDOG_FAIL — power-off path broken"; exit 124; fi
echo "VERDICT_UNEXPECTED_EC=$EC"; exit "$EC"
