"""Anchored native first-slice serial transcript checks.

One boot, exact marker tokens, ordered stages, exactly one terminal
`ZKN: exit code=10` after `ZKN: done`. Explicit loader/kernel failures
cannot pass. A legitimate extra `ZKL: map-frozen` after ExitBootServices
retry is allowed. This is not a Linux-replacement or full-desktop proof.
"""
from __future__ import annotations

import re

MARKERS = [
    "ZKL: start", "ZKL: kernel-loaded", "ZKL: initramfs-loaded", "ZKL: map-frozen",
    "ZKL: ebs-ok", "ZKN: entry", "ZKN: bootinfo-ok", "ZKN: serial-ok",
    "ZKN: gdt-ok", "ZKN: idt-ok", "ZKN: paging-ok", "ZKN: pmm-ok",
    "ZKN: trap-ud2-ok", "ZKN: trap-pf-unmapped-ok", "ZKN: trap-pf-ro-write-ok",
    "ZKN: trap-pf-nx-exec-ok", "ZKN: timer-ok", "ZKN: done",
]

FAILURE = re.compile(
    r"^ZKL: fail(?:[ \t]|$)|^ZKN: (?:PANIC|FAULT|bootinfo-invalid)(?:[ \t]|$)"
)


def parse_serial(serial):
    """One boot, exact marker tokens, ordered stages and one final success exit."""
    lines = serial.splitlines()
    patterns = [re.compile(r"^" + re.escape(marker) + r"(?:[ \t].*)?$") for marker in MARKERS]
    seen = [0] * len(MARKERS)
    cursor = 0
    errors = []
    exit_lines = []
    for number, line in enumerate(lines, 1):
        if FAILURE.match(line):
            errors.append(f"Explicit native failure at line {number}: {line}")
        if line.startswith("ZKN: exit"):
            exit_lines.append((number, line))
            if line != "ZKN: exit code=10":
                errors.append(f"Contradictory or malformed native exit at line {number}: {line}")
            if cursor != len(MARKERS):
                errors.append(f"Native exit precedes completion at line {number}")
        for index, pattern in enumerate(patterns):
            if not pattern.fullmatch(line):
                continue
            seen[index] += 1
            # ExitBootServices can legitimately require another frozen map.
            retry_map = MARKERS[index] == "ZKL: map-frozen" and cursor == index + 1
            if index == cursor:
                cursor += 1
            elif not retry_map:
                errors.append(f"Duplicate/out-of-order native stage at line {number}: {line}")
            if exit_lines:
                errors.append(f"Native stage after terminal exit at line {number}: {line}")
            break
    if cursor != len(MARKERS):
        errors.append("Required native stages missing or out of order")
    if len(exit_lines) != 1:
        errors.append(f"Expected one terminal native exit marker, observed {len(exit_lines)}")
    return {
        "kernel_entry_observed": seen[MARKERS.index("ZKN: entry")] > 0,
        "markers": [{"marker": marker, "observed_count": seen[index]}
                    for index, marker in enumerate(MARKERS)],
        "terminal_exit_markers": [{"line": n, "text": line} for n, line in exit_lines],
        "transcript_errors": errors,
    }
