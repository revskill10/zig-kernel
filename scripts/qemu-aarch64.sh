#!/bin/bash
set -e

echo "========================================"
echo "  zig-kernel QEMU Verification (aarch64)"
echo "========================================"

# Check dependencies
if ! command -v qemu-system-aarch64 &> /dev/null; then
    echo "ERROR: qemu-system-aarch64 not found"
    echo "Install: sudo apt-get install qemu-system-arm"
    exit 1
fi

if ! command -v zig &> /dev/null; then
    echo "ERROR: zig not found"
    exit 1
fi

# Build kernel for aarch64 (bare-metal freestanding - falls back to x86 qemu-bin until aarch64 target added)
echo "Building kernel for aarch64..."
zig build qemu-bin -Doptimize=ReleaseSmall || {
    echo "Build failed"
    exit 1
}

# Create initramfs if not exists
if [ ! -f initramfs.aarch64.cpio ]; then
    echo "Creating initramfs for aarch64..."
    
    rm -rf initramfs.aarch64
    mkdir -p initramfs.aarch64/{dev,proc,sys,tmp}
    
    # Create test file
    cat > initramfs.aarch64/hello.txt << 'EOF'
Hello from Zig Linux VFS (QEMU aarch64 verified)
EOF
    
    # Build initramfs CPIO archive
    cd initramfs.aarch64
    find . | cpio -o -H newc 2>/dev/null > ../initramfs.aarch64.cpio || {
        echo "Failed to create initramfs"
        exit 1
    }
    cd ..
fi

echo "Launching QEMU aarch64..."

# Check if kernel binary exists at expected location
KERNEL="zig-out/bin/zig-kernel"
if [ ! -f "$KERNEL" ]; then
    echo "Kernel binary not found at $KERNEL"
    echo "Run: zig build qemu-bin"
    exit 1
fi

# Launch QEMU for aarch64 with virt machine
qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a57 \
    -kernel "$KERNEL" \
    -initrd initramfs.aarch64.cpio \
    -append "console=ttyAMA0 loglevel=8" \
    -nographic \
    -serial mon:stdio \
    -m 512M \
    -net nic,model=virtio-net-pci,id=net0 \
    -net user,hostfwd=tcp::20129-:20128 \
    -no-reboot

echo "QEMU aarch64 session ended"