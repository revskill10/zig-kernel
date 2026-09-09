#!/bin/bash
# QEMU launch script for zig-kernel bare-metal verification
# Mirrors pattern from: waku-os/board/waku/qemu/

set -e

# Configuration
ARCH="${1:-x86_64}"
QEMU="qemu-system-${ARCH}"
KERNEL="zig-out/bin/kernel"
KERNEL_PATH="zig-out/kernel/${ARCH}/kernel"

# Fallback paths
if [ ! -f "$KERNEL" ]; then
    KERNEL="$KERNEL_PATH"
fi

# Verify kernel exists
if [ ! -f "$KERNEL" ]; then
    echo "Error: Kernel not found at $KERNEL"
    echo "Run: zig build qemu-img -Dtarget=${ARCH}-linux-gnu"
    exit 1
fi

# QEMU invocation - based on waku-qemu-bios-diagnostic.sh pattern
echo "Starting QEMU with kernel: $KERNEL"

exec "$QEMU" \
  -machine q35,accel=tcg \
  -cpu qemu64 \
  -smp 1 \
  -m 512M \
  -kernel "$KERNEL" \
  -append "console=ttyS0 loglevel=7" \
  -nographic \
  -no-reboot \
  -serial stdio \
  "$@"