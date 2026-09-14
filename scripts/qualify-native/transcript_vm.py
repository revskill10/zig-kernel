"""Strict native-vm-probe-v1 serial grammar and semantic verifier.

The base bootstrap parser must still pass for a positive run. Extra unrelated
lines remain allowed by the base parser; this module rejects contradictory VM
lines, enforces cycle/stage order against N6/timer/exit, and checks numeric
fields. Parser mutation tests are not guest proof.
"""
from __future__ import annotations

import re

import transcript

PROFILE = "native-vm-probe-v1"
MODES = ("positive", "skip-switch", "writable-ro")
CYCLE_STAGES = (
    "control", "template", "construct", "walk",
    "switch", "content", "fault-ro", "fault-nx",
    "fault-guard", "fault-top", "restore", "absent", "destroy",
)
N6_MARKERS = transcript.MARKERS[:16]
N6_LAST = "ZKN: trap-pf-nx-exec-ok"
TIMER = "ZKN: timer-ok"
DONE = "ZKN: done"
EXIT_OK = "ZKN: exit code=10"
EXIT_VM = "ZKN: exit code=17"

FIXTURE_LEN = 5120
FIXTURE_SHA256 = {
    1: "b9b1c7085cc32a99ff7127d83f845525115f4d0c57d67566c2521fa9681486b9",
    2: "f2bb6508933e81ba28e67fe968508db2c6888681a508019c8935f1b663d6c447",
}
EXPECT_IMAGE = 4
EXPECT_STACK = 16
EXPECT_TABLES = 6
EXPECT_OWNED = 26
EXPECT_IMAGE_PTS = 2
EXPECT_STACK_PTS = 1
PHYS_TOP = 256 * 1024 * 1024
PAGE = 4096
KERNEL_LO = 0x200000
KERNEL_HI = 0x400000
FAULT_CR2 = {
    "fault-ro": 0x40202180,
    "fault-nx": 0x40204030,
    "fault-guard": 0x7FFED000,
    "fault-top": 0x7FFFE000,
    "absent": 0x401FF100,
}

FAILURE = re.compile(
    r"^ZKL: fail(?:[ \t]|$)|^ZKN: (?:PANIC|FAULT|bootinfo-invalid)(?:[ \t]|$)"
)
START_RE = re.compile(
    r"^ZKN: vm-start profile=native-vm-probe-v1 mode=(positive|skip-switch|writable-ro)$"
)
FIXTURE_RE = re.compile(
    r"^ZKN: vm-fixture cycle=([12]) len=([0-9]+) sha256=([0-9a-f]{64})$"
)
CYCLE_RE = re.compile(
    r"^ZKN: vm-cycle cycle=([12]) stage=([a-z0-9-]+)(?:[ \t]+(.*))?$"
)
COMPLETE_RE = re.compile(r"^ZKN: vm-complete cycles=2$")
FAIL_RE = re.compile(
    r"^ZKN: vm-fail cycle=([12]) stage=([a-z0-9-]+) reason=([a-z0-9-]+)$"
)
EXIT_RE = re.compile(r"^ZKN: exit code=([0-9a-f]+)$")
HEX16 = re.compile(r"^[0-9a-f]{16}$")

CONTROL_RE = re.compile(
    r"^cr3=([0-9a-f]{16}) rflags=([0-9a-f]{16}) cr0=([0-9a-f]{16}) "
    r"cr4=([0-9a-f]{16}) efer=([0-9a-f]{16}) "
    r"pmm-total=([0-9]+) pmm-free=([0-9]+) pmm-used=([0-9]+) "
    r"pmm-unmanaged=([0-9]+) pmm-excluded=([0-9]+)$"
)
TEMPLATE_RE = re.compile(r"^root=([0-9a-f]{16}) pdpt0=([0-9a-f]{16})$")
CONSTRUCT_RE = re.compile(
    r"^owned=([0-9]+) image=([0-9]+) stack=([0-9]+) tables=([0-9]+) root=([0-9a-f]{16})$"
)
WALK_RE = re.compile(
    r"^image-pts=([0-9]+) stack-pts=([0-9]+) "
    r"rx=([0-9a-f]{16}) rx1=([0-9a-f]{16}) ro=([0-9a-f]{16}) rw=([0-9a-f]{16})$"
)
SWITCH_RE = re.compile(r"^expected=([0-9a-f]{16}) observed=([0-9a-f]{16})$")
CONTENT_RE = re.compile(r"^fetch=0$")
FAULT_RE = re.compile(
    r"^vector=14 pfec=([0-9a-f]+) cr2=([0-9a-f]{16}) rip=([0-9a-f]{16}) gen=([0-9]+)$"
)
DESTROY_RE = re.compile(
    r"^owned=0 adapter=0 pmm-total=([0-9]+) pmm-free=([0-9]+) pmm-used=([0-9]+) "
    r"pmm-unmanaged=([0-9]+) pmm-excluded=([0-9]+)$"
)

