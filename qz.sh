#!/bin/bash
# qz.sh — Quick QEMU verification for zig-kernel
# Usage: ./qz.sh [test] [run] [boot]
#
# This script provides QEMU-based verification aligned with
# the Waku OS / Omarchy approach from vendor/omarchy/waku-os/waku-os

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default settings (mirror Omarchy QEMU settings)
QEMU_CPUS=${QEMU_CPUS:-1}
QEMU_MEMORY_MIB=${QEMU_MEMORY_MIB:-256}
QEMU_TIMEOUT=${QEMU_TIMEOUT:-30}
QEMU_ACCEL=${QEMU_ACCEL:-tcg}  # tcg or kvm

# Detect QEMU binary
detect_qemu() {
    if command -v qemu-system-x86_64 &> /dev/null; then
        echo "qemu-system-x86_64"
    elif [ -x "./zig-out/bin/zu" ]; then
        echo "qemu-system-x86_64"
    else
        echo "error: QEMU not found. Install with: sudo apt install qemu-system-x86" >&2
        exit 1
    fi
}

QEMU_BIN=$(detect_qemu)

# Build for QEMU
build_qemu() {
    echo -e "${YELLOW}Building kernel for QEMU...${NC}"
    zig build qemu-bin -Doptimize=ReleaseSmall 2>&1 || zig build -Doptimize=ReleaseSmall 2>&1 || {
        echo -e "${RED}Build failed${NC}"
        return 1
    }
    echo -e "${GREEN}Build successful${NC}"
}

# Run quick verification test
test_qemu() {
    echo -e "${YELLOW}Running QEMU verification test...${NC}"
    
    local kernel_bin=""
    if [ -x "./zig-out/bin/zu" ]; then
        kernel_bin="./zig-out/bin/zu"
    elif [ -x "./zig-out/bin/zig-kernel" ]; then
        kernel_bin="./zig-out/bin/zig-kernel"
    else
        echo -e "${RED}Error: No QEMU binary found. Run './build' or 'make qemu-x86_64' first.${NC}" >&2
        return 1
    fi
    
    local log_file="qemu-test.log"
    rm -f "$log_file"
    
    # Run QEMU with serial to file (mirrors Omarchy approach)
    timeout "$QEMU_TIMEOUT" "$QEMU_BIN" \
        -machine q35,accel="$QEMU_ACCEL" \
        -cpu max \
        -smp "$QEMU_CPUS" \
        -m "$QEMU_MEMORY_MIB" \
        -kernel "$kernel_bin" \
        -serial file:"$log_file" \
        -display none \
        -no-reboot 2>/dev/null || true
    
    echo "=== QEMU Serial Output ==="
    cat "$log_file" 2>/dev/null || echo "(no output)"
    
    # Verification checks
    echo ""
    echo "=== Verification Summary ==="
    
    local passed=0
    local failed=0
    
    # Check 1: Kernel booted
    if grep -q "boot:" "$log_file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Kernel boot sequence visible"
        ((passed++))
    else
        echo -e "${RED}✗${NC} Kernel boot sequence not found"
        ((failed++))
    fi
    
    # Check 2: VFS initialized
    if grep -q "VFS:" "$log_file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} VFS initialized"
        ((passed++))
    else
        echo -e "${RED}✗${NC} VFS not initialized"
        ((failed++))
    fi
    
    # Check 3: Scheduler started
    if grep -q "sched:" "$log_file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Scheduler started"
        ((passed++))
    else
        echo -e "${RED}✗${NC} Scheduler not started"
        ((failed++))
    fi
    
    # Check 4: Memory management
    if grep -q "mm:" "$log_file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Memory management initialized"
        ((passed++))
    else
        echo -e "${RED}✗${NC} Memory management not visible"
        ((failed++))
    fi
    
    # Check 5: Network ready
    if grep -q "net:" "$log_file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Network stack initialized"
        ((passed++))
    else
        echo -e "${RED}✗${NC} Network stack not initialized"
        ((failed++))
    fi
    
    echo ""
    echo "Passed: $passed / $((passed + failed))"
    
    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}All QEMU verification tests passed!${NC}"
        return 0
    else
        echo -e "${RED}QEMU verification tests failed${NC}"
        return 1
    fi
}

# Run full kernel (interactive)
run_qemu() {
    echo -e "${YELLOW}Starting QEMU with kernel...${NC}"
    echo "Accelerator: $QEMU_ACCEL | CPUs: $QEMU_CPUS | Memory: ${QEMU_MEMORY_MIB}MiB"
    
    local kernel_bin=""
    if [ -x "./zig-out/bin/ku" ]; then
        kernel_bin="./zig-out/bin/ku"
    elif [ -x "./zig-out/bin/zig-kernel" ]; then
        kernel_bin="./zig-out/bin/zig-kernel"
    else
        build_qemu
        kernel_bin="./zig-out/bin/ku"
    fi
    
    "$QEMU_BIN" \
        -machine q35,accel="$QEMU_ACCEL" \
        -cpu max \
        -smp "$QEMU_CPUS" \
        -m "$QEMU_MEMORY_MIB" \
        -kernel "$kernel_bin" \
        -serial mon:stdio \
        -display none \
        -no-reboot
}

