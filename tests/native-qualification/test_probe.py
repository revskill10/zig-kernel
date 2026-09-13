#!/usr/bin/env python3
"""Docker probe orchestration: timeout evidence, cleanup, ownership. No real Docker."""
from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from common import scratch_dir
from test_transcript import transcript
import probe

CID = "a" * 64
IMAGE = probe.PINNED_IMAGE_ID


class ProbeFlowTests(unittest.TestCase):
    def run_fixture(self, *, mode="success", recovery="owned", cleanup_fail=False, serial=None, image_id=IMAGE):
        with tempfile.TemporaryDirectory(prefix="probe-", dir=scratch_dir("tests")) as directory:
            root = Path(directory).resolve()
            inputs = root / "inputs"
            output = root / "output"
            inputs.mkdir()
            output.mkdir()
            (inputs / "esp.img").write_bytes(b"fixture: not a boot artifact\n")
            report = {
                "status": "fail",
                "errors": [],
                "linux_replacement_qualified": False,
                "inputs": {"esp.img": {"bytes": 28, "sha256": probe.digest(inputs / "esp.img")}},
            }
            state = {"calls": []}

            def result(args, code=0, stdout="", stderr=""):
                return subprocess.CompletedProcess(args, code, stdout, stderr)

            def fake_docker(args, timeout=20, docker_host=None, docker_config=None):
                self.assertLessEqual(timeout, 135)
                state["calls"].append(list(args))
                if args[:2] == ["image", "inspect"]:
                    return result(args, stdout=image_id + "\n")
                if args[0] == "create":
                    self.assertEqual(args[args.index("--entrypoint") + 1], "/bin/sh")
                    self.assertEqual(args[-3:-1], [IMAGE, "-c"])
                    self.assertIn("-accel tcg", args[-1])
                    self.assertIn("--network", args)
                    self.assertIn("none", args)
                    self.assertIn("--read-only", args)
                    self.assertIn("ALL", args)
                    self.assertIn("--cap-drop", args)
                    state["cidfile"] = Path(args[args.index("--cidfile") + 1])
                    state["name"] = args[args.index("--name") + 1]
                    state["label"] = args[args.index("--label") + 1].split("=", 1)[1]
                    state["output"] = Path(args[args.index("--mount") + 1].split("dst=")[-1]) if False else output
                    if mode != "create_timeout_no_cid":
                        state["cidfile"].write_text(CID)
                    if mode.startswith("create_timeout"):
                        raise subprocess.TimeoutExpired(args, timeout, output=b"partial create", stderr=b"create wait")
                    return result(args, stdout=CID + "\n")
                if args[:3] == ["inspect", "--type", "container"]:
                    self.assertEqual(args[3], state["name"])
                    if recovery == "unavailable":
                        raise subprocess.TimeoutExpired(args, timeout)
                    labels = {probe.OWNER_LABEL: state["label"] if recovery != "wrong_label" else "other"}
                    image = IMAGE if recovery != "wrong_image" else "sha256:" + "c" * 64
                    record = {"Id": CID, "Name": "/" + state["name"], "Image": image, "Config": {"Labels": labels}}
                    return result(args, stdout=json.dumps([record]))
                if args[:2] == ["start", "-a"]:
                    (output / "serial.log").write_text(serial if serial is not None else transcript())
                    (output / "firmware-sha256.txt").write_text(
                        f"{probe.PINNED_OVMF_CODE_SHA256}  {probe.OVMF_CODE}\n"
                        f"{probe.PINNED_OVMF_VARS_SHA256}  /out/OVMF_VARS.fd\n"
                    )
                    if mode == "attach_timeout":
                        raise subprocess.TimeoutExpired(args, timeout, output=b"partial stdout", stderr=b"partial stderr")
                    return result(args, 33, "qemu stdout", "")
                if args[:2] == ["inspect", "--format"]:
                    if mode == "inspect_fail":
                        return result(args, 1, stderr="daemon disconnected")
                    return result(args, stdout=json.dumps({"ExitCode": 33, "Running": False}))
                if args[:2] == ["rm", "-f"]:
                    self.assertEqual(args[2], CID)
                    return result(args, 1 if cleanup_fail else 0, stderr="busy" if cleanup_fail else "")
                raise AssertionError(f"unexpected Docker request: {args}")

            with mock.patch.object(probe, "docker", side_effect=fake_docker):
                try:
                    probe.run_boot(
                        inputs=inputs, output=output, report=report, timeout=45,
                        image_ref=probe.PINNED_IMAGE_REF, image_id=IMAGE,
                        accel="tcg", docker_host=None, docker_config=None,
                    )
                except probe.Unavailable:
                    report.setdefault("unavailable", True)
                except probe.Failed:
                    pass
            outputs = {p.name: p.read_text() for p in output.iterdir() if p.is_file()}
            return report, outputs, state["calls"]

    def test_clean_fixture_passes_and_removes_exact_id(self):
        report, _, calls = self.run_fixture()
        self.assertFalse(report["errors"], report["errors"])
        self.assertEqual(calls[-1], ["rm", "-f", CID])
        self.assertFalse(report["linux_replacement_qualified"])
        self.assertTrue(report["launched"])

    def test_wrong_image_digest_is_unavailable_and_does_not_create(self):
        report, _, calls = self.run_fixture(image_id="sha256:" + "d" * 64)
        self.assertTrue(any("Pinned verifier image" in e for e in report["errors"]) or report.get("unavailable"))
        self.assertFalse(any(c[0] == "create" for c in calls))
        self.assertFalse(any(c[0] == "rm" for c in calls))

    def test_attach_timeout_retains_partial_streams_and_native_entry(self):
        report, outputs, calls = self.run_fixture(mode="attach_timeout", serial="ZKL: start\nZKN: entry\n")
        self.assertTrue(report["attach_timed_out"])
        self.assertTrue(report["kernel_entry_observed"])
        self.assertIsNotNone(report["serial_sha256"])
        self.assertEqual(outputs["container-stdout.log"], "partial stdout")
        self.assertEqual(outputs["container-stderr.log"], "partial stderr")
        self.assertEqual(calls[-1], ["rm", "-f", CID])
        self.assertTrue(report["errors"])

    def test_inspect_failure_still_collects_complete_serial_without_passing(self):
        report, outputs, calls = self.run_fixture(mode="inspect_fail")
        self.assertTrue(report["kernel_entry_observed"])
        self.assertEqual(report["transcript_errors"], [])
        self.assertTrue(report["errors"])
        self.assertTrue(any("inspect" in e.lower() for e in report["errors"]))
        self.assertIsNotNone(report["serial_sha256"])
        self.assertIn("serial.log", outputs)
        self.assertEqual(calls[-1], ["rm", "-f", CID])
        self.assertFalse(report["linux_replacement_qualified"])

    def test_create_timeout_with_cid_is_cleaned(self):
        report, _, calls = self.run_fixture(mode="create_timeout_written_cid")
        self.assertEqual(report["owned_container_id"], CID)
        self.assertEqual(calls[-1], ["rm", "-f", CID])

    def test_create_timeout_without_cid_recovers_only_exact_label_image(self):
        report, _, calls = self.run_fixture(mode="create_timeout_no_cid")
        self.assertEqual(report["creation_reconciliation"]["status"], "recovered")
        self.assertFalse(report["creation_ownership_unresolved"])
        self.assertEqual(calls[-1], ["rm", "-f", CID])

    def test_unrelated_container_or_unavailable_daemon_never_claimed(self):
        for recovery in ("wrong_label", "wrong_image", "unavailable"):
            with self.subTest(recovery=recovery):
                report, _, calls = self.run_fixture(mode="create_timeout_no_cid", recovery=recovery)
                self.assertTrue(report["creation_ownership_unresolved"])
                self.assertNotIn("owned_container_id", report)
                self.assertFalse(any(c[0] == "rm" for c in calls))
                self.assertIn("token", report["creation_identity"])

    def test_cleanup_failure_overrides_successful_guest(self):
        report, _, _ = self.run_fixture(cleanup_fail=True)
        self.assertTrue(any("removal failed" in e for e in report["errors"]))

    def test_complete_markers_with_panic_and_debug33_cannot_pass(self):
        report, _, _ = self.run_fixture(serial="ZKN: PANIC synthetic failure\n" + transcript())
        self.assertTrue(any("Explicit native failure" in e for e in report["errors"]))
        self.assertFalse(report["linux_replacement_qualified"])


if __name__ == "__main__":
    unittest.main()
