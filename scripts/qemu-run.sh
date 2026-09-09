#!/bin/bash
# QEMU verification runner for zig-kernel bare-metal testing
# Compatible with Omarchy Waku OS QEMU profile style

set -e

KERNEL="${KERNEL:-zig-out/baremetal/zig-kernel-bm}"
INITRAMFS="${INITRAMFS:-initramfs.cpio}"
SERIAL_LOG="${SERIAL_LOG:-/tmp/zig-kernel-qemu.log}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Build bare-metal kernel if needed
if [ ! -f "$KERNEL" ]; then
    log_info "Building bare-metal kernel..."
    if ! command -v zig &> /dev/null; then
        log_err "Zig compiler not found. Please install Zig 0.16+"
        exit 1
    fi
    zig build -Dtarget=x86_64-freestanding -Doptimize=ReleaseSmall || {
        log_err "Build failed"
        exit 1
    }
fi

# Create initramfs if needed
if [ ! -f "$INITRAMFS" ]; then
    log_info "Creating initramfs..."
    INIT_DIR=$(mktemp -d)
    trap "rm -rf $INIT_DIR" EXIT
    
    mkdir -p "$INIT_DIR"/{proc,sys,dev}
    echo "Hello from Zig Linux VFS (ramfs)" > "$INIT_DIR/hello.txt"
    
    # Create device nodes
    [ -e "$INIT_DIR/dev/console" ] || mknod "$INIT_DIR/dev/console" c 5 0 2>/dev/null || true
    [ -e "$INIT_DIR/dev/null" ] || mknod "$INIT_DIR/dev/null" c 1 3 2>/dev/null || true
    [ -e "$INIT_DIR/dev/zero" ] || mknod "$INIT_DIR/dev/zero" c 1 5 2>/dev/null || true
    
    # Pack as cpio (newc format)
    cd "$INIT_DIR"
    find . | cpio -o -H newc > "$INITRAMFS"
    cd - > /dev/null
    log_info "Initramfs created: $INITRAMFS"
fi

# Detect QEMU
QEMU=qemu-system-x86_64
if ! command -v $QEMU &> /dev/null; then
    log_err "QEMU not found. Install: sudo apt-get install qemu-system-x86"
    exit 1
fi

log_info "Starting QEMU (serial log: $SERIAL_LOG)..."
log_info "Machine: q35, 512MB RAM, 1 vCPU"

# Run QEMU with configuration matching Omarchy profile
$QEMU \
    -machine q35,accel=tcg \
    -cpu qemu64 \
    -smp 1 \
    -m 512 \
    -kernel "$KERNEL" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0,115200 loglevel=debug" \
    -nographic \
    -no-reboot \
    -serial file:"$SERIAL_LOG" \
    -serial stdio \
    -d guest_errors \
    -no-shutdown

# Check results
if [ -f "$SERIAL_LOG" ]; then
    log_info "QEMU completed. Serial output:"
    cat "$SERIAL_LOG"
fi

# Look for expected output markers
if grep -q "Kernel summary" "$SERIAL_LOG" 2>/dev/null; then
    log_info "✓ Kernel completed successfully"
    exit 0
else
    log_err "Kernel did not complete expected output"
    exit 1
fi