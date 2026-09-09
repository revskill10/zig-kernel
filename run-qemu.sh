#!/bin/bash
# QEMU runner script for zig-kernel bare-metal testing
# Usage: ./run-qemu.sh [x86_64|aarch64]

set -e

ARCH=${1:-x86_64}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_DIR="$SCRIPT_DIR"

echo "=== zig-kernel QEMU Runner ==="
echo "Building for architecture: $ARCH"

# Build flags
if [ "$ARCH" = "aarch64" ]; then
    TARGET="aarch64-linux-gnu"
    QEMU_CMD="qemu-system-aarch64"
    MACHINE="virt"
    CPU="cortex-a57"
else
    TARGET="x86_64-linux-gnu"
    QEMU_CMD="qemu-system-x86_64"
    MACHINE="q35"
    CPU="qemu64"
fi

# Check for cross-compiler
if ! command -v "$TARGET-gcc" &> /dev/null; then
    echo "Warning: $TARGET-gcc not found, using hosted execution"
    echo "For QEMU bare-metal, install: apt install gcc-$TARGET g++-$TARGET"
    
    echo "=== Running hosted simulation instead ==="
    cd "$KERNEL_DIR"
    zig build run
    exit 0
fi

# Build kernel for target
echo "Building kernel..."
cd "$KERNEL_DIR"

# Create bare-metal build
zig build -Dtarget="$ARCH-linux-gnu" -Doptimize=ReleaseFast

# Find the kernel binary
KERNEL_BIN="$KERNEL_DIR/zig-out/bin/zig-kernel"
if [ ! -f "$KERNEL_BIN" ]; then
    # Try alternate location
    KERNEL_BIN=$(find "$KERNEL_DIR/zig-out" -name "kernel" -type f 2>/dev/null | head -1)
fi

if [ ! -f "$KERNEL_BIN" ]; then
    echo "Error: Kernel binary not found"
    echo "Build output:"
    ls -la "$KERNEL_DIR/zig-out/" 2>/dev/null || echo "No zig-out directory"
    exit 1
fi

echo "Kernel binary: $KERNEL_BIN"

# Create initramfs if not present
INITRAMFS="$KERNEL_DIR/initramfs.cpio.gz"
if [ ! -f "$INITRAMFS" ]; then
    echo "Creating minimal initramfs..."
    mkdir -p /tmp/initramfs-root
    echo "Hello from zig-kernel QEMU!" > /tmp/initramfs-root/hello.txt
    echo "Kernel booted successfully at $(date)" > /tmp/initramfs-root/boot.log
    
    cd /tmp/initramfs-root
    find . | cpio -o -H newc | gzip > "$INITRAMFS"
    cd "$KERNEL_DIR"
    echo "Initramfs created: $INITRAMFS"
fi

# Run QEMU
echo ""
echo "Starting QEMU ($ARCH)..."
echo "Press Ctrl+A then X to exit"
echo ""

$QEMU_CMD \
    -kernel "$KERNEL_BIN" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0,115200 root=/dev/ram0 rw quiet" \
    -machine "$MACHINE" \
    -cpu "$CPU" \
    -smp 1 \
    -m 512M \
    -nographic \
    -no-reboot \
    -serial mon:stdio \
    -display none

echo ""
echo "QEMU session ended"