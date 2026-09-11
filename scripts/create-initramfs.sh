#!/bin/bash
# scripts/create-initramfs.sh - Create initramfs for QEMU kernel testing
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

INITRAMFS_DIR="initramfs"
INITRAMFS_FILE="initramfs.cpio"

echo "[initramfs] Creating test filesystem..."

# Clean up previous build
rm -rf "$INITRAMFS_DIR"
rm -f "$INITRAMFS_FILE"

# Create directory structure
mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,tmp}

# Create test file
cat > "$INITRAMFS_DIR/hello.txt" << 'EOF'
Hello from Zig Linux VFS (QEMU verified)
EOF

# Create minimal device nodes
mknod "$INITRAMFS_DIR/dev/null" c 1 3 2>/dev/null || true
mknod "$INITRAMFS_DIR/dev/zero" c 1 5 2>/dev/null || true
chmod 666 "$INITRAMFS_DIR/dev/null" 2>/dev/null || true
chmod 666 "$INITRAMFS_DIR/dev/zero" 2>/dev/null || true

# Create init script
cat > "$INITRAMFS_DIR/init" << 'INITEOF'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo "[init] Zig kernel initialized in QEMU"

# Run the kernel binary if available (for standalone testing)
if [ -x /kernel ]; then
    exec /kernel
fi

# Otherwise just sleep to keep QEMU running
exec sleep 3600
INITEOF
chmod +x "$INITRAMFS_DIR/init"

# Build initramfs CPIO archive
cd "$INITRAMFS_DIR"
find . | cpio -o -H newc 2>/dev/null > "../$INITRAMFS_FILE"
cd ..

echo "[initramfs] Created $INITRAMFS_FILE ($(stat -c%s "$INITRAMFS_FILE") bytes)"
