#!/usr/bin/env python3
"""Anchored serial markers: spoofing, order, duplicates, contradictory exits."""
from __future__ import annotations

import unittest

from common import QUALIFY_DIR  # noqa: F401 — path setup
from transcript import MARKERS, parse_serial


def transcript():
    fields = {
        "ZKL: kernel-loaded": " base=200000 span=1000 entry=200000",
        "ZKL: map-frozen": " attempt=1 ranges=12",
        "ZKN: timer-ok": " ticks=20",
    }
    return "\n".join(marker + fields.get(marker, "") for marker in MARKERS) + "\nZKN: exit code=10\n"


class TranscriptTests(unittest.TestCase):
    def test_valid_field_markers_and_firmware_noise(self):
        result = parse_serial("OVMF startup\r\n" + transcript())
        self.assertEqual(result["transcript_errors"], [])
        self.assertTrue(result["kernel_entry_observed"])

    def test_exit_boot_services_retry_allowed(self):
        text = transcript().replace(
            "ZKL: map-frozen attempt=1 ranges=12",
            "ZKL: map-frozen attempt=1 ranges=12\nZKL: ebs-retry attempt=1\nZKL: map-frozen attempt=2 ranges=12",
        )
        self.assertEqual(parse_serial(text)["transcript_errors"], [])

    def test_prefix_spoof_rejected(self):
        for marker in MARKERS:
            with self.subTest(marker=marker):
                self.assertTrue(parse_serial(transcript().replace(marker, marker + "-failed"))["transcript_errors"])

    def test_nonanchored_marker_rejected(self):
        self.assertTrue(parse_serial(transcript().replace("ZKN: entry", "echo ZKN: entry"))["transcript_errors"])

    def test_explicit_failure_rejects_otherwise_complete_success(self):
        for failure in ("ZKL: fail stage=open reason=NotFound", "ZKN: PANIC bad", "ZKN: bootinfo-invalid reason=x"):
            with self.subTest(failure=failure):
                self.assertTrue(parse_serial(failure + "\n" + transcript())["transcript_errors"])

    def test_repeated_boot_rejected(self):
        text = "ZKL: start\nZKL: kernel-loaded base=1\n" + transcript()
        self.assertTrue(parse_serial(text)["transcript_errors"])

    def test_native_faults_reject_complete_success_transcript(self):
        for fault in ("ZKN: FAULT double-fault", "ZKN: FAULT uncontrolled"):
            with self.subTest(fault=fault):
                result = parse_serial(transcript() + fault + "\n")
                self.assertTrue(any("Explicit native failure" in error for error in result["transcript_errors"]))

    def test_out_of_order_stage_rejected(self):
        text = transcript().replace("ZKN: gdt-ok\nZKN: idt-ok", "ZKN: idt-ok\nZKN: gdt-ok")
        self.assertTrue(parse_serial(text)["transcript_errors"])

    def test_exit_is_required_unique_correct_and_terminal(self):
        variants = [
            transcript().replace("ZKN: exit code=10\n", ""),
            transcript().replace("exit code=10", "exit code=3f"),
            transcript() + "ZKN: exit code=10\n",
            "ZKN: exit code=10\n" + transcript().replace("ZKN: exit code=10\n", ""),
            transcript() + "ZKN: entry\n",
        ]
        for text in variants:
            with self.subTest(text=text):
                self.assertTrue(parse_serial(text)["transcript_errors"])


if __name__ == "__main__":
    unittest.main()