CR3_ADDR = 0x000FFFFFFFFFF000
PTE_P = 1 << 0
PTE_U = 1 << 2
PTE_PS = 1 << 7
PTE_AD = (1 << 5) | (1 << 6)
CR0_WP = 1 << 16
CR4_LA57 = 1 << 12
CR4_PCIDE = 1 << 17
CR4_SMEP = 1 << 20
CR4_SMAP = 1 << 21
EFER_NXE = 1 << 11
RFLAGS_IF = 1 << 9
PFEC = {"fault-ro": 0x3, "fault-nx": 0x11, "fault-guard": 0, "fault-top": 0, "absent": 0}


def _kv_error(prefix, parsed, errors):
    if parsed is None:
        errors.append(prefix + " field mismatch")
        return None
    return parsed


def _frame_ok(value):
    return value != 0 and value % PAGE == 0 and value < PHYS_TOP


def _check_borrowed_pdpt(cycle, pdpt_entry, kernel_root, errors):
    if pdpt_entry & PTE_P == 0:
        errors.append("cycle %d borrowed PDPT is not present" % cycle)
    if pdpt_entry & PTE_U:
        errors.append("cycle %d borrowed PDPT is not supervisor" % cycle)
    if pdpt_entry & PTE_PS:
        errors.append("cycle %d borrowed PDPT is huge" % cycle)
    addr = pdpt_entry & CR3_ADDR
    if not _frame_ok(addr):
        errors.append("cycle %d borrowed PDPT address is not a domain-aligned frame" % cycle)
    elif kernel_root is not None and addr == kernel_root:
        errors.append("cycle %d borrowed PDPT aliases original root" % cycle)


