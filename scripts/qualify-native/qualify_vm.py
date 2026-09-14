#!/usr/bin/env python3
"""Public CPL0 private-VM mapping qualifier. Python 3 standard library only.

Reuses accepted snapshot, imginfo, FAT16-binding, pinned run_boot and evidence
helpers. Adds native-vm-probe-v1 verdict only after strict VM transcript
checks. Bootstrap errors are kept; a bootstrap-only pass is not VM
acceptance. linux_replacement_qualified, cpl3_execution_qualified and
user_supervisor_isolation_qualified are always false.
"""
from __future__ import annotations

import argparse
import json
import time
import uuid
from pathlib import Path

import fat16
import probe
import qualify
import transcript_vm
from probe import Failed, Unavailable

PROFILE = "native-vm-probe-v1"
SCOPE = (
    "native CPL0 private-VM mapping qualification only; "
    "linux_replacement_qualified, cpl3_execution_qualified and "
    "user_supervisor_isolation_qualified are always false"
)
MODES = transcript_vm.MODES
DEFAULT_TIMEOUT = 90
GUEST_FAIL_EXIT = 47


def _owned_container_id_ok(value):
    if not isinstance(value, str) or len(value) != 64:
        return False
    hexdigits = "0123456789abcdef"
    return all(c in hexdigits for c in value)


def _allowed_negative_error(message):
    if message == "Expected isa-debug-exit status33":
        return True
    if message == "Failed: Expected isa-debug-exit status33":
        return True
    if message.startswith("Failed: ") and message.endswith("Expected isa-debug-exit status33"):
        return True
    if message.startswith("Contradictory or malformed native exit"):
        return True
    if message.startswith("Native exit precedes completion"):
        return True
    if message == "Required native stages missing or out of order":
        return True
    return False


def expected_negative_transport_ok(report):
    """Real launch + pinned binding + guest/attach 47 + owned cleanup.

    Unrelated transport, config, timeout, or cleanup failures are not the
    known skip-switch / writable-RO result. Raw report errors stay intact.
    """
    if report.get("launched") is not True:
        return False
    if report.get("attach_attempted") is not True:
        return False
    if report.get("attach_timed_out"):
        return False
    if (report.get("container_state") or {}).get("ExitCode") != GUEST_FAIL_EXIT:
        return False
    if report.get("docker_start_exit_code") != GUEST_FAIL_EXIT:
        return False
    cleanup = report.get("cleanup") or {}
    if cleanup.get("exit_code") != 0:
        return False
    owned = report.get("owned_container_id")
    if not _owned_container_id_ok(owned):
        return False
    if cleanup.get("container_id") != owned:
        return False
    if report.get("esp_unchanged") is not True:
        return False
    binding = report.get("esp_binding") or {}
    if binding.get("status") != "pass":
        return False
    if report.get("profile") != PROFILE:
        return False
    if report.get("qemu_accel") != "tcg":
        return False
    if report.get("verifier_image") != probe.PINNED_IMAGE_ID:
        return False
    firmware = report.get("firmware_sha256") or {}
    if firmware.get(probe.OVMF_CODE) != probe.PINNED_OVMF_CODE_SHA256:
        return False
    if firmware.get("/out/OVMF_VARS.fd") != probe.PINNED_OVMF_VARS_SHA256:
        return False
    inputs = report.get("inputs") or {}
    kernel = (inputs.get("zk-kernel") or {}).get("sha256")
    if not kernel:
        return False
    if report.get("kernel_sha256") not in (None, kernel):
        return False
    for err in report.get("errors") or []:
        if not _allowed_negative_error(err):
            return False
    return True


def require_vm_timeout(timeout):
    if not isinstance(timeout, int) or isinstance(timeout, bool) or not (75 <= timeout <= 120):
        raise Failed("vm timeout must be an integer between 75 and 120 seconds")


def write_evidence(run, report):
    report["linux_replacement_qualified"] = False
    report["cpl3_execution_qualified"] = False
    report["user_supervisor_isolation_qualified"] = False
    path = run / "evidence.json"
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return path