# Run with network (user networking, mirrors Omarchy)
run_qemu_network() {
    echo -e "${YELLOW}Starting QEMU with network...${NC}"
    
    local kernel_bin=""
    if [ -x "./zig-out/bin/ku" ]; then
        kernel_bin="./zig-out/bin/ku"
    elif [ -x "./zig-out/bin/zig-kernel" ]; then
        kernel_bin="./zig-out/bin/zig-kernel"
    else
        build_qemu
        kernel_bin="./zig-out/bin/ku"
    fi
    
    "$QEMU_BIN" \
        -machine q35,accel="$QEMU_ACCEL" \
        -cpu max \
        -smp 1 \
        -m 256 \
        -kernel "$kernel_bin" \
        -netdev user,id=net0,net=192.168.123.0/24,hostfwd=tcp::20128-:20128 \
        -device virtio-net-pci,netdev=net0 \
        -serial stdio \
        -display none \
        -no-reboot
}

# Boot receipt test (mirrors Omarchy test-boot)
boot_receipt() {
    local run_id="qemu-boot-$(date -u +%Y%m%dT%H%M%SZ)"
    local boot_dir="output/qemu/$run_id"
    
    echo -e "${YELLOW}Running boot verification (receipt-style)...${NC}"
    
    mkdir -p "$boot_dir"
    
    local kernel_bin=""
    if [ -x "./zig-out/bin/ku" ]; then
        kernel_bin="./zig-out/bin/ku"
    elif [ -x "./zig-out/bin/zig-kernel" ]; then
        kernel_bin="./zig-out/bin/zig-kernel"
    else
        build_qemu
        kernel_bin="./zig-out/bin/ku"
    fi
    
    local log="$boot_dir/serial.log"
    local started_ns=$(date +%s%N)
    
    "$QEMU_BIN" \
        -machine q35,accel="$QEMU_ACCEL" \
        -cpu max \
        -smp 1 \
        -m 128 \
        -kernel "$kernel_bin" \
        -serial file:"$log" \
        -display none \
        -no-reboot &
    
    local pid=$!
    local ready=0
    
    # Poll for successful boot
    while kill -0 "$pid" 2>/dev/null; do
        if [ -f "$log" ] && grep -q "Demo complete" "$log"; then
            ready=1
            break
        fi
        sleep 0.1
    done
    
    wait "$pid" 2>/dev/null || true
    
    local ended_ns=$(date +%s%N)
    local mount_ms=$(( (ended_ns - started_ns) / 1000000 ))
    
    if [ $ready -eq 1 ]; then
        # Create receipt
        cat > "$boot_dir/receipt.json" << EOF
{
  "schemaVersion": 2,
  "profile": "qemu-verify",
  "machine": "q35",
  "accelerator": "$QEMU_ACCEL",
  "cpus": 1,
  "memoryMiB": 128,
  "network": "none",
  "bootMs": $mount_ms,
  "status": "passed"
}
EOF
        echo -e "${GREEN}✓ Boot verification passed (${mount_ms}ms)${NC}"
        echo "Receipt: $boot_dir/receipt.json"
        return 0
    else
        echo -e "${RED}✗ Boot verification failed${NC}"
        echo "Log: $log"
        return 1
    fi
}

# Show help
help() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  build           Build kernel for QEMU"
    echo "  test            Run QEMU verification tests"
    echo "  run             Run QEMU interactively"
    echo "  network         Run QEMU with user networking"
    echo "  boot-receipt    Run boot verification with receipt"
    echo "  all             Run build + test (default)"
    echo ""
    echo "Environment variables (default in parentheses):"
    echo "  QEMU_CPUS=${QEMU_CPUS:-1}"
    echo "  QEMU_MEMORY_MIB=${QEMU_MEMORY_MIB:-256}"
    echo "  QEMU_TIMEOUT=${QEMU_TIMEOUT:-30}"
    echo "  QEMU_ACCEL=${QEMU_ACCEL:-tcg}"
}

# Main
case "${1:-all}" in
    build)
        build_qemu
        ;;
    test)
        test_qemu
        ;;
    run)
        run_qemu
        ;;
    network)
        run_qemu_network
        ;;
    boot-receipt)
        boot_receipt
        ;;
    all|"")
        build_qemu && test_qemu
        ;;
    help|--help|-h)
        help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}" >&2
        help
        exit 1
        ;;
esac