def parse_vm_serial(serial, *, mode="positive"):
    """Verify VM evidence. `mode` is the expected artifact mode."""
    if mode not in MODES:
        return {
            "profile": PROFILE,
            "mode": mode,
            "vm_complete": False,
            "vm_fail": None,
            "cycles": [],
            "transcript_errors": ["unsupported VM mode %r" % (mode,)],
            "base": transcript.parse_serial(serial),
        }
    lines = serial.splitlines()
    errors = []
    base = transcript.parse_serial(serial)
    starts = []
    fixtures = []
    cycles = []
    completes = []
    fails = []
    exits = []
    n6_at = []
    timer_at = []
    done_at = []
    vm_line_numbers = []

    for number, line in enumerate(lines, 1):
        if FAILURE.match(line):
            errors.append("Explicit native failure at line %d: %s" % (number, line))
        if line.startswith("ZKN: vm-"):
            vm_line_numbers.append(number)
            if START_RE.fullmatch(line):
                starts.append((number, START_RE.fullmatch(line).group(1)))
            elif FIXTURE_RE.fullmatch(line):
                m = FIXTURE_RE.fullmatch(line)
                fixtures.append((number, int(m.group(1)), int(m.group(2)), m.group(3)))
            elif CYCLE_RE.fullmatch(line):
                m = CYCLE_RE.fullmatch(line)
                stage = m.group(2)
                if stage not in CYCLE_STAGES:
                    errors.append("Unknown VM stage %s at line %d" % (stage, number))
                cycles.append((number, int(m.group(1)), stage, m.group(3) or ""))
            elif COMPLETE_RE.fullmatch(line):
                completes.append(number)
            elif FAIL_RE.fullmatch(line):
                m = FAIL_RE.fullmatch(line)
                fails.append((number, int(m.group(1)), m.group(2), m.group(3)))
            else:
                errors.append("Malformed or spoofed VM marker at line %d: %s" % (number, line))
        if line == N6_LAST or line.startswith(N6_LAST + " "):
            n6_at.append(number)
        if line == TIMER or line.startswith(TIMER + " "):
            timer_at.append(number)
        if line == DONE:
            done_at.append(number)
        if line.startswith("ZKN: exit"):
            exits.append((number, line))

    if len(starts) != 1:
        errors.append("Expected one vm-start, observed %d" % len(starts))
    else:
        if starts[0][1] != mode:
            errors.append("vm-start mode %s does not match expected %s" % (starts[0][1], mode))

    if mode == "positive":
        errors.extend(base["transcript_errors"])
        if fails:
            errors.append("Positive transcript contains vm-fail")
        if len(completes) != 1:
            errors.append("Expected one vm-complete, observed %d" % len(completes))
        if len(exits) != 1 or exits[0][1] != EXIT_OK:
            errors.append("Positive VM run requires exactly one success exit code=10")
        _reject_vm_after_terminal(vm_line_numbers, completes, exits, errors)
        _check_positive_order(
            starts, fixtures, cycles, completes, n6_at, timer_at, done_at, exits, errors,
        )
        _check_cycle_semantics(fixtures, cycles, errors, require_full=True)
    else:
        if not base["transcript_errors"]:
            errors.append("Negative transcript passed the bootstrap parser")
        if completes:
            errors.append("Negative transcript contains vm-complete")
        if done_at:
            errors.append("Negative transcript contains ZKN: done")
        if timer_at:
            errors.append("Negative transcript contains timer-ok")
        if any(text == EXIT_OK for _, text in exits):
            errors.append("Negative transcript contains success exit")
        if len(fails) != 1:
            errors.append("Expected one vm-fail, observed %d" % len(fails))
        elif fails[0][1] != 1:
            errors.append("vm-fail cycle must be 1")
        if len(exits) != 1 or exits[0][1] != EXIT_VM:
            errors.append("Negative VM run requires exactly one exit code=17")
        if fails and exits and fails[0][0] > exits[0][0]:
            errors.append("vm-fail after terminal exit")
        expected_stage = "switch" if mode == "skip-switch" else "fault-ro"
        if fails:
            if fails[0][2] != expected_stage:
                errors.append("vm-fail stage %s does not match expected %s" % (fails[0][2], expected_stage))
            if mode == "skip-switch" and fails[0][3] != "cr3-readback":
                errors.append("skip-switch reason must be cr3-readback")
            if mode == "writable-ro" and fails[0][3] != "expected-pf":
                errors.append("writable-ro reason must be expected-pf")
        _check_n6_prefix(lines, starts, errors)
        _check_negative_sequence(mode, starts, fixtures, cycles, fails, exits, vm_line_numbers, errors)
        _check_cycle_semantics(fixtures, cycles, errors, require_full=False)

    return {
        "profile": PROFILE,
        "mode": mode,
        "vm_complete": len(completes) == 1 and not errors and mode == "positive",
        "vm_fail": None if not fails else {
            "cycle": fails[0][1], "stage": fails[0][2], "reason": fails[0][3],
        },
        "fixtures": [{"cycle": c, "len": n, "sha256": h} for _, c, n, h in fixtures],
        "cycles": [{"cycle": c, "stage": s, "fields": f} for _, c, s, f in cycles],
        "base": base,
        "transcript_errors": errors,
    }


def _reject_vm_after_terminal(vm_line_numbers, completes, exits, errors):
    limit = None
    if completes:
        limit = completes[0]
    if exits:
        limit = exits[0][0] if limit is None else min(limit, exits[0][0])
    if limit is None:
        return
    for n in vm_line_numbers:
        if n > limit:
            errors.append("VM marker after completion or terminal exit")
            return


