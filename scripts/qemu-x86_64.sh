#!/bin/bash
set -e

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "========================================"
echo "  zig-kernel QEMU Verification (x86_64)"
echo "========================================"

# Check dependencies
if ! command -v qemu-system-x86_64 &> /dev/null; then
    echo -e "${RED}ERROR: qemu-system-x86_64 not found${NC}"
    echo "Install: sudo apt-get install qemu-system-x86"
    exit 1
fi

if ! command -v zig &> /dev/null; then
    echo -e "${RED}ERROR: zig not found${NC}"
    exit 1
fi

# Build kernel as ELF for QEMU (bare-metal freestanding)
echo -e "${GREEN}Building kernel for QEMU...${NC}"
zig build qemu-bin -Doptimize=ReleaseSmall || {
    echo -e "${RED}Build failed${NC}"
    exit 1
}
# Resolve kernel binary (bare-metal vs hosted fallback)
KERNEL_BIN="zig-out/bin/kernel-baremetal"
if [ ! -f "$KERNEL_BIN" ]; then
    KERNEL_BIN="zig-out/bin/zig-kernel"
fi

# Create initramfs if not exists
if [ ! -f initramfs.cpio ]; then
    echo -e "${GREEN}Creating initramfs...${NC}"
    
    rm -rf initramfs
    mkdir -p initramfs/{dev,proc,sys,bin,sbin,etc,lib,usr/{bin,lib},tmp}
    
    # Create test file
    cat > initramfs/hello.txt << 'EOF'
Hello from Zig Linux VFS (QEMU verified)
EOF
    
    # Create minimal device nodes
    mknod initramfs/dev/null c 1 3 2>/dev/null || true
    chmod 666 initramfs/dev/null 2>/dev/null || true
    
    # Create test program placeholder
    cat > initramfs/test-kernel << 'TESTEOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "Zig kernel booted in QEMU"
echo "PID: $(cat /proc/1/status | grep PID | awk '{print $2}')"
TESTEOF
    chmod +x initramfs/test-kernel
    
    # Build initramfs CPIO archive
    cd initramfs
    find . | cpio -o -H newc 2>/dev/null > ../initramfs.cpio || {
        echo -e "${RED}Failed to create initramfs${NC}"
        exit 1
    }
    cd ..
fi

echo -e "${GREEN}Launching QEMU...${NC}"
echo "========================================"

# Launch QEMU with serial monitor
qemu-system-x86_64 \
    -kernel "$KERNEL_BIN" \
    -initrd initramfs.cpio \
    -append "console=ttyS0 loglevel=8" \
    -nographic \
    -serial mon:stdio \
    -m 256M \
    -cpu qemu64 \
    -smp 2 \
    -net nic,model=e1000,id=net0 \
    -net user,hostfwd=tcp::20128-:20128 \
    -no-reboot \
    -display none

echo "========================================"
echo -e "${GREEN}QEMU session ended${NC}"