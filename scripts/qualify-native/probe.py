"""Docker/QEMU TCG first-slice boot probe. No hosted QEMU fallback.

Pinned image and firmware hashes are required. The verifier image ENTRYPOINT
is qemu-system-x86_64, so every create uses --entrypoint /bin/sh. Cleanup
removes only the owned container ID (or a name+label+image recovered ID).
Wildcard container/process deletion is forbidden.
"""
from __future__ import annotations

import hashlib
import json
import os
import shlex
import subprocess
import uuid
from pathlib import Path

from transcript import MARKERS, parse_serial

PINNED_IMAGE_REF = "zig-kernel-qemu-verifier:local"
PINNED_IMAGE_ID = "sha256:8385adfe772b198700e89273eb4d4243f89ee6c1e3367bf2661f1a0d33c9e458"
PINNED_OVMF_CODE_SHA256 = "d9b568def24088c92f34b5479e0ed7e44d0a4d4cea8a0f5716719180bba48106"
PINNED_OVMF_VARS_SHA256 = "6ed987af3a3c155be71665f510eae3e007eda9b8b94afd59d45e91c4a11565cc"
DEFAULT_ACCEL = "tcg"
ALLOWED_ACCEL = frozenset({"tcg"})
OWNER_LABEL = "zig-native.qualify-owner"
OVMF_CODE = "/usr/share/OVMF/OVMF_CODE.fd"
OVMF_VARS = "/usr/share/OVMF/OVMF_VARS.fd"
SCOPE = "native firmware/kernel bootstrap smoke only; not a Linux replacement"


class Unavailable(Exception):
    """Missing Docker, pinned image, or firmware. Never a pass."""


class Failed(Exception):
    """Probe launched or artifacts were present but the run is not success."""


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def decode(value):
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")


def valid_cid(candidate):
    return len(candidate) == 64 and all(c in "0123456789abcdef" for c in candidate)


def docker_env(docker_host, docker_config):
    """Inherit the process Docker context. Only explicit overrides are injected."""
    env = os.environ.copy()
    if docker_host:
        env["DOCKER_HOST"] = docker_host
    if docker_config:
        env["DOCKER_CONFIG"] = str(docker_config)
    return env


def require_tcg(accel):
    if accel != "tcg":
        raise Failed(f"unsupported qemu backend {accel!r}; only tcg is supported for this slice")


def require_timeout(timeout):
    if not isinstance(timeout, int) or isinstance(timeout, bool) or not (5 <= timeout <= 120):
        raise Failed("timeout must be an integer between 5 and 120 seconds")


def docker(args, timeout=20, docker_host=None, docker_config=None):
    env = docker_env(docker_host, docker_config)
    return subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout, env=env)


def collect_serial(output, report):
    """Called after cleanup even when attach/inspect fails; preserve raw serial."""
    serial_file = output / "serial.log"
    serial = serial_file.read_text(errors="replace") if serial_file.exists() else ""
    report["serial_sha256"] = digest(serial_file) if serial_file.exists() else None
    parsed = parse_serial(serial)
    report.update(parsed)
    report["errors"].extend(parsed["transcript_errors"])


def recover_creation(name, token, image_id, report, docker_host, docker_config):
    """Name is a lookup only; ownership requires exact nonce label AND image."""
    report["creation_ownership_unresolved"] = True
    try:
        inspected = docker(["inspect", "--type", "container", name],
                           docker_host=docker_host, docker_config=docker_config)
        if inspected.returncode:
            report["creation_reconciliation"] = {
                "status": "unresolved",
                "exit_code": inspected.returncode,
                "stderr": inspected.stderr,
            }
            return None
        records = json.loads(inspected.stdout)
        if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
            raise ValueError("Expected one container inspect record")
        item = records[0]
        candidate = item.get("Id", "")
        labels = (item.get("Config") or {}).get("Labels") or {}
        matches = (valid_cid(candidate) and item.get("Name") == "/" + name and
                   labels.get(OWNER_LABEL) == token and item.get("Image") == image_id)
        report["creation_reconciliation"] = {
            "status": "recovered" if matches else "ownership-mismatch",
            "inspected_id": candidate,
        }
        if not matches:
            return None
        report["creation_ownership_unresolved"] = False
        return candidate
    except Exception as exc:
        report["creation_reconciliation"] = {
            "status": "unresolved",
            "error": type(exc).__name__ + ": " + str(exc),
        }
        return None


