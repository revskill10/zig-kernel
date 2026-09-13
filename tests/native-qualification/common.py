"""Shared paths for native qualifier tests.

Scratch is QUALIFY_TEST_SCRATCH when set, otherwise a directory inside the
checkout that contains tests/native-qualification. Coordinator ancestry is
never used.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

CHECKOUT = Path(__file__).resolve().parents[2]
QUALIFY_DIR = CHECKOUT / "scripts" / "qualify-native"
WORKTREE = CHECKOUT

if str(QUALIFY_DIR) not in sys.path:
    sys.path.insert(0, str(QUALIFY_DIR))

os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")


def checkout_scratch():
    return CHECKOUT / "qualify-native-test-scratch"


def scratch_root():
    env = os.environ.get("QUALIFY_TEST_SCRATCH")
    if env:
        return Path(env)
    return checkout_scratch()


def resolved_d_path(path):
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    resolved = candidate.resolve()
    if os.name == "nt" and resolved.drive.upper() != "D:":
        raise RuntimeError("test scratch must be on D:, got %s" % resolved)
    return resolved


def scratch_dir(name):
    root = resolved_d_path(scratch_root())
    path = root / name
    path.mkdir(parents=True, exist_ok=True)
    return path
