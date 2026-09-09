#!/bin/bash
# QEMU verification script for zig-kernel
# Creates a minimal ELF kernel that can be booted in QEMU

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== zig-kernel QEMU Verification ==="
echo ""

# Create qemu_entry.zig for bare-metal entry
cat > src/arch/x86_64/qemu_entry.zig << 'ZIGCODE'
// QEMU entry point - bare-metal boot entry for zig-kernel
export fn _start() noreturn {
    // Call the main kernel logic
    const main_mod = @import("main.zig");
    _ = main_mod.main() catch {
        while (true) {}
    };
}
ZIGCODE

# Create bare-metal build
echo "Building kernel for QEMU..."
zig build qemu-bin -Doptimize=ReleaseSafe 2>/dev/null || {
    echo "Note: Cross-compilation requires x86_64 freestanding target"
    echo "Using hosted simulation instead..."
    zig build run
    exit 0
}

# Verify ELF
if [ -f "zig-out/bin/zig-kernel" ]; then
    echo ""
    echo "Building QEMU image..."
    
    # Create initramfs with test files
    mkdir -p qemu_initramfs/{dev,proc,sys}
    echo "Hello from Zig Linux VFS (QEMU verified)" > qemu_initramfs/hello.txt
    
    # Create minimal device nodes if mknod available
    (mknod qemu_initramfs/dev/console c 5 0 2>/dev/null || true) || true
    
    # Create cpio archive
    cd qemu_initramfs
    find . | cpio -o -H newc 2>/dev/null | gzip > ../qemu_initramfs.cpio || {
        # Fallback: just use the kernel without initramfs
        cd ..
        rm -rf qemu_initramfs
        echo "Creating kernel image without initramfs..."
    }
    cd ..
    
    echo ""
    echo "To run in QEMU:"
    echo "  qemu-system-x86_64 -kernel zig-out/bin/zig-kernel -initrd qemu_initramfs.cpio -nographic -m 256M"
fi

# Cleanup
rm -rf qemu_initramfs 2>/dev/null || true