def _check_positive_order(starts, fixtures, cycles, completes, n6_at, timer_at, done_at, exits, errors):
    if not (starts and completes and n6_at and timer_at and done_at and exits):
        errors.append("Positive VM order is missing N6, timer, done, or VM markers")
        return
    start_n = starts[0][0]
    complete_n = completes[0]
    n6_n = n6_at[-1]
    timer_n = timer_at[0]
    done_n = done_at[0]
    exit_n = exits[0][0]
    if start_n <= n6_n:
        errors.append("vm-start must follow the last N6 trap marker")
    if complete_n <= start_n:
        errors.append("vm-complete must follow vm-start")
    if timer_n <= complete_n:
        errors.append("vm-complete must precede timer-ok")
    if done_n <= timer_n:
        errors.append("done must follow timer-ok")
    if exit_n <= done_n:
        errors.append("success exit must follow done")
    for n, *_ in fixtures:
        if n <= start_n or n >= complete_n:
            errors.append("fixture outside start/complete window")
            break
    for n, *_ in cycles:
        if n <= start_n or n >= complete_n:
            errors.append("cycle marker outside start/complete window")
            break
    merged = []
    for n, c, _, _ in fixtures:
        merged.append((n, "fixture", c, None))
    for n, c, s, _ in cycles:
        merged.append((n, "stage", c, s))
    merged.sort(key=lambda item: item[0])
    want = []
    for c in (1, 2):
        want.append(("fixture", c, None))
        for s in CYCLE_STAGES:
            want.append(("stage", c, s))
    got = [(kind, c, s) for _, kind, c, s in merged]
    if got != want:
        errors.append("VM cycle/stage order mismatch")


def _check_n6_prefix(lines, starts, errors):
    if not starts:
        return
    start_n = starts[0][0]
    patterns = [
        re.compile(r"^" + re.escape(marker) + r"(?:[ \t].*)?$") for marker in N6_MARKERS
    ]
    cursor = 0
    last_n6 = 0
    for number, line in enumerate(lines, 1):
        if number >= start_n:
            break
        for index, pattern in enumerate(patterns):
            if not pattern.fullmatch(line):
                continue
            retry_map = N6_MARKERS[index] == "ZKL: map-frozen" and cursor == index + 1
            if index == cursor:
                cursor += 1
                last_n6 = number
            elif not retry_map:
                errors.append(
                    "Duplicate/out-of-order N6 stage at line %d: %s" % (number, line)
                )
            break
    if cursor != len(N6_MARKERS):
        errors.append("Negative run missing complete ordered N6 prefix")
    elif last_n6 and last_n6 >= start_n:
        errors.append("vm-start must follow the last N6 trap marker")


