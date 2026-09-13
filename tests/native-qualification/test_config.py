#!/usr/bin/env python3
"""Accel, Docker context, scratch, and standalone-checkout fixtures."""
from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from common import CHECKOUT, QUALIFY_DIR, checkout_scratch, scratch_dir, scratch_root
import qualify
import probe


class AccelTests(unittest.TestCase):
    def test_only_tcg_is_accepted(self):
        probe.require_tcg("tcg")
        for bad in ("kvm", "whpx", "tcg;rm -rf /out", "tcg -enable-kvm", "host"):
            with self.subTest(bad=bad):
                with self.assertRaises(probe.Failed):
                    probe.require_tcg(bad)

    def test_guest_command_emits_literal_tcg_and_quotes(self):
        text = probe.guest_command(45, "tcg")
        self.assertIn("-accel", text)
        self.assertIn("tcg", text)
        self.assertNotIn("tcg;id", text)
        with self.assertRaises(probe.Failed):
            probe.guest_command(45, "tcg;id")

    def test_cli_rejects_shell_metacharacter_accel_before_launch(self):
        parent = Path(tempfile.mkdtemp(prefix="accel-", dir=scratch_dir("tests")))
        argv = [
            "--esp-image", str(parent / "esp.img"),
            "--loader", str(parent / "BOOTX64.efi"),
            "--kernel", str(parent / "zk-kernel"),
            "--initramfs", str(parent / "initramfs.bin"),
            "--imginfo", str(parent / "imginfo.exe"),
            "--evidence-parent", str(parent),
            "--qemu-accel", "tcg;rm -rf /out",
        ]
        with mock.patch.object(probe, "run_boot", side_effect=AssertionError("must not launch")), \
             self.assertRaises(SystemExit) as ctx:
            qualify.main(argv)
        self.assertEqual(ctx.exception.code, 2)
        self.assertFalse(list(parent.glob("native-qualify-*")))

    def test_run_boot_rejects_non_tcg_without_docker(self):
        parent = Path(tempfile.mkdtemp(prefix="bootaccel-", dir=scratch_dir("tests")))
        inputs, output = parent / "inputs", parent / "output"
        inputs.mkdir()
        output.mkdir()
        (inputs / "esp.img").write_bytes(b"x")
        report = {"errors": [], "linux_replacement_qualified": False, "inputs": {}}
        calls = []

        def fake_docker(*_a, **_k):
            calls.append(True)
            raise AssertionError("docker must not run")

        with mock.patch.object(probe, "docker", side_effect=fake_docker):
            with self.assertRaises(probe.Failed):
                probe.run_boot(
                    inputs=inputs, output=output, report=report, timeout=15,
                    image_ref=probe.PINNED_IMAGE_REF, image_id=probe.PINNED_IMAGE_ID,
                    accel="kvm", docker_host=None, docker_config=None,
                )
        self.assertFalse(calls)
        self.assertFalse(report.get("launched"))


class DockerContextTests(unittest.TestCase):
    def test_absent_override_preserves_existing_docker_host(self):
        with mock.patch.dict(os.environ, {"DOCKER_HOST": "unix:///var/run/docker.sock"}, clear=False):
            env = probe.docker_env(None, None)
            self.assertEqual(env["DOCKER_HOST"], "unix:///var/run/docker.sock")

    def test_absent_override_does_not_inject_host_or_config(self):
        with mock.patch.dict(os.environ, {"PATH": os.environ.get("PATH", "")}, clear=True):
            env = probe.docker_env(None, None)
            self.assertNotIn("DOCKER_HOST", env)
            self.assertNotIn("DOCKER_CONFIG", env)

    def test_explicit_host_override_is_honored(self):
        env = probe.docker_env("npipe:////./pipe/dockerDesktopLinuxEngine", None)
        self.assertEqual(env["DOCKER_HOST"], "npipe:////./pipe/dockerDesktopLinuxEngine")

    def test_default_config_is_not_ancestor_tmp(self):
        self.assertIsNone(qualify.resolve_docker_config(None))
        self.assertIsNone(qualify.resolve_docker_config(""))
        fake = Path(tempfile.mkdtemp(prefix="anc-", dir=scratch_dir("tests")))
        planted = fake / ".tmp" / "sandbox-container" / "docker-config"
        planted.mkdir(parents=True)
        self.assertIsNone(qualify.resolve_docker_config(None))
        self.assertNotEqual(qualify.resolve_docker_config(None), str(planted))

    def test_explicit_missing_config_is_unavailable(self):
        with self.assertRaises(qualify.Unavailable) as ctx:
            qualify.resolve_docker_config(str(scratch_dir("tests") / "no-such-docker-config"))
        self.assertIn("docker config directory missing", str(ctx.exception))

    def test_cli_missing_config_unavailable_without_launch(self):
        parent = Path(tempfile.mkdtemp(prefix="cfg-", dir=scratch_dir("tests")))
        for name in ("esp.img", "BOOTX64.efi", "zk-kernel", "initramfs.bin", "imginfo.exe"):
            (parent / name).write_bytes(b"x")
        argv = [
            "--esp-image", str(parent / "esp.img"),
            "--loader", str(parent / "BOOTX64.efi"),
            "--kernel", str(parent / "zk-kernel"),
            "--initramfs", str(parent / "initramfs.bin"),
            "--imginfo", str(parent / "imginfo.exe"),
            "--evidence-parent", str(parent / "evidence"),
            "--docker-config", str(parent / "missing-docker-config"),
        ]
        (parent / "evidence").mkdir()
        with mock.patch.object(probe, "run_boot", side_effect=AssertionError("must not launch")), \
             mock.patch.object(qualify, "run_imginfo", return_value="ok"), \
             redirect_stdout(io.StringIO()):
            rc = qualify.main(argv)
        self.assertEqual(rc, 2)


