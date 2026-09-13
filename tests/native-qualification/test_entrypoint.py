#!/usr/bin/env python3
"""Public entrypoints: portable Python CLI, optional PowerShell wrapper."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from common import QUALIFY_DIR, CHECKOUT, scratch_dir
import esp_image as img


def _powershell():
    return shutil.which("powershell") or shutil.which("pwsh")


class PythonEntrypointTests(unittest.TestCase):
    def test_python_cli_missing_artifact_is_unavailable(self):
        parent = Path(tempfile.mkdtemp(prefix="pyentry-", dir=scratch_dir("tests")))
        loader, kernel, initrd = b"L" * 16, b"K" * 16, b"I" * 8
        (parent / "esp.img").write_bytes(img.standard_esp(loader, kernel, initrd))
        (parent / "BOOTX64.efi").write_bytes(loader)
        (parent / "initramfs.bin").write_bytes(initrd)
        evidence = parent / "evidence"
        evidence.mkdir()
        args = [
            sys.executable, "-B", str(QUALIFY_DIR / "qualify.py"),
            "--esp-image", str(parent / "esp.img"),
            "--loader", str(parent / "BOOTX64.efi"),
            "--kernel", str(parent / "missing-kernel"),
            "--initramfs", str(parent / "initramfs.bin"),
            "--imginfo", str(parent / "imginfo.bin"),
            "--evidence-parent", str(evidence),
        ]
        env = os.environ.copy()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["TMP"] = str(parent)
        env["TEMP"] = str(parent)
        env["TMPDIR"] = str(parent)
        completed = subprocess.run(args, capture_output=True, text=True, timeout=30, env=env, cwd=str(CHECKOUT))
        self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
        reports = list(evidence.glob("native-qualify-*/evidence.json"))
        self.assertTrue(reports, completed.stdout + completed.stderr)
        report = json.loads(reports[0].read_text(encoding="utf-8"))
        self.assertEqual(report["status"], "unavailable")
        self.assertFalse(report["linux_replacement_qualified"])
        self.assertFalse(report["launched"])
        self.assertTrue(any("missing artifact" in e for e in report["errors"]))

    def test_python_cli_rejects_non_tcg_without_docker(self):
        parent = Path(tempfile.mkdtemp(prefix="pyaccel-", dir=scratch_dir("tests")))
        args = [
            sys.executable, "-B", str(QUALIFY_DIR / "qualify.py"),
            "--esp-image", str(parent / "esp.img"),
            "--loader", str(parent / "BOOTX64.efi"),
            "--kernel", str(parent / "zk-kernel"),
            "--initramfs", str(parent / "initramfs.bin"),
            "--imginfo", str(parent / "imginfo.bin"),
            "--evidence-parent", str(parent),
            "--qemu-accel", "kvm",
        ]
        completed = subprocess.run(args, capture_output=True, text=True, timeout=20, cwd=str(CHECKOUT))
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("tcg", (completed.stderr + completed.stdout).lower())


@unittest.skipUnless(_powershell() is not None, "PowerShell wrapper not available on this host")
class PowerShellWrapperTests(unittest.TestCase):
    def test_powershell_missing_python_is_unavailable(self):
        parent = Path(tempfile.mkdtemp(prefix="entry-", dir=scratch_dir("tests")))
        missing_py = parent / "no-python.exe"
        script = QUALIFY_DIR / "qualify.ps1"
        ps = _powershell()
        args = [
            ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script),
            "-EspImage", str(parent / "esp.img"),
            "-Loader", str(parent / "BOOTX64.efi"),
            "-Kernel", str(parent / "zk-kernel"),
            "-Initramfs", str(parent / "initramfs.bin"),
            "-ImgInfo", str(parent / "imginfo.exe"),
            "-Python", str(missing_py),
            "-EvidenceDir", str(parent),
        ]
        env = os.environ.copy()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["TMP"] = str(parent)
        env["TEMP"] = str(parent)
        env["TMPDIR"] = str(parent)
        completed = subprocess.run(args, capture_output=True, text=True, timeout=30, env=env, cwd=str(CHECKOUT))
        self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
        evidences = list(parent.glob("native-qualify-*/evidence.json"))
        self.assertTrue(evidences, completed.stdout + completed.stderr)
        report = json.loads(evidences[0].read_text(encoding="utf-8"))
        self.assertEqual(report["status"], "unavailable")
        self.assertFalse(report["linux_replacement_qualified"])
        self.assertIn("Python 3", report.get("reason", "") + "".join(report.get("errors", [])))


if __name__ == "__main__":
    unittest.main()
