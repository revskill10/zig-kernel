#!/usr/bin/env python3
"""Public native first-slice qualifier. Python 3 standard library only.

Copies loader/kernel/initramfs/ESP into a fresh per-run snapshot, inspects
PE/ELF with imginfo, binds embedded FAT16 bytes to those snapshots, then
boots the snapshot ESP under pinned Docker/QEMU TCG. Corruption and path
mismatch fail before launch. linux_replacement_qualified is always false.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

import fat16
import probe
from probe import Failed, Unavailable

DEFAULT_INITRAMFS_PATH = fat16.DEFAULT_INITRAMFS_PATH
SCOPE = (
    "native firmware/kernel first-slice bootstrap only; "
    "linux_replacement_qualified is always false"
)


def sha_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require_d_output(path):
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    resolved = candidate.resolve()
    if os.name == "nt" and resolved.drive.upper() != "D:":
        raise Unavailable(f"output must be on D:, got {resolved}")
    return resolved


def resolve_docker_config(explicit):
    """Use an explicit directory or inherit the process Docker context.

    Ancestor .tmp/sandbox-container paths are never discovered.
    """
    if explicit is None or explicit == "":
        return None
    path = Path(explicit)
    if not path.is_dir():
        raise Unavailable(f"docker config directory missing: {path}")
    return str(path.resolve())


def run_imginfo(imginfo, kind, path):
    imginfo = Path(imginfo)
    if not imginfo.is_file():
        raise Unavailable(f"imginfo missing: {imginfo}")
    try:
        proc = subprocess.run(
            [str(imginfo), kind, str(path)],
            capture_output=True, text=True, timeout=30,
        )
    except FileNotFoundError as exc:
        raise Unavailable(f"imginfo not executable: {imginfo}") from exc
    except subprocess.TimeoutExpired as exc:
        raise Failed(f"imginfo {kind} timed out") from exc
    text = ((proc.stdout or "") + (proc.stderr or "")).strip()
    if proc.returncode != 0:
        raise Failed(f"imginfo {kind} failed (rc={proc.returncode}): {text}")
    return text


def snapshot_inputs(run, esp, loader, kernel, initramfs):
    inputs = run / "inputs"
    output = run / "output"
    inputs.mkdir()
    output.mkdir()
    mapping = [
        (esp, "esp.img"),
        (loader, "BOOTX64.efi"),
        (kernel, "zk-kernel"),
        (initramfs, "initramfs.bin"),
    ]
    for source, name in mapping:
        src = Path(source)
        if not src.is_file():
            raise Unavailable(f"missing artifact: {src}")
        shutil.copyfile(src, inputs / name)
    artifacts = {
        p.name: {"bytes": p.stat().st_size, "sha256": sha_file(p)}
        for p in inputs.iterdir()
    }
    return inputs, output, artifacts


def write_evidence(run, report):
    report["linux_replacement_qualified"] = False
    path = run / "evidence.json"
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return path


def qualify(args):
    try:
        parent = require_d_output(args.evidence_parent)
    except Unavailable as exc:
        print(json.dumps({
            "status": "unavailable",
            "verdict": "unavailable",
            "linux_replacement_qualified": False,
            "errors": [str(exc)],
            "launched": False,
        }, indent=2))
        return 2
    parent.mkdir(parents=True, exist_ok=True)
    run = parent / ("native-qualify-" + time.strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:8])
    run.mkdir(parents=True, exist_ok=False)
    report = {
        "status": "fail",
        "verdict": "fail",
        "scope": SCOPE,
        "linux_replacement_qualified": False,
        "run_dir": str(run),
        "errors": [],
        "expected_markers": probe.MARKERS,
        "kernel_entry_observed": False,
        "launched": False,
    }
    inputs = None
    try:
        probe.require_timeout(args.timeout)
        probe.require_tcg(args.qemu_accel)
        docker_config = resolve_docker_config(args.docker_config)
        docker_host = args.docker_host or None
        inputs, output, artifacts = snapshot_inputs(
            run, args.esp_image, args.loader, args.kernel, args.initramfs,
        )
        report["inputs"] = artifacts
        report["snapshot_note"] = (
            "hashes describe copied bytes that the guest boots; "
            "embedded ESP files are compared to these snapshots"
        )
        report["imginfo"] = {
            "pe": run_imginfo(args.imginfo, "pe", inputs / "BOOTX64.efi"),
            "elf": run_imginfo(args.imginfo, "elf", inputs / "zk-kernel"),
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
    if report["status"] != "unavailable":
        report["status"] = "pass" if not report["errors"] else "fail"
        report["verdict"] = report["status"]
    report["linux_replacement_qualified"] = False
    evidence = write_evidence(run, report)
    summary = {
        "status": report["status"],
        "verdict": report["verdict"],
        "run_dir": report["run_dir"],
        "kernel_entry_observed": report.get("kernel_entry_observed", False),
        "linux_replacement_qualified": False,
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
    parser.add_argument("--initramfs-path", default=DEFAULT_INITRAMFS_PATH,
                        help="must equal the loader's actual lookup path; no alias guessing")
    parser.add_argument("--qemu-image", default=probe.PINNED_IMAGE_REF)
    parser.add_argument("--qemu-image-id", default=probe.PINNED_IMAGE_ID)
    parser.add_argument("--qemu-accel", choices=["tcg"], default=probe.DEFAULT_ACCEL,
                        help="only tcg is supported; other backends are rejected before launch")
    parser.add_argument("--timeout", type=int, default=45)
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
    return qualify(args)


if __name__ == "__main__":
    raise SystemExit(main())