def attach(cid, timeout, output, report, docker_host, docker_config):
    report["attach_attempted"] = True
    try:
        started = docker(["start", "-a", cid], timeout=timeout + 15,
                         docker_host=docker_host, docker_config=docker_config)
    except subprocess.TimeoutExpired as exc:
        report["attach_timed_out"] = True
        report["docker_start_exit_code"] = None
        (output / "container-stdout.log").write_text(decode(exc.stdout), encoding="utf-8")
        (output / "container-stderr.log").write_text(decode(exc.stderr), encoding="utf-8")
        raise
    (output / "container-stdout.log").write_text(decode(started.stdout), encoding="utf-8")
    (output / "container-stderr.log").write_text(decode(started.stderr), encoding="utf-8")
    report["docker_start_exit_code"] = started.returncode
    return started


def resolve_pinned_image(image_ref, image_id, docker_host, docker_config):
    try:
        inspected = docker(["image", "inspect", "--format", "{{.Id}}", image_ref],
                           docker_host=docker_host, docker_config=docker_config)
    except FileNotFoundError as exc:
        raise Unavailable("Docker CLI unavailable") from exc
    except subprocess.TimeoutExpired as exc:
        raise Unavailable("Docker image inspect timed out") from exc
    except OSError as exc:
        raise Unavailable("Docker engine unavailable: " + str(exc)) from exc
    if inspected.returncode:
        detail = (inspected.stderr or inspected.stdout or "").strip()
        raise Unavailable("Docker verifier image unavailable: " + detail)
    resolved = inspected.stdout.strip()
    if not resolved.startswith("sha256:") or not valid_cid(resolved[7:]):
        raise Unavailable("Invalid verifier image identity")
    if resolved != image_id:
        raise Unavailable(
            f"Pinned verifier image {image_id} is not present; {image_ref} resolved to {resolved}"
        )
    return resolved


def parse_firmware_hashes(text):
    hashes = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            hashes[parts[1].lstrip("*")] = parts[0].lower()
    return hashes


def guest_command(timeout, accel):
    require_tcg(accel)
    require_timeout(timeout)
    code = shlex.quote(OVMF_CODE)
    vars_path = shlex.quote(OVMF_VARS)
    qemu = [
        "qemu-system-x86_64",
        "-machine", "q35",
        "-cpu", "qemu64",
        "-accel", "tcg",
        "-m", "256",
        "-drive", "if=pflash,format=raw,readonly=on,file=" + OVMF_CODE,
        "-drive", "if=pflash,format=raw,file=/out/OVMF_VARS.fd",
        "-drive", "if=ide,format=raw,file=/inputs/esp.img,snapshot=on",
        "-serial", "file:/out/serial.log",
        "-display", "none",
        "-monitor", "none",
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
        "-no-reboot",
    ]
    qemu_s = " ".join(shlex.quote(part) for part in qemu)
    return (
        f"if [ ! -f {code} ] || [ ! -f {vars_path} ]; then "
        "echo firmware-missing > /out/firmware-missing.txt; exit 2; fi && "
        f"cp {vars_path} /out/OVMF_VARS.fd && "
        f"sha256sum {code} /out/OVMF_VARS.fd > /out/firmware-sha256.txt && "
        "qemu-system-x86_64 --version > /out/qemu-version.txt && "
        f"timeout -k 3 {shlex.quote(str(timeout))} {qemu_s}"
    )


