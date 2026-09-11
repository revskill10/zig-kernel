#!/bin/bash
# release-gate.sh — Minimal reproducible local production gate for sandbox qualification.
# Rule: Must be run from the repository root in a WSL environment with Zig available via Windows PATH.
# Exit 0 = all gates passed (local production qualification met).
# Exit 1 = missing kernel artifact or build failure.
# Exit 2 = environment-gated (KVM not usable, not a fail).
# Exit 3 = qualification failed (kernel ran but missing truth gates or wrong exit).
# Exit 124 = watchdog (QEMU stayed alive too long, power-off path broken).

# NB: no `set -e` — timeout(1) intentionally returns 124 (watchdog) and QEMU
# returns 3 (isa-debug-exit power-off); both are handled explicitly below.
set -uo pipefail

cd "$(dirname "$0")/.."

RECEIPT=release-gate-receipt.txt
: > "$RECEIPT"
log() { echo "$@" | tee -a "$RECEIPT"; }

# Linked worktrees with Windows gitdir paths are unreadable under WSL;
# callers may export RELEASE_GATE_COMMIT (exact Windows-side HEAD) instead.
COMMIT="${RELEASE_GATE_COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"

log "=== Production Sandbox Qualification Gate ==="
log "Working directory: $(pwd)"
log "Commit: $COMMIT"

# --- Gate 0: Kernel artifact -------------------------------------------------
KERNEL_BIN=zig-out/bin/kernel-baremetal
if [ ! -f "$KERNEL_BIN" ]; then
    log "Building kernel baremetal artifact (release small)..."
    # Use the Windows zig.exe via PATH (assuming we are in WSL and can call /mnt/c/... or zig.exe is in PATH)
    # We'll try to call zig.exe directly; if not found, we'll try the typical location.
    if ! command -v zig.exe &> /dev/null; then
        if [ -x "/mnt/c/Users/$(whoami)/scoop/shims/zig.exe" ]; then
            ZIG="/mnt/c/Users/$(whoami)/scoop/shims/zig.exe"
        elif [ -x "/mnt/c/Program Files/zig/zig.exe" ]; then
            ZIG="/mnt/c/Program Files/zig/zig.exe"
        else
            log "ERROR: zig.exe not found in PATH or typical locations. Please ensure Zig 0.16.0 is installed and accessible from WSL."
            exit 1
        fi
    else
        ZIG=zig.exe
    fi
    "$ZIG" build qemu-bin -Doptimize=ReleaseSmall || { log "VERDICT_FAIL: kernel build failed"; exit 1; }
fi
log "ARTIFACT: $KERNEL_BIN"

# --- Gate 1: Environment must provide KVM -----------------------------------
if [ ! -e /dev/kvm ]; then
    log "VERDICT_ENV_GATED: /dev/kvm absent — KVM qualification cannot run (not a pass)"
    exit 2
fi
if [ ! -r /dev/kvm ]; then
    log "VERDICT_ENV_GATED: /dev/kvm not readable — add user to kvm group (not a pass)"
    exit 2
fi
log "ENV: /dev/kvm present and readable"

# --- Gate 2: QEMU must accept hardware accel, fail hard otherwise -----------
QEMU_VERSION=$(qemu-system-x86_64 --version | head -1)
log "ENV: $QEMU_VERSION"
# QEMU with -accel kvm -S (paused) must stay alive until the timeout kills it.
# Exit 124 = process alive under hardware accel = healthy.
timeout 5 qemu-system-x86_64 -accel kvm -machine none -display none -S >/dev/null 2>&1
PROBE_EC=$?
if [ "$PROBE_EC" -ne 124 ]; then
    log "VERDICT_ENV_GATED: -accel kvm probe exited $PROBE_EC before watchdog — QEMU cannot use hardware KVM here (not a pass)"
    exit 2
fi
log "ENV: -accel kvm probe OK (hardware acceleration functional, stayed alive 5s)"

# --- Gate 3: Artifact provenance --------------------------------------------
log "ARTIFACT: $KERNEL_BIN"
log "COMMIT: $COMMIT"

# --- Gate 4: Ensure initramfs exists ----------------------------------------
if [ ! -f initramfs.cpio ]; then
    log "Building initramfs..."
    bash ./scripts/create-initramfs.sh || { log "VERDICT_FAIL: initramfs build failed"; exit 1; }
fi

# --- Gate 5: Run under explicit -accel kvm (no fallback) --------------------
log "RUN: qemu-system-x86_64 -accel kvm -nic none -no-reboot"
timeout 60 qemu-system-x86_64 \
    -accel kvm \
    -kernel "$KERNEL_BIN" \
    -initrd initramfs.cpio \
    -append "console=ttyS0 loglevel=8" \
    -nographic -serial mon:stdio -m 256M -cpu host -smp 2 \
    -nic none \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -no-reboot -display none > qemu-gate-output.log 2>&1
EC=$?
log "QEMU_EC: $EC"

# --- Gate 6: Truth gates (identical to CI/qemu-kvm-qualify.sh) --------------
GATES=0
grep -q "Zig Linux Kernel" qemu-gate-output.log && GATES=$((GATES+1)) || log "MISS: kernel banner"
grep -q "hello.txt" qemu-gate-output.log && GATES=$((GATES+1)) || log "MISS: VFS read"
grep -q "Demo complete" qemu-gate-output.log && GATES=$((GATES+1)) || log "MISS: demos"
grep -q "KERNEL_HALT" qemu-gate-output.log && GATES=$((GATES+1)) || log "MISS: halt"

log "GATES: $GATES/4"

if [ "$EC" -eq 3 ] && [ "$GATES" -eq 4 ]; then
    log "VERDICT_QUALIFIED: booted, demos, halt, power-off exit 3 under hardware KVM"
    exit 0
fi
if [ "$EC" -eq 124 ]; then
    log "VERDICT_WATCHDOG_FAIL: power-off path broken under KVM"
    exit 124
fi
log "VERDICT_FAIL: EC=$EC GATES=$GATES/4"
exit 1