class ScratchTests(unittest.TestCase):
    def test_default_scratch_is_inside_checkout(self):
        with mock.patch.dict(os.environ):
            os.environ.pop("QUALIFY_TEST_SCRATCH", None)
            self.assertEqual(checkout_scratch(), CHECKOUT / "qualify-native-test-scratch")
            self.assertTrue(str(checkout_scratch()).startswith(str(CHECKOUT)))
            self.assertNotIn(str(Path(".tmp") / "kernel-implementation" / "grok-scratch"),
                             str(checkout_scratch()))

    def test_env_scratch_is_honored(self):
        target = scratch_dir("env-honored")
        with mock.patch.dict(os.environ, {"QUALIFY_TEST_SCRATCH": str(target)}):
            self.assertEqual(scratch_root(), target)


class StandaloneCheckoutTests(unittest.TestCase):
    def test_python_modules_run_from_copied_checkout_tree(self):
        root = Path(tempfile.mkdtemp(prefix="standalone-", dir=scratch_dir("tests")))
        dest_scripts = root / "scripts" / "qualify-native"
        dest_tests = root / "tests" / "native-qualification"
        dest_scripts.mkdir(parents=True)
        dest_tests.mkdir(parents=True)
        for name in ("fat16.py", "transcript.py", "probe.py", "qualify.py", "run-tests.py"):
            shutil.copyfile(QUALIFY_DIR / name, dest_scripts / name)
        shutil.copyfile(CHECKOUT / "tests" / "native-qualification" / "common.py", dest_tests / "common.py")
        env = os.environ.copy()
        env["QUALIFY_TEST_SCRATCH"] = str(root / "scratch")
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONPATH"] = str(dest_scripts)
        copied_root = str(root)
        code = (
            "import sys; from pathlib import Path; sys.path.insert(0, r'%s'); import common; "
            "assert common.CHECKOUT == Path(r'%s').resolve(); "
            "assert common.checkout_scratch() == Path(r'%s').resolve() / 'qualify-native-test-scratch'; "
            "print(common.checkout_scratch())"
            % (str(dest_tests), copied_root, copied_root)
        )
        completed = subprocess.run(
            [sys.executable, "-B", "-c", code],
            capture_output=True, text=True, env=env, cwd=str(root), timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("qualify-native-test-scratch", completed.stdout)


class BuildEntryAndScratchOrderTests(unittest.TestCase):
    def test_build_zig_qualify_argv_includes_evidence_parent(self):
        text = (CHECKOUT / "build.zig").read_text(encoding="utf-8")
        qualify_at = text.find("scripts/qualify-native/qualify.py")
        self.assertNotEqual(qualify_at, -1)
        self.assertIn("--evidence-parent", text[qualify_at:qualify_at + 800])

    def test_missing_evidence_parent_is_argparse_error(self):
        with self.assertRaises(SystemExit) as ctx:
            qualify.main([
                "--esp-image", "esp.img",
                "--loader", "BOOTX64.efi",
                "--kernel", "zk-kernel",
                "--initramfs", "initramfs.bin",
                "--imginfo", "imginfo",
            ])
        self.assertEqual(ctx.exception.code, 2)

    def test_qualify_ps1_is_ascii_without_bom(self):
        data = (QUALIFY_DIR / "qualify.ps1").read_bytes()
        self.assertFalse(data.startswith(b"\xef\xbb\xbf"))
        self.assertTrue(all(b < 128 for b in data), "qualify.ps1 must be ASCII for legacy PowerShell")

    @unittest.skipUnless(os.name == "nt", "D-drive policy is Windows-only")
    def test_rejected_c_evidence_parent_does_not_mkdir(self):
        created = []

        def wrapped_mkdir(self, *args, **kwargs):
            created.append(str(self))
            raise AssertionError("mkdir must not run for rejected path")

        argv = [
            "--esp-image", "esp.img",
            "--loader", "BOOTX64.efi",
            "--kernel", "zk-kernel",
            "--initramfs", "initramfs.bin",
            "--imginfo", "imginfo",
            "--evidence-parent", r"C:\zk-qualify-forbidden",
        ]
        with mock.patch.object(Path, "mkdir", wrapped_mkdir), redirect_stdout(io.StringIO()) as out:
            rc = qualify.main(argv)
        self.assertEqual(rc, 2)
        self.assertEqual(created, [])
        self.assertIn("unavailable", out.getvalue())

    @unittest.skipUnless(os.name == "nt", "D-drive policy is Windows-only")
    def test_run_tests_rejects_c_scratch_before_makedirs(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "qualify_run_tests", QUALIFY_DIR / "run-tests.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        created = []

        def fake_makedirs(path, exist_ok=False):
            created.append(path)
            raise AssertionError("makedirs must not run")

        env = {"QUALIFY_TEST_SCRATCH": r"C:\zk-qualify-forbidden-scratch"}
        with mock.patch.dict(os.environ, env, clear=False), \
             mock.patch.object(mod.os, "makedirs", side_effect=fake_makedirs):
            rc = mod.main()
        self.assertEqual(rc, 2)
        self.assertEqual(created, [])


if __name__ == "__main__":
    unittest.main()

