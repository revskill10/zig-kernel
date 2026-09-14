#!/usr/bin/env python3
"""VM qualifier snapshot/artifact/profile, unavailable, and negative rejection."""
from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from common import CHECKOUT, scratch_dir
import esp_image as img
import probe
import qualify_vm
from test_vm_transcript import positive_transcript, skip_switch_transcript, writable_ro_transcript


def fake_imginfo(_imginfo, kind, path):
    return f"imginfo: {kind} ok file={path}"


def mark_valid_negative_transport(report):
    report["launched"] = True
    report["attach_attempted"] = True
    report["kernel_entry_observed"] = True
    report["docker_start_exit_code"] = 47
    report["container_state"] = {"ExitCode": 47}
    report["owned_container_id"] = "a" * 64
    report["cleanup"] = {"container_id": "a" * 64, "exit_code": 0}
    report["esp_unchanged"] = True
    report["verifier_image"] = probe.PINNED_IMAGE_ID
    report["qemu_accel"] = "tcg"
    report["firmware_sha256"] = {
        probe.OVMF_CODE: probe.PINNED_OVMF_CODE_SHA256,
        "/out/OVMF_VARS.fd": probe.PINNED_OVMF_VARS_SHA256,
    }
    report["errors"].append("Expected isa-debug-exit status33")