def run_boot(*, inputs, output, report, timeout, image_ref, image_id, accel,
             docker_host, docker_config):
    """Launch the pinned TCG guest. Mutates report. Cleanup is always attempted."""
    cid = None
    cidfile = output.parent / "container.cid"
    owner_token = uuid.uuid4().hex
    container_name = "native-qualify-" + owner_token
    create_attempted = False
    report["creation_identity"] = {"name": container_name, "label": OWNER_LABEL, "token": owner_token}
    report["expected_markers"] = MARKERS
    report.setdefault("kernel_entry_observed", False)
    report["linux_replacement_qualified"] = False
    report["scope"] = SCOPE
    report["qemu_accel"] = accel
    report["docker_host"] = docker_host
    if docker_config:
        report["docker_config"] = str(docker_config)
    try:
        require_tcg(accel)
        require_timeout(timeout)
        resolved = resolve_pinned_image(image_ref, image_id, docker_host, docker_config)
        report["verifier_image"] = resolved
        report["verifier_image_ref"] = image_ref
        command = guest_command(timeout, accel)
        report["guest_command"] = command
        create_args = [
            "create", "--cidfile", str(cidfile), "--name", container_name,
            "--label", OWNER_LABEL + "=" + owner_token,
            "--network", "none", "--read-only", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--pids-limit", "128", "--memory", "768m",
            "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m",
            "--tmpfs", "/var/tmp:rw,nosuid,nodev,size=64m",
            "--mount", f"type=bind,src={inputs},dst=/inputs,readonly",
            "--mount", f"type=bind,src={output},dst=/out",
            "--entrypoint", "/bin/sh", resolved, "-c", command,
        ]
        try:
            create_attempted = True
            created = docker(create_args, docker_host=docker_host, docker_config=docker_config)
        finally:
            if cidfile.exists():
                candidate = cidfile.read_text().strip()
                if valid_cid(candidate):
                    cid = candidate
        if created.returncode or cid is None:
            raise Failed("Docker create failed or did not yield owned container ID")
        report["owned_container_id"] = cid
        report["launched"] = True
        started = attach(cid, timeout, output, report, docker_host, docker_config)
        if (output / "firmware-missing.txt").exists():
            raise Unavailable("OVMF firmware missing inside verifier image")
        firmware_file = output / "firmware-sha256.txt"
        if firmware_file.exists():
            firmware = parse_firmware_hashes(firmware_file.read_text(errors="replace"))
            report["firmware_sha256"] = firmware
            code_hash = firmware.get(OVMF_CODE)
            vars_hash = firmware.get("/out/OVMF_VARS.fd")
            if code_hash != PINNED_OVMF_CODE_SHA256 or vars_hash != PINNED_OVMF_VARS_SHA256:
                report["errors"].append(
                    "Pinned firmware hash mismatch: "
                    f"code={code_hash} vars={vars_hash}"
                )
        else:
            report["errors"].append("Firmware hash evidence missing")
        state = docker(["inspect", "--format", "{{json .State}}", cid],
                       docker_host=docker_host, docker_config=docker_config)
        if state.returncode:
            raise Failed("Cannot inspect completed native probe")
        report["container_state"] = json.loads(state.stdout)
        if report["container_state"].get("ExitCode") != 33 or started.returncode != 33:
            report["errors"].append("Expected isa-debug-exit status33")
    except Unavailable as exc:
        report["errors"].append(type(exc).__name__ + ": " + str(exc))
        raise
    except Failed as exc:
        report["errors"].append(type(exc).__name__ + ": " + str(exc))
        raise
    except Exception as exc:
        report["errors"].append(type(exc).__name__ + ": " + str(exc))
    finally:
        if create_attempted and cid is None:
            image_for_recovery = report.get("verifier_image") or image_id
            cid = recover_creation(container_name, owner_token, image_for_recovery, report,
                                   docker_host, docker_config)
            if cid is None:
                report["errors"].append(
                    "Container creation ownership unresolved; see recorded name/label/image"
                )
        if cid is not None:
            report["owned_container_id"] = cid
            try:
                removed = docker(["rm", "-f", cid],
                                 docker_host=docker_host, docker_config=docker_config)
                report["cleanup"] = {"container_id": cid, "exit_code": removed.returncode}
                if removed.returncode:
                    report["errors"].append("Owned container removal failed")
            except Exception as exc:
                report["errors"].append("Cleanup failed: " + type(exc).__name__)
        if report.get("attach_attempted") or (output / "serial.log").exists():
            try:
                collect_serial(output, report)
            except Exception as exc:
                report["errors"].append(
                    "Serial evidence failed: " + type(exc).__name__ + ": " + str(exc)
                )
        esp = inputs / "esp.img"
        if esp.exists() and "esp.img" in report.get("inputs", {}):
            try:
                report["esp_unchanged"] = digest(esp) == report["inputs"]["esp.img"]["sha256"]
                if not report["esp_unchanged"]:
                    report["errors"].append("Boot input ESP changed")
            except Exception as exc:
                report["errors"].append("ESP rehash failed: " + type(exc).__name__ + ": " + str(exc))
        report["linux_replacement_qualified"] = False
