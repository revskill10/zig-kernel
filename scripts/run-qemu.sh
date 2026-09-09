#!/usr/bin/env bash
# QEMU runner for zig-kernel
# Usage: ./scripts/run-qemu.sh [options]
# Options:
#   -n, --no-display    Run headless (for CI)
#   -k, --kvm           Use KVM accelerator
#   -m, --memory N      Memory in MiB (default: 512)
#   -c, --cpus N        CPU count (default: 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${KERNEL:-${SCRIPT_DIR}/../zig-out/bin/zku}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.fd}"
OVMF_VARS="${OVMF_VARS:-/tmp/zku-ovmf-vars.fd}"

# Check for kernel binary (zku or zig-kernel)
if [[ ! -f "$KERNEL" ]]; then
    if [[ -f "${SCRIPT_DIR}/../zig-out/bin/zig-kernel" ]]; then
        KERNEL="${SCRIPT_DIR}/../zig-out/bin/zig-kernel"
    fi
fi

# Create OVMF_VARS if not exists
if [[ ! -f "$OVMF_VARS" ]]; then
    if [[ -f /usr/share/OVMF/OVMF_VARS.fd ]]; then
        cp /usr/share/OVMF/OVMF_VARS.fd "$OVMF_VARS"
    else
        # Copy from bundled firmware if available
        BUNDLED_VARS="${SCRIPT_DIR}/../roms/OVMF_VARS.fd"
        if [[ -f "$BUNDLED_VARS" ]]; then
            cp "$BUNDLED_VARS" "$OVMF_VARS"
        fi
    fi
fi

# Parse arguments
NO_DISPLAY=false
USE_KVM=false
MEMORY=512
CPUS=2

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--no-display)
            NO_DISPLAY=true
            shift
            ;;
        -k|--kvm)
            USE_KVM=true
            shift
            ;;
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -c|--cpus)
            CPUS="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            shift
            ;;
    esac
done

# Check kernel exists
if [[ ! -f "$KERNEL" ]]; then
    echo "Error: Kernel not found at $KERNEL"
    echo "Run 'zig build qemu' first"
    exit 1
fi

# Check OVMF firmware
if [[ ! -f "$OVMF_CODE" ]]; then
    echo "Warning: OVMF firmware not found at $OVMF_CODE"
    echo "Falling back to BIOS boot..."
fi

# Build QEMU command
QEMU_CMD="qemu-system-x86_64"

# Check KVM availability
if [[ "$USE_KVM" == true ]]; then
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        ACCELERATOR="kvm"
    else
        echo "Warning: KVM requested but not available, falling back to TCG"
        ACCELERATOR="tcg"
    fi
else
    ACCELERATOR="tcg"
fi

# Display and serial settings
if [[ "$NO_DISPLAY" == true ]]; then
    DISPLAY_ARGS=("-display" "none")
    SERIAL_ARGS=("-serial" "mon:stdio")
else
    DISPLAY_ARGS=("-display" "gtk,gl=on")
    SERIAL_ARGS=("-serial" "stdio")
fi

# Build QEMU arguments
ARGS=(
    -machine "q35,accel=${ACCELERATOR}"
    -cpu "host"
    -smp "$CPUS"
    -m "$MEMORY"
)

# Add UEFI if available
if [[ -f "$OVMF_CODE" ]]; then
    QEMU_FIRMWARE_DIR="$(dirname "$OVMF_CODE")"
    ARGS+=(
        -L "$QEMU_FIRMWARE_DIR"
        -bios "$OVMF_CODE"
        -drive "if=pflash,format=raw,unit=0,file=${OVMF_CODE},readonly=on"
        -drive "if=pflash,format=raw,unit=1,file=${OVMF_VARS}"
    )
fi

# Add kernel
ARGS+=(
    -kernel "$KERNEL"
    -append "console=ttyS0 loglevel=7"
    "${DISPLAY_ARGS[@]}"
    "${SERIAL_ARGS[@]}"
    -no-reboot
)

# Execute
echo "Running zig-kernel in QEMU..."
echo "Kernel: $KERNEL"
echo "Memory: ${MEMORY}MiB, CPUs: ${CPUS}, Accelerator: ${ACCELERATOR}"
exec "$QEMU_CMD" "${ARGS[@]}"