class VmQualifyConfigTests(unittest.TestCase):
    def make_artifacts(self, *, corrupt_kernel=False, missing=None):
        root = Path(tempfile.mkdtemp(prefix="vm-qualify-", dir=scratch_dir("tests")))
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

    def run_qual(self, root, parent, *, boot=None, mode="positive", timeout="90", extra=None):
        argv = [
            "--esp-image", str(root / "esp.img"),
            "--loader", str(root / "BOOTX64.efi"),
            "--kernel", str(root / "zk-kernel"),
            "--initramfs", str(root / "initramfs.bin"),
            "--imginfo", str(root / "imginfo.exe"),
            "--evidence-parent", str(parent),
            "--timeout", timeout,
            "--mode", mode,
        ]
        if extra:
            argv.extend(extra)
        if boot is None:
            boot_fn = mock.Mock(side_effect=AssertionError("must not launch"))
        else:
            boot_fn = boot
        with mock.patch.object(qualify_vm.qualify, "run_imginfo", side_effect=fake_imginfo), \
             mock.patch.object(probe, "run_boot", side_effect=boot_fn), \
             redirect_stdout(io.StringIO()) as stdout:
            rc = qualify_vm.main(argv)
        runs = list(parent.glob("native-vm-qualify-*"))
        report = json.loads((runs[0] / "evidence.json").read_text(encoding="utf-8")) if runs else {}
        return rc, report, stdout.getvalue(), runs

    def test_corruption_fails_before_launch(self):
        root, parent = self.make_artifacts(corrupt_kernel=True)
        rc, report, _, runs = self.run_qual(root, parent)
        self.assertEqual(rc, 1)
        self.assertEqual(report["status"], "fail")
        self.assertFalse(report["launched"])
        self.assertFalse(report["vm_qualified"])
        self.assertFalse(report["linux_replacement_qualified"])
        self.assertFalse(report["cpl3_execution_qualified"])
        self.assertFalse(report["user_supervisor_isolation_qualified"])
        self.assertTrue(any("artifact mismatch" in e for e in report["errors"]))
        self.assertEqual(len(runs), 1)

    def test_missing_artifact_is_unavailable(self):
        root, parent = self.make_artifacts(missing="zk-kernel")
        rc, report, _, _ = self.run_qual(root, parent)
        self.assertEqual(rc, 2)
        self.assertEqual(report["status"], "unavailable")
        self.assertFalse(report["launched"])
        self.assertFalse(report["vm_qualified"])

    def test_timeout_below_vm_range_fails_before_launch(self):
        root, parent = self.make_artifacts()
        rc, report, _, _ = self.run_qual(root, parent, timeout="45")
        self.assertEqual(rc, 1)
        self.assertFalse(report["launched"])
        self.assertTrue(any("75" in e and "120" in e for e in report["errors"]))

    def test_missing_runtime_unavailable_not_skip(self):
        root, parent = self.make_artifacts()

        def boom(**_k):
            raise probe.Unavailable("Docker verifier image unavailable")

        rc, report, _, _ = self.run_qual(root, parent, boot=boom)
        self.assertEqual(rc, 2)
        self.assertEqual(report["status"], "unavailable")
        self.assertFalse(report["vm_qualified"])
        self.assertFalse(report["linux_replacement_qualified"])

    def test_bootstrap_only_success_is_not_vm_pass(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            kwargs["report"]["launched"] = True
            kwargs["report"]["kernel_entry_observed"] = True
            kwargs["report"]["attach_attempted"] = True
            serial = kwargs["output"] / "serial.log"
            from test_transcript import transcript as bootstrap_transcript
            serial.write_text(bootstrap_transcript(), encoding="utf-8")

        rc, report, _, _ = self.run_qual(root, parent, boot=fake_boot)
        self.assertEqual(rc, 1)
        self.assertEqual(report["status"], "fail")
        self.assertFalse(report["vm_qualified"])
        self.assertFalse(report["linux_replacement_qualified"])
        self.assertTrue(report["launched"])

    def test_positive_serial_can_qualify_vm(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            kwargs["report"]["launched"] = True
            kwargs["report"]["kernel_entry_observed"] = True
            kwargs["report"]["attach_attempted"] = True
            (kwargs["output"] / "serial.log").write_text(positive_transcript(), encoding="utf-8")

        rc, report, _, _ = self.run_qual(root, parent, boot=fake_boot)
        self.assertEqual(rc, 0)
        self.assertEqual(report["status"], "pass")
        self.assertTrue(report["vm_qualified"])
        self.assertFalse(report["linux_replacement_qualified"])
        self.assertFalse(report["cpl3_execution_qualified"])
        self.assertFalse(report["user_supervisor_isolation_qualified"])
        self.assertEqual(report["profile"], "native-vm-probe-v1")
        self.assertEqual(report["inputs"]["zk-kernel"]["sha256"], report["kernel_sha256"])

    def test_skip_switch_never_passes(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            mark_valid_negative_transport(kwargs["report"])
            (kwargs["output"] / "serial.log").write_text(skip_switch_transcript(), encoding="utf-8")
            raise probe.Failed("Expected isa-debug-exit status33")

        rc, report, _, _ = self.run_qual(root, parent, boot=fake_boot, mode="skip-switch")
        self.assertEqual(rc, 1)
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["verdict"], "fail")
        self.assertFalse(report["vm_qualified"])
        self.assertTrue(report["expected_negative_observed"])
        self.assertFalse(report["linux_replacement_qualified"])

    def test_writable_ro_never_passes(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            mark_valid_negative_transport(kwargs["report"])
            (kwargs["output"] / "serial.log").write_text(writable_ro_transcript(), encoding="utf-8")
            raise probe.Failed("Expected isa-debug-exit status33")

        rc, report, _, _ = self.run_qual(root, parent, boot=fake_boot, mode="writable-ro")
        self.assertEqual(rc, 1)
        self.assertEqual(report["verdict"], "fail")
        self.assertFalse(report["vm_qualified"])
        self.assertTrue(report["expected_negative_observed"])

    def test_unlaunched_timeout_is_not_expected_negative(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            kwargs["report"]["launched"] = False
            kwargs["report"]["docker_start_exit_code"] = 124
            kwargs["report"]["container_state"] = {"ExitCode": 124}
            kwargs["report"]["cleanup"] = {"exit_code": 1}
            kwargs["report"]["errors"].append("cleanup failed")
            (kwargs["output"] / "serial.log").write_text(skip_switch_transcript(), encoding="utf-8")
            raise probe.Failed("cleanup failed")

        rc, report, _, _ = self.run_qual(root, parent, boot=fake_boot, mode="skip-switch")
        self.assertEqual(rc, 1)
        self.assertEqual(report["verdict"], "fail")
        self.assertFalse(report["vm_qualified"])
        self.assertFalse(report["expected_negative_observed"])
        self.assertTrue(any("expected negative failure was not observed" in e for e in report["errors"]))

    def test_attach_timeout_is_not_expected_negative(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            mark_valid_negative_transport(kwargs["report"])
            kwargs["report"]["attach_timed_out"] = True
            kwargs["report"]["docker_start_exit_code"] = None
            kwargs["report"]["errors"].append("attach timed out")
            (kwargs["output"] / "serial.log").write_text(skip_switch_transcript(), encoding="utf-8")
            raise probe.Failed("attach timed out")

        rc, report, _, _ = self.run_qual(root, parent, boot=fake_boot, mode="skip-switch")
        self.assertFalse(report["expected_negative_observed"])
        self.assertFalse(report["vm_qualified"])

    def test_esp_mutation_is_not_expected_negative(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            mark_valid_negative_transport(kwargs["report"])
            kwargs["report"]["esp_unchanged"] = False
            kwargs["report"]["errors"].append("Boot input ESP changed")
            (kwargs["output"] / "serial.log").write_text(skip_switch_transcript(), encoding="utf-8")
            raise probe.Failed("Expected isa-debug-exit status33")

        rc, report, _, _ = self.run_qual(root, parent, boot=fake_boot, mode="skip-switch")
        self.assertFalse(report["expected_negative_observed"])
        self.assertFalse(report["vm_qualified"])

    def test_default_kernel_step_not_replaced(self):
        text = (CHECKOUT / "build.zig").read_text(encoding="utf-8")
        native_at = text.find('mkNativeMod(b, "src/native/main.zig"')
        vm_at = text.find("native-kernel-vm-probe")
        self.assertNotEqual(native_at, -1)
        self.assertNotEqual(vm_at, -1)
        self.assertIn("zk-kernel-vm-skip-switch", text)
        self.assertIn("zk-kernel-vm-writable-ro", text)
        self.assertIn("qualify-native-vm", text)
        self.assertIn("test-native-vm-probe", text)
        self.assertIn("scripts/qualify-native/qualify_vm.py", text)

    def test_missing_pins_not_expected_negative(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            mark_valid_negative_transport(kwargs["report"])
            kwargs["report"]["verifier_image"] = None
            kwargs["report"]["qemu_accel"] = None
            kwargs["report"].pop("firmware_sha256", None)
            (kwargs["output"] / "serial.log").write_text(skip_switch_transcript(), encoding="utf-8")
            raise probe.Failed("Expected isa-debug-exit status33")

        rc, report, _, _ = self.run_qual(root, parent, boot=fake_boot, mode="skip-switch")
        self.assertEqual(rc, 1)
        self.assertFalse(report["expected_negative_observed"])
        self.assertFalse(report["vm_qualified"])
        self.assertTrue(any("expected negative failure was not observed" in e for e in report["errors"]))
        self.assertTrue(any("Expected isa-debug-exit status33" in e for e in report["errors"]))

    def test_wrong_cleanup_owner_not_expected_negative(self):
        root, parent = self.make_artifacts()

        def fake_boot(**kwargs):
            mark_valid_negative_transport(kwargs["report"])
            kwargs["report"]["cleanup"] = {"container_id": "b" * 64, "exit_code": 0}
            (kwargs["output"] / "serial.log").write_text(skip_switch_transcript(), encoding="utf-8")
            raise probe.Failed("Expected isa-debug-exit status33")

        rc, report, _, _ = self.run_qual(root, parent, boot=fake_boot, mode="skip-switch")
        self.assertEqual(rc, 1)
        self.assertFalse(report["expected_negative_observed"])
        self.assertFalse(report["vm_qualified"])
        self.assertTrue(any("expected negative failure was not observed" in e for e in report["errors"]))

    def test_transport_predicate_rejects_missing_pins_and_wrong_owner(self):
        report = {
            "launched": True,
            "attach_attempted": True,
            "container_state": {"ExitCode": 47},
            "docker_start_exit_code": 47,
            "cleanup": {"exit_code": 0, "container_id": "b" * 64},
            "owned_container_id": "a" * 64,
            "esp_unchanged": True,
            "esp_binding": {"status": "pass"},
            "profile": qualify_vm.PROFILE,
            "inputs": {"zk-kernel": {"sha256": "c" * 64}},
            "errors": [],
        }
        self.assertFalse(qualify_vm.expected_negative_transport_ok(report))
        report["cleanup"]["container_id"] = "a" * 64
        report["qemu_accel"] = "tcg"
        report["verifier_image"] = probe.PINNED_IMAGE_ID
        report["firmware_sha256"] = {
            probe.OVMF_CODE: probe.PINNED_OVMF_CODE_SHA256,
            "/out/OVMF_VARS.fd": probe.PINNED_OVMF_VARS_SHA256,
        }
        self.assertTrue(qualify_vm.expected_negative_transport_ok(report))
        missing = dict(report)
        missing["verifier_image"] = None
        missing["qemu_accel"] = None
        missing["firmware_sha256"] = {}
        self.assertFalse(qualify_vm.expected_negative_transport_ok(missing))

    def test_cli_help_names_modes(self):
        buf = io.StringIO()
        qualify_vm.build_parser().print_help(buf)
        help_text = buf.getvalue()
        self.assertIn("skip-switch", help_text)
        self.assertIn("writable-ro", help_text)
        self.assertIn("75-120", help_text)


if __name__ == "__main__":
    unittest.main()