def apply_vm_transcript(report, output, mode):
    serial_file = output / "serial.log"
    serial = serial_file.read_text(errors="replace") if serial_file.exists() else ""
    parsed = transcript_vm.parse_vm_serial(serial, mode=mode)
    report["vm_transcript"] = {
        "profile": parsed["profile"],
        "mode": parsed["mode"],
        "vm_complete": parsed["vm_complete"],
        "vm_fail": parsed["vm_fail"],
        "fixtures": parsed.get("fixtures", []),
        "transcript_errors": parsed["transcript_errors"],
    }
    report["errors"].extend(parsed["transcript_errors"])
    report["kernel_sha256"] = (report.get("inputs") or {}).get("zk-kernel", {}).get("sha256")
    if parsed.get("fixtures"):
        report["fixture_sha256"] = [item["sha256"] for item in parsed["fixtures"]]
        report["fixture_len"] = [item.get("len") for item in parsed["fixtures"]]
    if mode != "positive":
        fail = parsed.get("vm_fail") or {}
        want_stage = "switch" if mode == "skip-switch" else "fault-ro"
        want_reason = "cr3-readback" if mode == "skip-switch" else "expected-pf"
        transcript_ok = (
            fail.get("stage") == want_stage
            and fail.get("reason") == want_reason
            and not parsed["vm_complete"]
            and not parsed["transcript_errors"]
            and "ZKN: exit code=17" in serial
            and "ZKN: vm-complete" not in serial
            and "ZKN: done" not in serial
        )
        expected_negative = transcript_ok and expected_negative_transport_ok(report)
        if not expected_negative:
            report["errors"].append("expected negative failure was not observed")
        report["expected_negative_observed"] = expected_negative
    else:
        report["expected_negative_observed"] = False
    report["vm_qualified"] = (
        mode == "positive"
        and not parsed["transcript_errors"]
        and parsed["vm_complete"]
        and not report["errors"]
    )


