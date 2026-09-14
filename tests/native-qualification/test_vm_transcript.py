#!/usr/bin/env python3
"""VM transcript grammar: mutation, order, negatives, semantic mismatches."""
from __future__ import annotations

import unittest

from common import QUALIFY_DIR  # noqa: F401 — path setup
from transcript import MARKERS
from transcript_vm import FIXTURE_SHA256, parse_vm_serial, CYCLE_STAGES

SHA1 = FIXTURE_SHA256[1]
SHA2 = FIXTURE_SHA256[2]
OTHER = "c" * 64
CR3 = "0000000000300000"
ROOT = "0000000000abc000"
RX = "0000000000aa0000"
RX1 = "0000000000ad0000"
RO = "0000000000ab0000"
RW = "0000000000ac0000"
RO_VA = "0000000040202180"
NX_VA = "0000000040204030"
GUARD = "000000007ffed000"
TOP = "000000007fffe000"
ENTRY = "00000000401ff100"
KERNEL_RIP = "0000000000200100"
EFER_OK = "0000000000001d01"
EFER_NO_NXE = "0000000000001501"
PMM = "pmm-total=4096 pmm-free=1000 pmm-used=3096 pmm-unmanaged=10 pmm-excluded=20"


def bootstrap():
    fields = {
        "ZKL: kernel-loaded": " base=200000 span=1000 entry=200000",
        "ZKL: map-frozen": " attempt=1 ranges=12",
        "ZKN: timer-ok": " ticks=32",
    }
    return [marker + fields.get(marker, "") for marker in MARKERS]


def _fault(cycle, stage, pfec, cr2, gen, rip=KERNEL_RIP):
    return (
        "ZKN: vm-cycle cycle=%d stage=%s vector=14 pfec=%s cr2=%s rip=%s gen=%d"
        % (cycle, stage, pfec, cr2, rip, gen)
    )


def cycle_lines(cycle, sha, *, stop=None, mode="positive"):
    gen0 = 1 if cycle == 1 else 6
    lines = [
        "ZKN: vm-fixture cycle=%d len=5120 sha256=%s" % (cycle, sha),
        "ZKN: vm-cycle cycle=%d stage=control cr3=%s rflags=0000000000000002 "
        "cr0=0000000080010033 cr4=0000000000000600 efer=%s %s" % (cycle, CR3, EFER_OK, PMM),
        "ZKN: vm-cycle cycle=%d stage=template root=%s pdpt0=0000000000310003" % (cycle, CR3),
        "ZKN: vm-cycle cycle=%d stage=construct owned=26 image=4 stack=16 tables=6 root=%s" % (cycle, ROOT),
        "ZKN: vm-cycle cycle=%d stage=walk image-pts=2 stack-pts=1 rx=%s rx1=%s ro=%s rw=%s" % (cycle, RX, RX1, RO, RW),
        "ZKN: vm-cycle cycle=%d stage=switch expected=%s observed=%s" % (cycle, ROOT, ROOT),
        "ZKN: vm-cycle cycle=%d stage=content fetch=0" % cycle,
        _fault(cycle, "fault-ro", "3", RO_VA, gen0),
        _fault(cycle, "fault-nx", "11", NX_VA, gen0 + 1, rip=NX_VA),
        _fault(cycle, "fault-guard", "0", GUARD, gen0 + 2),
        _fault(cycle, "fault-top", "0", TOP, gen0 + 3),
        "ZKN: vm-cycle cycle=%d stage=restore expected=%s observed=%s" % (cycle, CR3, CR3),
        _fault(cycle, "absent", "0", ENTRY, gen0 + 4),
        "ZKN: vm-cycle cycle=%d stage=destroy owned=0 adapter=0 %s" % (cycle, PMM),
    ]
    if stop is None:
        return lines
    if stop == "walk":
        return lines[:5]
    if stop == "switch":
        return lines[:6]
    if stop == "content":
        return lines[:7]
    raise AssertionError(stop)


def positive_transcript():
    head, tail = bootstrap()[:16], bootstrap()[16:]
    vm = (
        ["ZKN: vm-start profile=native-vm-probe-v1 mode=positive"]
        + cycle_lines(1, SHA1)
        + cycle_lines(2, SHA2)
        + ["ZKN: vm-complete cycles=2"]
    )
    return "\n".join(head + vm + tail) + "\nZKN: exit code=10\n"


def skip_switch_transcript():
    head = bootstrap()[:16]
    observed = CR3
    lines = head + [
        "ZKN: vm-start profile=native-vm-probe-v1 mode=skip-switch",
    ] + cycle_lines(1, SHA1, stop="walk") + [
        "ZKN: vm-cycle cycle=1 stage=switch expected=%s observed=%s" % (ROOT, observed),
        "ZKN: vm-fail cycle=1 stage=switch reason=cr3-readback",
        "ZKN: exit code=17",
    ]
    return "\n".join(lines) + "\n"


