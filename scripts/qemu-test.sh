#!/usr/bin/env bash
# Fail-closed wrapper for the CI QEMU boot gate used by make qemu-test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p zig-out
LOG=zig-out/qemu-output.log

echo "=== Running kernel in QEMU headless mode ==="
timeout 60 bash ./scripts/qemu-x86_64.sh 2>&1 | tee "$LOG"
statuses=("${PIPESTATUS[@]}")
runner_status="${statuses[0]:-1}"
tee_status="${statuses[1]:-1}"

if [[ "$tee_status" -ne 0 ]]; then
    echo "❌ Failed to capture QEMU output" >&2
    exit "$tee_status"
fi
if [[ "$runner_status" -eq 124 ]]; then
    echo "❌ QEMU test timed out" >&2
    exit 124
fi
# isa-debug-exit returns 3 when the kernel requests a clean shutdown.
if [[ "$runner_status" -ne 0 && "$runner_status" -ne 3 ]]; then
    echo "❌ QEMU failed with exit $runner_status" >&2
    exit "$runner_status"
fi

for marker in "Zig Linux Kernel" "hello.txt" "Demo complete"; do
    if ! grep -Fq "$marker" "$LOG"; then
        echo "❌ Missing QEMU marker: $marker" >&2
        exit 1
    fi
done
if ! grep -Eq "KERNEL_HALT|Kernel alive - hlt loop" "$LOG"; then
    echo "❌ Missing QEMU halt marker" >&2
    exit 1
fi

echo "✅ QEMU test PASSED"