def _check_negative_sequence(mode, starts, fixtures, cycles, fails, exits, vm_line_numbers, errors):
    if not starts:
        return
    start_n = starts[0][0]
    fail_n = fails[0][0] if fails else None
    exit_n = exits[0][0] if exits else None
    if any(c != 1 for _, c, _, _ in fixtures) or any(c != 1 for _, c, _, _ in cycles):
        errors.append("Negative run must not emit cycle 2")
    if [c for _, c, _, _ in fixtures] != [1]:
        errors.append("Negative run must record exactly one cycle-1 fixture")
    if fixtures and fixtures[0][0] <= start_n:
        errors.append("cycle 1 fixture must follow vm-start")
    stages = [(n, s) for n, c, s, _ in cycles if c == 1]
    stage_names = [s for _, s in stages]
    if mode == "skip-switch":
        required = ["control", "template", "construct", "walk", "switch"]
        if stage_names != required:
            errors.append("skip-switch missing construction/walk/switch before failure")
        if "content" in stage_names:
            errors.append("skip-switch emitted virtual content success")
        _check_skip_switch_observed(cycles, errors)
    elif mode == "writable-ro":
        required = ["control", "template", "construct", "walk", "switch", "content"]
        if stage_names != required:
            errors.append("writable-ro missing stages before RO-fault failure")
        if "fault-ro" in stage_names:
            errors.append("writable-ro emitted successful fault-ro")
        switch_fields = [f for _, c, s, f in cycles if c == 1 and s == "switch"]
        if not switch_fields:
            errors.append("writable-ro missing switch observation")
        else:
            parsed = SWITCH_RE.fullmatch(switch_fields[0])
            if not parsed or parsed.group(1) != parsed.group(2):
                errors.append("writable-ro switch readback must match before RO tamper")
    else:
        required = []
    events = [(start_n, ("start", None, None))]
    for n, c, _, _ in fixtures:
        events.append((n, ("fixture", c, None)))
    for n, c, s, _ in cycles:
        events.append((n, ("stage", c, s)))
    if fails:
        events.append((fails[0][0], ("fail", fails[0][1], None)))
    if exits:
        events.append((exits[0][0], ("exit", None, None)))
    events.sort(key=lambda item: item[0])
    want = [("start", None, None), ("fixture", 1, None)]
    for stage in required:
        want.append(("stage", 1, stage))
    if fails:
        want.append(("fail", 1, None))
    if exits:
        want.append(("exit", None, None))
    got = [item[1] for item in events]
    if required and got != want:
        errors.append("negative fixture/stage order mismatch")
    if fail_n is not None:
        if stages and fail_n < stages[-1][0]:
            errors.append("vm-fail precedes the last reached cycle stage")
        if fixtures and fail_n < fixtures[0][0]:
            errors.append("vm-fail precedes cycle evidence")
        for n in vm_line_numbers:
            if n > fail_n:
                errors.append("VM marker after named failure")
                break
    if exit_n is not None:
        for n in vm_line_numbers:
            if n > exit_n:
                errors.append("VM marker after terminal exit")
                break
        if fail_n is not None and fail_n > exit_n:
            errors.append("vm-fail after terminal exit")


def _check_skip_switch_observed(cycles, errors):
    control_fields = [f for _, c, s, f in cycles if c == 1 and s == "control"]
    switch_fields = [f for _, c, s, f in cycles if c == 1 and s == "switch"]
    if not switch_fields:
        errors.append("skip-switch missing switch observation")
        return
    parsed = SWITCH_RE.fullmatch(switch_fields[0])
    if not parsed:
        errors.append("skip-switch switch field mismatch")
        return
    expected = int(parsed.group(1), 16)
    observed = int(parsed.group(2), 16)
    if parsed.group(1) == parsed.group(2):
        errors.append("skip-switch CR3 readback matched the private root")
    if not _frame_ok(observed):
        errors.append("skip-switch observed CR3 is not a valid saved original root")
        return
    if not control_fields:
        errors.append("skip-switch missing control observation")
        return
    control = CONTROL_RE.fullmatch(control_fields[0])
    if not control:
        errors.append("skip-switch control field mismatch")
        return
    orig_addr = int(control.group(1), 16) & CR3_ADDR
    if observed != orig_addr:
        errors.append("skip-switch observed CR3 is not the saved original CR3 address")
    if observed == expected:
        errors.append("skip-switch observed CR3 equals the private root")