def qualify_vm(args):
    try:
        parent = qualify.require_d_output(args.evidence_parent)
    except Unavailable as exc:
        print(json.dumps({
            "status": "unavailable",
            "verdict": "unavailable",
            "profile": PROFILE,
            "linux_replacement_qualified": False,
            "cpl3_execution_qualified": False,
            "user_supervisor_isolation_qualified": False,
            "vm_qualified": False,
            "errors": [str(exc)],
            "launched": False,
        }, indent=2))
        return 2
    parent.mkdir(parents=True, exist_ok=True)
    run = parent / ("native-vm-qualify-" + time.strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:8])
    run.mkdir(parents=True, exist_ok=False)
    report = {
        "status": "fail",
        "verdict": "fail",
        "profile": PROFILE,
        "scope": SCOPE,
        "mode": args.mode,
        "linux_replacement_qualified": False,
        "cpl3_execution_qualified": False,
        "user_supervisor_isolation_qualified": False,
        "vm_qualified": False,
        "expected_negative_observed": False,
        "run_dir": str(run),
        "errors": [],
        "kernel_entry_observed": False,
        "launched": False,
    }
    output = None
    try:
        require_vm_timeout(args.timeout)
        probe.require_tcg(args.qemu_accel)
        docker_config = qualify.resolve_docker_config(args.docker_config)
        docker_host = args.docker_host or None
        inputs, output, artifacts = qualify.snapshot_inputs(
            run, args.esp_image, args.loader, args.kernel, args.initramfs,
        )
        report["inputs"] = artifacts
        report["snapshot_note"] = (
            "hashes describe copied bytes that the guest boots; "
            "embedded ESP files are compared to these snapshots; "
            "runtime evidence is bound to this kernel digest and mode"
        )
        report["imginfo"] = {
            "pe": qualify.run_imginfo(args.imginfo, "pe", inputs / "BOOTX64.efi"),
            "elf": qualify.run_imginfo(args.imginfo, "elf", inputs / "zk-kernel"),
        }
        initramfs_path = fat16.canonical_path(args.initramfs_path)
        binding, _ = fat16.verify(inputs / "esp.img", [
            (fat16.LOADER_PATH, inputs / "BOOTX64.efi"),
            (fat16.KERNEL_PATH, inputs / "zk-kernel"),
            (initramfs_path, inputs / "initramfs.bin"),
        ])
        (run / "esp-binding.json").write_text(json.dumps(binding, indent=2) + "\n", encoding="utf-8")
        report["esp_binding"] = {
            "status": binding["status"],
            "errors": binding["errors"],
            "comparisons": binding.get("comparisons", []),
            "image_sha256": binding.get("image_sha256"),
            "geometry": binding.get("geometry"),
        }
        if binding["status"] != "pass":
            raise Failed("ESP artifact binding failed: " + "; ".join(binding["errors"]))
        probe.run_boot(
            inputs=inputs,
            output=output,
            report=report,
            timeout=args.timeout,
            image_ref=args.qemu_image,
            image_id=args.qemu_image_id,
            accel=args.qemu_accel,
            docker_host=docker_host,
            docker_config=docker_config,
        )
    except Unavailable as exc:
        report["errors"].append(str(exc))
        report["status"] = "unavailable"
        report["verdict"] = "unavailable"
    except Failed as exc:
        report["errors"].append(str(exc))
        report["status"] = "fail"
        report["verdict"] = "fail"
    except Exception as exc:
        report["errors"].append(type(exc).__name__ + ": " + str(exc))
        report["status"] = "fail"
        report["verdict"] = "fail"
    if output is not None and (report.get("attach_attempted") or (output / "serial.log").exists()):
        try:
            apply_vm_transcript(report, output, args.mode)
        except Exception as exc:
            report["errors"].append("VM transcript failed: " + type(exc).__name__ + ": " + str(exc))
    elif args.mode == "positive" and report.get("launched"):
        report["errors"].append("VM serial evidence missing")
    if args.mode != "positive":
        report["vm_qualified"] = False
        if report["status"] != "unavailable":
            report["status"] = "fail"
            report["verdict"] = "fail"
    elif report["status"] != "unavailable":
        report["status"] = "pass" if not report["errors"] and report.get("vm_qualified") else "fail"
        report["verdict"] = report["status"]
        if report["status"] != "pass":
            report["vm_qualified"] = False
    report["linux_replacement_qualified"] = False
    report["cpl3_execution_qualified"] = False
    report["user_supervisor_isolation_qualified"] = False
    evidence = write_evidence(run, report)
    summary = {
        "status": report["status"],
        "verdict": report["verdict"],
        "profile": PROFILE,
        "mode": args.mode,
        "run_dir": report["run_dir"],
        "vm_qualified": report.get("vm_qualified", False),
        "expected_negative_observed": report.get("expected_negative_observed", False),
        "kernel_entry_observed": report.get("kernel_entry_observed", False),
        "linux_replacement_qualified": False,
        "cpl3_execution_qualified": False,
        "user_supervisor_isolation_qualified": False,
        "launched": report.get("launched", False),
        "errors": report["errors"],
        "evidence": str(evidence),
    }
    print(json.dumps(summary, indent=2))
    if report["status"] == "pass":
        return 0
    if report["status"] == "unavailable":
        return 2
    return 1


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--esp-image", required=True)
    parser.add_argument("--loader", required=True)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--initramfs", required=True)
    parser.add_argument("--imginfo", required=True)
    parser.add_argument("--initramfs-path", default=qualify.DEFAULT_INITRAMFS_PATH,
                        help="must equal the loader's actual lookup path; no alias guessing")
    parser.add_argument("--qemu-image", default=probe.PINNED_IMAGE_REF)
    parser.add_argument("--qemu-image-id", default=probe.PINNED_IMAGE_ID)
    parser.add_argument("--qemu-accel", choices=["tcg"], default=probe.DEFAULT_ACCEL,
                        help="only tcg is supported; other backends are rejected before launch")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                        help="guest timeout in seconds; must be 75-120 for this VM profile")
    parser.add_argument("--mode", choices=list(MODES), default="positive",
                        help="artifact mode: positive, skip-switch, or writable-ro")
    parser.add_argument("--evidence-parent", required=True,
                        help="parent directory for a fresh per-run evidence directory")
    parser.add_argument("--docker-host", default=None,
                        help="optional Docker host override; default inherits the process context")
    parser.add_argument("--docker-config", default=None,
                        help="optional Docker config directory; default inherits the process context")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    return qualify_vm(args)


if __name__ == "__main__":
    raise SystemExit(main())
