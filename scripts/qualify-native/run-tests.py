#!/usr/bin/env python3
"""Portable native qualifier regression runner. Python 3 stdlib only."""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECKOUT = HERE.parents[1]
TESTS = CHECKOUT / "tests" / "native-qualification"


def resolved_scratch(raw):
    candidate = Path(raw)
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    return candidate.resolve()


def main():
    raw = os.environ.get("QUALIFY_TEST_SCRATCH") or str(CHECKOUT / "qualify-native-test-scratch")
    scratch = resolved_scratch(raw)
    if os.name == "nt" and scratch.drive.upper() != "D:":
        print("qualify-native tests: scratch must be on D:, got %s" % scratch, file=sys.stderr)
        return 2
    os.makedirs(scratch, exist_ok=True)
    os.environ["QUALIFY_TEST_SCRATCH"] = str(scratch)
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    os.environ["PYTHONNOUSERSITE"] = "1"
    os.environ["TMP"] = str(scratch)
    os.environ["TEMP"] = str(scratch)
    os.environ["TMPDIR"] = str(scratch)
    sys.path.insert(0, str(HERE))
    suite = unittest.defaultTestLoader.discover(str(TESTS), pattern="test_*.py")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