def _check_cycle_semantics(fixtures, cycles, errors, *, require_full):
    by_cycle = {1: {}, 2: {}}
    seen = {1: [], 2: []}
    for _, cycle, stage, fields in cycles:
        if stage in by_cycle[cycle]:
            errors.append("Duplicated cycle %d stage %s" % (cycle, stage))
        by_cycle[cycle][stage] = fields
        seen[cycle].append(stage)

    want_cycles = (1, 2) if require_full else (1,)
    if require_full:
        if [c for _, c, _, _ in fixtures] != [1, 2]:
            errors.append("Expected fixtures for cycles 1 then 2")
    elif fixtures and fixtures[0][1] != 1:
        errors.append("Negative run must record cycle-1 fixture")

    for n, cycle, length, digest in fixtures:
        if length != FIXTURE_LEN:
            errors.append("cycle %d fixture length != %d" % (cycle, FIXTURE_LEN))
        pinned = FIXTURE_SHA256.get(cycle)
        if pinned is None or digest != pinned:
            errors.append("cycle %d fixture digest is not the pinned native-vm-probe-v1 value" % cycle)

    generations = []
    cycles_needed = want_cycles
    baseline_pmm = None
    baseline_cr3 = None
    baseline_template_root = None
    baseline_pdpt_addrperm = None
    for cycle in cycles_needed:
        fields = by_cycle[cycle]
        if require_full and seen[cycle] != list(CYCLE_STAGES):
            errors.append("Cycle %d stages incomplete or reordered" % cycle)
            continue
        control = None
        construct = None
        walk = None
        switch = None
        template = None
        restore = None
        destroy = None
        if "control" in fields:
            control = _kv_error("cycle %d control" % cycle, CONTROL_RE.fullmatch(fields["control"]), errors)
        elif require_full:
            _kv_error("cycle %d control" % cycle, None, errors)
        if "construct" in fields:
            construct = _kv_error("cycle %d construct" % cycle, CONSTRUCT_RE.fullmatch(fields["construct"]), errors)
        elif require_full:
            _kv_error("cycle %d construct" % cycle, None, errors)
        if "walk" in fields:
            walk = _kv_error("cycle %d walk" % cycle, WALK_RE.fullmatch(fields["walk"]), errors)
        elif require_full:
            _kv_error("cycle %d walk" % cycle, None, errors)
        if "switch" in fields:
            switch = _kv_error("cycle %d switch" % cycle, SWITCH_RE.fullmatch(fields["switch"]), errors)
        elif require_full:
            _kv_error("cycle %d switch" % cycle, None, errors)
        if "template" in fields:
            template = _kv_error("cycle %d template" % cycle, TEMPLATE_RE.fullmatch(fields["template"]), errors)
        elif require_full:
            _kv_error("cycle %d template" % cycle, None, errors)
        if "content" in fields and not CONTENT_RE.fullmatch(fields["content"]):
            errors.append("cycle %d content field mismatch" % cycle)
        if "restore" in fields:
            restore = _kv_error("cycle %d restore" % cycle, SWITCH_RE.fullmatch(fields["restore"]), errors)
        if "destroy" in fields:
            destroy = _kv_error("cycle %d destroy" % cycle, DESTROY_RE.fullmatch(fields["destroy"]), errors)

        kernel_root = None
        if control:
            cr3, rflags, cr0, cr4, efer, total, free, used, unmanaged, excluded = control.groups()
            cr3_i, rflags_i = int(cr3, 16), int(rflags, 16)
            cr0_i, cr4_i, efer_i = int(cr0, 16), int(cr4, 16), int(efer, 16)
            total_i, free_i, used_i = int(total), int(free), int(used)
            if rflags_i & RFLAGS_IF:
                errors.append("cycle %d IF not masked" % cycle)
            if cr0_i & CR0_WP == 0 or efer_i & EFER_NXE == 0:
                errors.append("cycle %d WP/NXE missing" % cycle)
            if cr4_i & (CR4_PCIDE | CR4_LA57 | CR4_SMEP | CR4_SMAP):
                errors.append("cycle %d unsupported CR4 profile" % cycle)
            if total_i != free_i + used_i:
                errors.append("cycle %d PMM accounting invalid" % cycle)
            kernel_root = cr3_i & CR3_ADDR
            if not _frame_ok(kernel_root):
                errors.append("cycle %d original root is not a domain-aligned frame" % cycle)
            if template and int(template.group(1), 16) != kernel_root:
                errors.append("cycle %d template root != CR3 address" % cycle)
            pmm_tuple = (total, free, used, unmanaged, excluded)
            if cycle == 1:
                baseline_pmm = pmm_tuple
                baseline_cr3 = cr3
            else:
                if baseline_pmm is not None and pmm_tuple != baseline_pmm:
                    errors.append("cycle %d PMM stats != run baseline" % cycle)
                if baseline_cr3 is not None and cr3 != baseline_cr3:
                    errors.append("cycle %d original full CR3 != run baseline" % cycle)
            if restore:
                if restore.group(1) != restore.group(2):
                    errors.append("cycle %d restore expected != observed" % cycle)
                if restore.group(1) != cr3:
                    errors.append("cycle %d restore is not the original full CR3" % cycle)
            if destroy:
                destroy_tuple = (
                    destroy.group(1), destroy.group(2), destroy.group(3),
                    destroy.group(4), destroy.group(5),
                )
                if destroy_tuple != pmm_tuple:
                    errors.append("cycle %d destroy PMM stats != control baseline" % cycle)
                if baseline_pmm is not None and destroy_tuple != baseline_pmm:
                    errors.append("cycle %d destroy PMM stats != run baseline" % cycle)
        if template:
            pdpt_entry = int(template.group(2), 16)
            _check_borrowed_pdpt(cycle, pdpt_entry, kernel_root, errors)
            if cycle == 1:
                baseline_template_root = template.group(1)
                baseline_pdpt_addrperm = pdpt_entry & ~PTE_AD
            else:
                if baseline_template_root is not None and template.group(1) != baseline_template_root:
                    errors.append("cycle %d template root != run baseline" % cycle)
                if baseline_pdpt_addrperm is not None and (pdpt_entry & ~PTE_AD) != baseline_pdpt_addrperm:
                    errors.append("cycle %d borrowed PDPT != run baseline modulo A/D" % cycle)
        if construct:
            owned, image, stack, tables, root = construct.groups()
            root_i = int(root, 16)
            if int(owned) != EXPECT_OWNED or int(image) != EXPECT_IMAGE or int(stack) != EXPECT_STACK or int(tables) != EXPECT_TABLES:
                errors.append("cycle %d page budgets != 4/16/6/26" % cycle)
            if int(owned) != int(image) + int(stack) + int(tables):
                errors.append("cycle %d owned != image+stack+tables" % cycle)
            if not _frame_ok(root_i):
                errors.append("cycle %d private root is not a domain-aligned frame" % cycle)
            if kernel_root is not None and root_i == kernel_root:
                errors.append("cycle %d private root equals original CR3 root" % cycle)
            if switch:
                if switch.group(1) != root:
                    errors.append("cycle %d switch expected != construct root" % cycle)
                if require_full and switch.group(1) != switch.group(2):
                    errors.append("cycle %d switch root mismatch" % cycle)
        if walk:
            if walk.group(1) != str(EXPECT_IMAGE_PTS) or walk.group(2) != str(EXPECT_STACK_PTS):
                errors.append("cycle %d image/stack PT counts" % cycle)
            leaves = (
                int(walk.group(3), 16), int(walk.group(4), 16),
                int(walk.group(5), 16), int(walk.group(6), 16),
            )
            if len(set(leaves)) != 4:
                errors.append("cycle %d leaf physical backings are not distinct" % cycle)
            for leaf in leaves:
                if not _frame_ok(leaf):
                    errors.append("cycle %d leaf physical id is not a domain-aligned frame" % cycle)
                    break
            if construct:
                root_i = int(construct.group(5), 16)
                if root_i in leaves:
                    errors.append("cycle %d leaf aliases the private root" % cycle)
        for stage, want in PFEC.items():
            if stage in fields:
                parsed = FAULT_RE.fullmatch(fields[stage])
                if not parsed:
                    errors.append("cycle %d %s field mismatch" % (cycle, stage))
                    continue
                pfec = int(parsed.group(1), 16)
                cr2 = int(parsed.group(2), 16)
                rip = int(parsed.group(3), 16)
                gen = int(parsed.group(4))
                if pfec != want:
                    errors.append("cycle %d %s pfec mismatch" % (cycle, stage))
                if cr2 != FAULT_CR2[stage]:
                    errors.append("cycle %d %s CR2 is not the expected fault VA" % (cycle, stage))
                if gen == 0:
                    errors.append("cycle %d %s generation is zero" % (cycle, stage))
                if stage == "fault-nx":
                    if rip != FAULT_CR2["fault-nx"]:
                        errors.append("cycle %d fault-nx RIP is not the NX VA" % cycle)
                elif not (KERNEL_LO <= rip < KERNEL_HI):
                    errors.append("cycle %d %s RIP is not a nonzero bounded kernel RIP" % (cycle, stage))
                generations.append(gen)
    for i in range(1, len(generations)):
        if generations[i] <= generations[i - 1]:
            errors.append("fault generations are not strictly increasing across cycles")
            break
