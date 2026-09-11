#!/bin/bash
# qemu-kvm-qualify.sh — fail-closed KVM sandbox qualification (Q1/Q2).
# Rule 4 (linux-sandbox-qualification): acceleration is asserted, never silently
# degraded to TCG. Exit 2 = environment-gated (NOT a pass). Exit 0 = verified
# under hardware KVM on the exact recorded commit.
set -u
cd "$(dirname "$0")/.."

RECEIPT=qemu-kvm-receipt.txt
: > "$RECEIPT"
log() { echo "$@" | tee -a "$RECEIPT"; }

# --- Gate 1: environment must provide KVM -----------------------------------
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
# Any earlier exit means KVM init failed (env-gated, not a pass).
timeout 5 qemu-system-x86_64 -accel kvm -machine none -display none -S >/dev/null 2>&1
PROBE_EC=$?
if [ "$PROBE_EC" -ne 124 ]; then
    log "VERDICT_ENV_GATED: -accel kvm probe exited $PROBE_EC before watchdog — QEMU cannot use hardware KVM here (not a pass)"
    exit 2
fi
log "ENV: -accel kvm probe OK (hardware acceleration functional, stayed alive 5s)"

# --- Gate 3: artifact provenance ---------------------------------------------
KERNEL_BIN=zig-out/bin/kernel-baremetal
test -f "$KERNEL_BIN" || { log "VERDICT_FAIL: run 'zig build qemu-bin -Doptimize=ReleaseSmall' first"; exit 1; }
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
log "ARTIFACT: $KERNEL_BIN"
log "COMMIT: $COMMIT"

if [ ! -f initramfs.cpio ]; then
    bash ./scripts/create-initramfs.sh || { log "VERDICT_FAIL: initramfs build failed"; exit 1; }
fi

# --- Gate 4: run under explicit -accel kvm (no fallback) ---------------------
log "RUN: qemu-system-x86_64 -accel kvm -nic none -no-reboot"
timeout 60 qemu-system-x86_64 \
    -accel kvm \
    -kernel "$KERNEL_BIN" \
    -initrd initramfs.cpio \
    -append "console=ttyS0 loglevel=8" \
    -nographic -serial mon:stdio -m 256M -cpu host -smp 2 \
    -nic none \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -no-reboot -display none > qemu-kvm-output.log 2>&1
EC=$?
log "QEMU_EC: $EC"

# --- Gate 5: truth gates (identical to CI) -----------------------------------
GATES=0
grep -q "Zig Linux Kernel" qemu-kvm-output.log && GATES=$((GATES+1)) || log "MISS: kernel banner"
grep -q "hello.txt"        qemu-kvm-output.log && GATES=$((GATES+1)) || log "MISS: VFS read"
grep -q "Demo complete"    qemu-kvm-output.log && GATES=$((GATES+1)) || log "MISS: demos"
grep -q "KERNEL_HALT"      qemu-kvm-output.log && GATES=$((GATES+1)) || log "MISS: halt"

if [ "$EC" -eq 3 ] && [ "$GATES" -eq 4 ]; then
    log "VERDICT_KVM_QUALIFIED: booted, demos, halt, power-off exit 3 under hardware KVM"
    exit 0
fi
if [ "$EC" -eq 124 ]; then
    log "VERDICT_WATCHDOG_FAIL: power-off path broken under KVM"
    exit 124
fi
log "VERDICT_FAIL: EC=$EC GATES=$GATES/4"
exit 1
