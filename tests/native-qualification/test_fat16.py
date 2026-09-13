#!/usr/bin/env python3
"""ESP binding negatives: corruption, mismatch, missing path, no aliasing."""
from __future__ import annotations

import struct
import tempfile
import unittest
from pathlib import Path

from common import QUALIFY_DIR, scratch_dir
import esp_image as img

import fat16 as v


class Fat16BindingTests(unittest.TestCase):
    def setUp(self):
        self.loader = b"L" * 64
        self.kernel = b"K" * 600
        self.initrd = b"I" * 32
        self.raw = img.standard_esp(self.loader, self.kernel, self.initrd)
        self.volume = v.FAT16(self.raw)
        self.scratch = Path(tempfile.mkdtemp(prefix="fat16-", dir=scratch_dir("tests")))
        self.image = self.scratch / "esp.img"
        self.image.write_bytes(self.raw)
        (self.scratch / "BOOTX64.efi").write_bytes(self.loader)
        (self.scratch / "zk-kernel").write_bytes(self.kernel)
        (self.scratch / "initramfs.bin").write_bytes(self.initrd)
        self.expected = [
            ("/EFI/BOOT/BOOTX64.EFI", self.scratch / "BOOTX64.efi"),
            ("/ZK/KERNEL.ELF", self.scratch / "zk-kernel"),
            ("/ZK/INITRD.BIN", self.scratch / "initramfs.bin"),
        ]
        self.records = {e["path"]: e for e in self.volume.entries}

    def expected_ok(self):
        report, _ = v.verify(self.image, self.expected)
        self.assertEqual(report["status"], "pass", report["errors"])
        self.assertEqual(report["scope"], v.SCOPE)
        self.assertTrue(all(c["match"] for c in report["comparisons"]))

    def test_standard_layout_binds_initrd_not_initramfs_alias(self):
        self.expected_ok()
        report, _ = v.verify(self.image, self.expected[:2] + [
            ("/ZK/INITRAMFS.BIN", self.scratch / "initramfs.bin"),
        ])
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["errors"], ["missing path: /ZK/INITRAMFS.BIN"])

    def test_external_artifact_mismatch_fails_before_any_boot(self):
        bad = bytearray(self.kernel)
        bad[-1] ^= 1
        (self.scratch / "wrong-kernel.bin").write_bytes(bad)
        report, _ = v.verify(self.image, [
            self.expected[0],
            ("/ZK/KERNEL.ELF", self.scratch / "wrong-kernel.bin"),
            self.expected[2],
        ])
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["errors"], ["artifact mismatch: /ZK/KERNEL.ELF"])

    def test_embedded_artifact_mismatch_fails(self):
        kernel = self.records["/ZK/KERNEL.ELF"]
        mutated = bytearray(self.raw)
        mutated[self.volume.cluster_offset(kernel["cluster"])] ^= 1
        wrong = self.scratch / "wrong-embedded.img"
        wrong.write_bytes(mutated)
        report, _ = v.verify(wrong, self.expected)
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["errors"], ["artifact mismatch: /ZK/KERNEL.ELF"])
        self.assertEqual(v.sha(v.read_bounded(self.image)), v.sha(self.raw))

    def rejects(self, mutation, text):
        data = bytearray(self.raw)
        mutation(data)
        with self.assertRaises(v.InvalidESP) as ctx:
            v.FAT16(bytes(data))
        self.assertIn(text, str(ctx.exception))

    def set_fat(self, data, cluster, value):
        for copy in range(2):
            struct.pack_into("<H", data, self.volume.fat_offset + copy * self.volume.fat_bytes + cluster * 2, value)

    def test_fat_copies_disagree(self):
        self.rejects(lambda d: d.__setitem__(self.volume.fat_offset + 20, d[self.volume.fat_offset + 20] ^ 1),
                     "FAT copies differ")

    def test_kernel_chain_cycle(self):
        kernel = self.records["/ZK/KERNEL.ELF"]
        self.rejects(lambda d: self.set_fat(d, kernel["cluster"], kernel["cluster"]), "cycle in cluster chain")

    def test_bad_free_reserved_links(self):
        kernel = self.records["/ZK/KERNEL.ELF"]
        self.rejects(lambda d: self.set_fat(d, kernel["cluster"], 0xFFF7), "bad/free/reserved")
        self.rejects(lambda d: self.set_fat(d, kernel["cluster"], 0), "bad/free/reserved")
        self.rejects(lambda d: self.set_fat(d, kernel["cluster"], 0xFFF0), "bad/free/reserved")

    def test_outside_data_and_size_mismatch(self):
        kernel = self.records["/ZK/KERNEL.ELF"]
        self.rejects(lambda d: self.set_fat(d, kernel["cluster"], self.volume.cluster_count + 2), "outside data region")
        self.rejects(lambda d: struct.pack_into("<H", d, kernel["entry_offset"] + 26, self.volume.cluster_count + 2),
                     "outside data region")
        self.rejects(lambda d: struct.pack_into("<I", d, kernel["entry_offset"] + 28, kernel["size"] + self.volume.cluster_bytes),
                     "chain length does not match")
        self.rejects(lambda d: self.set_fat(d, kernel["cluster"], 0xFFFF), "chain length does not match")

    def test_duplicate_and_crosslink_and_lfn(self):
        init = self.records["/ZK/INITRD.BIN"]
        kernel = self.records["/ZK/KERNEL.ELF"]
        self.rejects(lambda d: d.__setitem__(slice(init["entry_offset"], init["entry_offset"] + 11), b"KERNEL  ELF"),
                     "duplicate path")
        self.rejects(lambda d: struct.pack_into("<H", d, init["entry_offset"] + 26, kernel["cluster"]),
                     "cross-linked cluster")
        self.rejects(lambda d: d.__setitem__(init["entry_offset"] + 11, 0x0F),
                     "LFN directory entry unsupported")

    def test_truncated_and_metadata_outside(self):
        self.rejects(lambda d: d.pop(), "declared volume size differs")
        self.rejects(lambda d: struct.pack_into("<H", d, 22, 65535), "metadata extends outside")

    def test_not_generic_iso_claim(self):
        self.assertIn("no ISO/GPT/LFN/native-boot qualification", v.SCOPE)
        self.assertIn("raw-fat16-short-names", self.volume.geometry()["format"])


if __name__ == "__main__":
    unittest.main()