def writable_ro_transcript():
    head = bootstrap()[:16]
    lines = head + [
        "ZKN: vm-start profile=native-vm-probe-v1 mode=writable-ro",
    ] + cycle_lines(1, SHA1, stop="content") + [
        "ZKN: vm-fail cycle=1 stage=fault-ro reason=expected-pf",
        "ZKN: exit code=17",
    ]
    return "\n".join(lines) + "\n"


class VmTranscriptTests(unittest.TestCase):
    def test_valid_positive(self):
        result = parse_vm_serial(positive_transcript(), mode="positive")
        self.assertEqual(result["transcript_errors"], [])
        self.assertTrue(result["vm_complete"])

    def test_base_only_bootstrap_rejected(self):
        text = "\n".join(bootstrap()) + "\nZKN: exit code=10\n"
        result = parse_vm_serial(text, mode="positive")
        self.assertTrue(result["transcript_errors"])
        self.assertFalse(result["vm_complete"])

    def test_prefix_and_suffix_spoof_rejected(self):
        text = positive_transcript()
        self.assertTrue(parse_vm_serial(text.replace("ZKN: vm-complete cycles=2", "ZKN: vm-complete cycles=2 extra"), mode="positive")["transcript_errors"])
        self.assertTrue(parse_vm_serial(text.replace("ZKN: vm-start", "echo ZKN: vm-start"), mode="positive")["transcript_errors"])
        self.assertTrue(parse_vm_serial(text.replace("ZKN: vm-complete cycles=2", "ZKN: vm-complete-not cycles=2"), mode="positive")["transcript_errors"])

    def test_concatenated_positive_boots_rejected(self):
        text = positive_transcript() + positive_transcript()
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_reused_cycle_numbers_rejected(self):
        text = positive_transcript().replace("cycle=2", "cycle=1")
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_reordered_stages_rejected(self):
        text = positive_transcript().replace(
            "stage=fault-ro vector=14 pfec=3 cr2=%s rip=%s gen=1\nZKN: vm-cycle cycle=1 stage=fault-nx" % (RO_VA, KERNEL_RIP),
            "stage=fault-nx vector=14 pfec=11 cr2=%s rip=%s gen=2\nZKN: vm-cycle cycle=1 stage=fault-ro" % (NX_VA, NX_VA),
        )
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_duplicated_success_markers_rejected(self):
        text = positive_transcript().replace(
            "ZKN: vm-complete cycles=2",
            "ZKN: vm-complete cycles=2\nZKN: vm-complete cycles=2",
        )
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_truncated_run_rejected(self):
        text = positive_transcript().split("ZKN: vm-complete")[0] + "ZKN: timer-ok ticks=32\nZKN: done\nZKN: exit code=10\n"
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_substituted_fixture_digest_rejected(self):
        text = positive_transcript().replace(SHA2, SHA1)
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_unpinned_distinct_hash_pair_rejected(self):
        text = positive_transcript().replace(SHA1, OTHER).replace(SHA2, "d" * 64)
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("pinned" in e for e in errs))

    def test_wrong_roots_and_counts_rejected(self):
        text = positive_transcript().replace("owned=26 image=4 stack=16 tables=6", "owned=24 image=4 stack=16 tables=6")
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])
        text = positive_transcript().replace("expected=%s observed=%s" % (ROOT, ROOT), "expected=%s observed=%s" % (ROOT, CR3), 1)
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])
        text = positive_transcript().replace("pmm-free=1000", "pmm-free=999", 1)
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_fault_panic_and_extra_exit_rejected(self):
        for extra in ("ZKN: FAULT uncontrolled", "ZKN: PANIC bad", "ZKN: exit code=17"):
            text = positive_transcript() + extra + "\n"
            self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_negative_mode_claiming_positive_rejected(self):
        text = skip_switch_transcript().replace("mode=skip-switch", "mode=positive")
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])
        self.assertTrue(parse_vm_serial(positive_transcript(), mode="skip-switch")["transcript_errors"])

    def test_skip_switch_expected_failure(self):
        result = parse_vm_serial(skip_switch_transcript(), mode="skip-switch")
        self.assertEqual(result["transcript_errors"], [])
        self.assertEqual(result["vm_fail"]["stage"], "switch")
        self.assertFalse(result["vm_complete"])

    def test_writable_ro_expected_failure(self):
        result = parse_vm_serial(writable_ro_transcript(), mode="writable-ro")
        self.assertEqual(result["transcript_errors"], [])
        self.assertEqual(result["vm_fail"]["stage"], "fault-ro")
        self.assertFalse(result["vm_complete"])

    def test_skip_switch_with_content_rejected(self):
        text = skip_switch_transcript().replace(
            "ZKN: vm-fail cycle=1 stage=switch reason=cr3-readback",
            "ZKN: vm-cycle cycle=1 stage=content fetch=0\nZKN: vm-fail cycle=1 stage=switch reason=cr3-readback",
        )
        self.assertTrue(parse_vm_serial(text, mode="skip-switch")["transcript_errors"])

    def test_skip_switch_matching_cr3_rejected(self):
        text = skip_switch_transcript().replace(
            "expected=%s observed=%s" % (ROOT, CR3),
            "expected=%s observed=%s" % (ROOT, ROOT),
        )
        self.assertTrue(parse_vm_serial(text, mode="skip-switch")["transcript_errors"])

    def test_numeric_profile_bits(self):
        text = positive_transcript().replace("efer=%s" % EFER_OK, "efer=%s" % EFER_NO_NXE)
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("WP/NXE" in e for e in errs), errs)
        text = positive_transcript().replace("cr4=0000000000000600", "cr4=0000000000020600")
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_if1_rejected(self):
        text = positive_transcript().replace("rflags=0000000000000002", "rflags=0000000000000202", 1)
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("IF not masked" in e for e in errs), errs)

    def test_zero_cr2_rejected(self):
        text = positive_transcript().replace("cr2=%s" % RO_VA, "cr2=0000000000000000", 1)
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("CR2" in e for e in errs), errs)

    def test_reused_generation_rejected(self):
        text = positive_transcript().replace("rip=%s gen=6" % KERNEL_RIP, "rip=%s gen=1" % KERNEL_RIP, 1)
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("generation" in e for e in errs), errs)

    def test_zero_length_fixture_rejected(self):
        text = positive_transcript().replace("len=5120", "len=0", 1)
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("length" in e for e in errs), errs)

    def test_unaligned_private_root_rejected(self):
        text = positive_transcript().replace(ROOT, "0000000000abc001", 1)
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_private_equals_original_rejected(self):
        text = positive_transcript().replace(
            "owned=26 image=4 stack=16 tables=6 root=%s" % ROOT,
            "owned=26 image=4 stack=16 tables=6 root=%s" % CR3,
            1,
        )
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("equals original" in e for e in errs), errs)

    def test_wrong_image_budget_rejected(self):
        text = positive_transcript().replace("owned=26 image=4 stack=16 tables=6", "owned=22 image=0 stack=16 tables=6")
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("page budgets" in e for e in errs), errs)

    def test_vm_marker_after_complete_rejected(self):
        text = positive_transcript().replace(
            "ZKN: vm-complete cycles=2",
            "ZKN: vm-complete cycles=2\nZKN: vm-fixture cycle=1 len=5120 sha256=%s" % SHA1,
        )
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("after completion" in e or "outside start/complete" in e for e in errs), errs)

    def test_unknown_stage_rejected(self):
        text = positive_transcript().replace("stage=content fetch=0", "stage=arbitrary after-terminal", 1)
        self.assertTrue(parse_vm_serial(text, mode="positive")["transcript_errors"])

    def test_kernel_rip_out_of_window_rejected(self):
        text = positive_transcript().replace("rip=%s gen=1" % KERNEL_RIP, "rip=00000000401ff100 gen=1", 1)
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("kernel RIP" in e for e in errs), errs)

    def test_negative_garbage_fields_rejected(self):
        text = skip_switch_transcript().replace(
            "stage=control cr3=%s rflags=0000000000000002" % CR3,
            "stage=control garbage",
            1,
        )
        self.assertTrue(parse_vm_serial(text, mode="skip-switch")["transcript_errors"])

    def test_negative_missing_switch_observation_rejected(self):
        text = skip_switch_transcript().replace(
            "ZKN: vm-cycle cycle=1 stage=switch expected=%s observed=%s\n" % (ROOT, CR3),
            "",
        )
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("switch" in e for e in errs), errs)

    def test_negative_cycle2_after_exit_rejected(self):
        text = skip_switch_transcript() + "ZKN: vm-cycle cycle=2 stage=arbitrary after-terminal\n"
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(errs)

    def test_negative_partial_n6_prefix_rejected(self):
        lines = skip_switch_transcript().splitlines()
        lines = [ln for ln in lines if not ln.startswith("ZKN: trap-pf-nx-exec-ok")]
        text = "\n".join(lines) + "\n"
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("N6 prefix" in e for e in errs), errs)

    def test_negative_unpinned_hash_rejected(self):
        text = skip_switch_transcript().replace(SHA1, "a" * 64)
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("pinned" in e for e in errs), errs)

    def test_negative_fail_cycle2_rejected(self):
        text = skip_switch_transcript().replace("vm-fail cycle=1", "vm-fail cycle=2")
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("cycle must be 1" in e or "order mismatch" in e for e in errs), errs)

    def test_skip_switch_zero_observed_rejected(self):
        text = skip_switch_transcript().replace("observed=%s" % CR3, "observed=0000000000000000")
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("observed CR3" in e for e in errs), errs)

    def test_skip_switch_unrelated_observed_rejected(self):
        other = "0000000000400000"
        text = skip_switch_transcript().replace("observed=%s" % CR3, "observed=%s" % other)
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("saved original CR3" in e for e in errs), errs)

    def test_negative_fixture_after_all_stages_rejected(self):
        lines = skip_switch_transcript().splitlines()
        fix = next(ln for ln in lines if "vm-fixture" in ln)
        lines.remove(fix)
        lines.insert(next(i for i, ln in enumerate(lines) if "vm-fail" in ln), fix)
        errs = parse_vm_serial("\n".join(lines) + "\n", mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("order mismatch" in e for e in errs), errs)

    def test_negative_duplicate_fixture_rejected(self):
        lines = skip_switch_transcript().splitlines()
        fix = next(ln for ln in lines if "vm-fixture" in ln)
        text = skip_switch_transcript().replace(fix, fix + "\n" + fix)
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("exactly one cycle-1 fixture" in e or "order mismatch" in e for e in errs), errs)

    def test_negative_control_before_boot_rejected(self):
        lines = skip_switch_transcript().splitlines()
        control = next(ln for ln in lines if "stage=control" in ln)
        lines.remove(control)
        lines.insert(0, control)
        errs = parse_vm_serial("\n".join(lines) + "\n", mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("order mismatch" in e or "N6" in e for e in errs), errs)

    def test_positive_cycle2_pmm_baseline_rejected(self):
        lines = [
            ln.replace("pmm-free=1000 pmm-used=3096", "pmm-free=999 pmm-used=3097")
            if "cycle=2" in ln else ln
            for ln in positive_transcript().splitlines()
        ]
        errs = parse_vm_serial("\n".join(lines) + "\n", mode="positive")["transcript_errors"]
        self.assertTrue(any("run baseline" in e for e in errs), errs)

    def test_positive_invalid_borrowed_pdpt_rejected(self):
        text = positive_transcript().replace("pdpt0=0000000000310003", "pdpt0=0000000000000004")
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("borrowed PDPT" in e for e in errs), errs)

    def test_positive_cycle2_pdpt_ad_allowed(self):
        text = positive_transcript().replace(
            "cycle=2 stage=template root=%s pdpt0=0000000000310003" % CR3,
            "cycle=2 stage=template root=%s pdpt0=0000000000310063" % CR3,
        )
        result = parse_vm_serial(text, mode="positive")
        self.assertEqual(result["transcript_errors"], [])

    def test_n6_duplicate_rejected(self):
        text = skip_switch_transcript().replace(
            "ZKN: trap-ud2-ok",
            "ZKN: trap-ud2-ok\nZKN: trap-ud2-ok",
            1,
        )
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("Duplicate/out-of-order N6" in e for e in errs), errs)

    def test_n6_reordered_rejected(self):
        text = skip_switch_transcript().replace(
            "ZKN: trap-ud2-ok\nZKN: trap-pf-unmapped-ok",
            "ZKN: trap-pf-unmapped-ok\nZKN: trap-ud2-ok",
        )
        errs = parse_vm_serial(text, mode="skip-switch")["transcript_errors"]
        self.assertTrue(any("Duplicate/out-of-order N6" in e or "N6 prefix" in e for e in errs), errs)

    def test_n6_map_frozen_retry_allowed(self):
        text = skip_switch_transcript().replace(
            "ZKL: map-frozen attempt=1 ranges=12\nZKL: ebs-ok",
            "ZKL: map-frozen attempt=1 ranges=12\nZKL: ebs-retry attempt=1\n"
            "ZKL: map-frozen attempt=2 ranges=12\nZKL: ebs-ok",
        )
        result = parse_vm_serial(text, mode="skip-switch")
        self.assertEqual(result["transcript_errors"], [])

    def test_walk_rx1_alias_rejected(self):
        text = positive_transcript().replace("rx1=%s" % RX1, "rx1=%s" % RX)
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("not distinct" in e for e in errs), errs)

    def test_walk_missing_rx1_rejected(self):
        text = positive_transcript().replace("rx=%s rx1=%s ro=%s rw=%s" % (RX, RX1, RO, RW),
                                            "rx=%s ro=%s rw=%s" % (RX, RO, RW))
        errs = parse_vm_serial(text, mode="positive")["transcript_errors"]
        self.assertTrue(any("walk" in e for e in errs), errs)

    def test_stage_list_is_complete(self):
        self.assertEqual(len(CYCLE_STAGES), 13)


if __name__ == "__main__":
    unittest.main()
