#!/usr/bin/env python3
"""Public qualify.py glue: fail-before-launch on corruption, imginfo, missing files."""
from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from common import scratch_dir
import esp_image as img
import qualify
import probe


def fake_imginfo(_imginfo, kind, path):
    return f"imginfo: {kind} ok file={path}"


class QualifyGlueTests(unittest.TestCase):
    def make_artifacts(self, *, corrupt_kernel=False, missing=None):
        root = Path(tempfile.mkdtemp(prefix="qualify-", dir=scratch_dir("tests")))
        loader, kernel, initrd = b"L" * 32, b"K" * 32, b"I" * 16
        if corrupt_kernel:
            embedded_kernel = bytearray(kernel)
            embedded_kernel[-1] ^= 1
            embedded_kernel = bytes(embedded_kernel)
        else:
            embedded_kernel = kernel
        esp = img.standard_esp(loader, embedded_kernel, initrd)
        files = {
            "esp.img": esp,
            "BOOTX64.efi": loader,
            "zk-kernel": kernel,
            "initramfs.bin": initrd,
            "imginfo.exe": b"not-executed",
        }
        if missing:
            files.pop(missing)
        for name, data in files.items():
            (root / name).write_bytes(data)
        parent = root / "evidence"
        parent.mkdir()
        return root, parent

    def run_qualify(self, root, parent, **kwargs):
        argv = [
            "--esp-image", str(root / "esp.img"),
            "--loader", str(root / "BOOTX64.efi"),
            "--kernel", str(root / "zk-kernel"),
            "--initramfs", str(root / "initramfs.bin"),
            "--imginfo", str(root / "imginfo.exe"),
            "--evidence-parent", str(parent),
            "--timeout", "15",
        ]
        for key, value in kwargs.items():
            argv.extend([key, value])
        with mock.patch.object(qualify, "run_imginfo", side_effect=fake_imginfo), \
             mock.patch.object(probe, "run_boot", side_effect=AssertionError("must not launch")), \
             redirect_stdout(io.StringIO()) as stdout:
            rc = qualify.main(argv)
        runs = list(parent.glob("native-qualify-*"))
        self.assertEqual(len(runs), 1)
        report = json.loads((runs[0] / "evidence.json").read_text(encoding="utf-8"))
        return rc, report, stdout.getvalue(), runs[0]

    def test_corruption_fails_before_launch(self):
        root, parent = self.make_artifacts(corrupt_kernel=True)
        rc, report, _, run = self.run_qualify(root, parent)
        self.assertEqual(rc, 1)
        self.assertEqual(report["status"], "fail")
        self.assertFalse(report["launched"])
        self.assertFalse(report["linux_replacement_qualified"])
        self.assertTrue(any("artifact mismatch" in e for e in report["errors"]))
        self.assertTrue((run / "esp-binding.json").is_file())

    def test_missing_artifact_is_unavailable(self):
        root, parent = self.make_artifacts(missing="zk-kernel")
        rc, report, _, _ = self.run_qualify(root, parent)
        self.assertEqual(rc, 2)
        self.assertEqual(report["status"], "unavailable")
        self.assertFalse(report["launched"])
        self.assertFalse(report["linux_replacement_qualified"])

    def test_imginfo_failure_is_failed_not_pass(self):
        root, parent = self.make_artifacts()

        def boom(*_a, **_k):
            raise qualify.Failed("imginfo pe failed (rc=1): bad pe")

        argv = [
            "--esp-image", str(root / "esp.img"),
            "--loader", str(root / "BOOTX64.efi"),
            "--kernel", str(root / "zk-kernel"),
            "--initramfs", str(root / "initramfs.bin"),
            "--imginfo", str(root / "imginfo.exe"),
            "--evidence-parent", str(parent),
        ]
        with mock.patch.object(qualify, "run_imginfo", side_effect=boom), \
             mock.patch.object(probe, "run_boot", side_effect=AssertionError("must not launch")), \
             redirect_stdout(io.StringIO()):
            rc = qualify.main(argv)
        report = json.loads(next(parent.glob("native-qualify-*")).joinpath("evidence.json").read_text(encoding="utf-8"))
        self.assertEqual(rc, 1)
        self.assertEqual(report["status"], "fail")
        self.assertFalse(report["launched"])
        self.assertTrue(any("imginfo" in e for e in report["errors"]))

    def test_missing_imginfo_binary_is_unavailable(self):
        root, parent = self.make_artifacts()
        argv = [
            "--esp-image", str(root / "esp.img"),
            "--loader", str(root / "BOOTX64.efi"),
            "--kernel", str(root / "zk-kernel"),
            "--initramfs", str(root / "initramfs.bin"),
            "--imginfo", str(root / "no-such-imginfo.exe"),
            "--evidence-parent", str(parent),
        ]
        with mock.patch.object(probe, "run_boot", side_effect=AssertionError("must not launch")), \
             redirect_stdout(io.StringIO()):
            rc = qualify.main(argv)
        report = json.loads(next(parent.glob("native-qualify-*")).joinpath("evidence.json").read_text(encoding="utf-8"))
        self.assertEqual(rc, 2)
        self.assertEqual(report["status"], "unavailable")
        self.assertFalse(report["linux_replacement_qualified"])

    def test_success_path_still_not_linux_replacement(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            kwargs["report"]["launched"] = True
            kwargs["report"]["kernel_entry_observed"] = True
            kwargs["report"]["linux_replacement_qualified"] = True  # must be overwritten

        argv = [
            "--esp-image", str(root / "esp.img"),
            "--loader", str(root / "BOOTX64.efi"),
            "--kernel", str(root / "zk-kernel"),
            "--initramfs", str(root / "initramfs.bin"),
            "--imginfo", str(root / "imginfo.exe"),
            "--evidence-parent", str(parent),
        ]
        with mock.patch.object(qualify, "run_imginfo", side_effect=fake_imginfo), \
             mock.patch.object(probe, "run_boot", side_effect=fake_boot), \
             redirect_stdout(io.StringIO()):
            rc = qualify.main(argv)
        report = json.loads(next(parent.glob("native-qualify-*")).joinpath("evidence.json").read_text(encoding="utf-8"))
        self.assertEqual(rc, 0)
        self.assertEqual(report["status"], "pass")
        self.assertFalse(report["linux_replacement_qualified"])
        self.assertTrue(report["launched"])


if __name__ == "__main__":
    unittest.main()
