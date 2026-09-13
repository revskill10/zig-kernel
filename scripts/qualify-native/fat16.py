#!/usr/bin/env python3
"""Bounded FAT16 ESP artifact binding. Python 3 stdlib only.

Supported profile (intentional, not a generic ISO/GPT/FAT parser):
- raw unpartitioned FAT16 volume
- 512-byte sectors
- two identical FAT copies
- ASCII 8.3 short names only
- image size <= 128 MiB
- directory depth <= 8, at most 4096 named entries

FAT12/32, partitioned/hidden-sector volumes, LFN, volume labels and other
attribute/name variants fail explicitly. This module never guesses path
aliases and never claims El Torito/ISO9660/UDF coverage.
"""
from __future__ import annotations

import hashlib
import struct
from pathlib import Path

MAX_IMAGE = 128 * 1024 * 1024
LOADER_PATH = "/EFI/BOOT/BOOTX64.EFI"
KERNEL_PATH = "/ZK/KERNEL.ELF"
DEFAULT_INITRAMFS_PATH = "/ZK/INITRD.BIN"
SCOPE = (
    "ESP paths and artifact-byte binding only; raw FAT16 short names; "
    "no ISO/GPT/LFN/native-boot qualification"
)


class InvalidESP(ValueError):
    pass


def check(condition, message):
    if not condition:
        raise InvalidESP(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_bounded(path, maximum=MAX_IMAGE):
    with Path(path).open("rb") as handle:
        data = handle.read(maximum + 1)
    check(len(data) <= maximum, f"input exceeds {maximum} bytes: {path}")
    return data


def canonical_path(value):
    value = value.replace("\\", "/")
    parts = value.split("/")
    check(value.startswith("/") and len(parts) > 1,
          f"expected absolute volume path: {value!r}")
    check(all(p and p not in (".", "..") and p.isascii() for p in parts[1:]),
          f"invalid volume path: {value!r}")
    return "/" + "/".join(p.upper() for p in parts[1:])


class FAT16:
    def __init__(self, data):
        self.data = data
        check(512 <= len(data) <= MAX_IMAGE, "invalid image size")
        check(data[510:512] == b"\x55\xaa", "missing boot signature")
        check(self.u16(11) == 512, "only 512-byte sector volumes supported")
        self.spc = data[13]
        check(self.spc in (1, 2, 4, 8, 16, 32, 64, 128), "invalid sectors per cluster")
        self.cluster_bytes = 512 * self.spc
        reserved, nfats, roots = self.u16(14), data[16], self.u16(17)
        check(reserved >= 1 and nfats == 2, "expected reserved sectors and two FATs")
        check(0 < roots <= 4096 and roots % 16 == 0, "unsupported root entry count")
        self.root_entries = roots
        total16, total32 = self.u16(19), self.u32(32)
        check(bool(total16) != bool(total32), "exactly one total-sector field must be set")
        total = total16 or total32
        check(total * 512 == len(data), "declared volume size differs from input length")
        check(self.u32(28) == 0, "partitioned/hidden-sector volume unsupported")
        fat_sectors = self.u16(22)
        check(fat_sectors > 0, "FAT16 sectors-per-FAT is zero")
        self.fat_offset = reserved * 512
        self.fat_bytes = fat_sectors * 512
        self.root_offset = (reserved + nfats * fat_sectors) * 512
        self.data_offset = self.root_offset + roots * 32
        check(self.data_offset < len(data), "metadata extends outside image")
        self.cluster_count = (len(data) - self.data_offset) // self.cluster_bytes
        check(4085 <= self.cluster_count < 65525, "cluster count is not FAT16")
        check((self.cluster_count + 2) * 2 <= self.fat_bytes, "FAT too short for data clusters")
        first = data[self.fat_offset:self.fat_offset + self.fat_bytes]
        second = data[self.fat_offset + self.fat_bytes:self.root_offset]
        check(first == second, "FAT copies differ")
        check(self.fat(0) == (0xFF00 | data[21]) and self.fat(1) >= 0xFFF8,
              "invalid FAT reserved/media entries")
        self.claimed = {}
        self.files = {}
        self.entries = []
        self.paths = set()
        self.walk(data[self.root_offset:self.data_offset], "/", 0, 0, self.root_offset, 0)
        for cluster in range(2, self.cluster_count + 2):
            if self.fat(cluster) != 0:
                check(cluster in self.claimed, f"allocated cluster {cluster} is unreachable")

    def u16(self, offset):
        return struct.unpack_from("<H", self.data, offset)[0]

    def u32(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0]

    def fat(self, cluster):
        return self.u16(self.fat_offset + cluster * 2)

    def cluster_offset(self, cluster):
        check(2 <= cluster < self.cluster_count + 2, f"cluster {cluster} outside data region")
        offset = self.data_offset + (cluster - 2) * self.cluster_bytes
        check(offset + self.cluster_bytes <= len(self.data), "cluster extends beyond image")
        return offset

    def chain(self, start, owner):
        clusters = []
        seen = set()
        current = start
        while True:
            check(current < 0xFFF0, f"reserved cluster identifier {current:#x} for {owner}")
            self.cluster_offset(current)
            check(current not in seen, f"cycle in cluster chain for {owner}: {current}")
            check(current not in self.claimed,
                  f"cross-linked cluster {current} for {owner} and {self.claimed.get(current)}")
            seen.add(current)
            self.claimed[current] = owner
            clusters.append(current)
            following = self.fat(current)
            if following >= 0xFFF8:
                break
            check(2 <= following < 0xFFF0, f"bad/free/reserved FAT link {following:#x} for {owner}")
            current = following
        return clusters

    @staticmethod
    def name(raw):
        if raw in (b".          ", b"..         "):
            return raw.rstrip().decode("ascii")
        check(all(32 <= c < 127 for c in raw), "non-ASCII short filename unsupported")
        base, ext = raw[:8].rstrip(b" "), raw[8:].rstrip(b" ")
        check(bool(base) and b" " not in base + ext, "invalid short filename padding")
        forbidden = b'"*+,./:;<=>?[\\]|'
        check(not any(c in forbidden for c in base + ext), "invalid short filename character")
        value = base.decode("ascii") + ("." + ext.decode("ascii") if ext else "")
        check(value == value.upper(), "lowercase on-disk short name unsupported")
        return value

    def walk(self, buf, directory, cluster, parent, base_offset, depth, offsets=None):
        check(depth <= 8, "directory nesting exceeds verifier profile")
        names = set()
        dots = set()
        for offset in range(0, len(buf), 32):
            entry = buf[offset:offset + 32]
            if entry[0] == 0:
                break
            if entry[0] == 0xE5:
                continue
            attr = entry[11]
            check(attr != 0x0F, "LFN directory entry unsupported; requires separate verifier profile")
            check(attr in (0x10, 0x20), f"unsupported directory attributes {attr:#x}")
            check(entry[12] == 0 and entry[20:22] == b"\0\0", "unsupported name-case/high-cluster fields")
            name = self.name(entry[:11])
            check(name not in names, f"duplicate path {directory}{name}")
            names.add(name)
            first = struct.unpack_from("<H", entry, 26)[0]
            size = struct.unpack_from("<I", entry, 28)[0]
            if name in (".", ".."):
                check(directory != "/" and attr == 0x10 and size == 0, "invalid dot entry")
                check(first == (cluster if name == "." else parent), "dot entry cluster mismatch")
                dots.add(name)
                continue
            path = directory + name
            check(path not in self.paths, f"duplicate path {path}")
            self.paths.add(path)
            check(len(self.paths) <= 4096, "directory entry count exceeds verifier profile")
            absolute = base_offset + offset if offsets is None else offsets[offset // self.cluster_bytes] + offset % self.cluster_bytes
            rec = {"path": path, "raw_name83": entry[:11].decode("ascii"),
                   "entry_offset": absolute, "cluster": first, "size": size,
                   "type": "directory" if attr == 0x10 else "file"}
            self.entries.append(rec)
            if attr == 0x20 and size == 0:
                check(first == 0, f"empty file {path} must have cluster zero")
                chains = []
            else:
                chains = self.chain(first, path)
            if attr == 0x20:
                needed = (size + self.cluster_bytes - 1) // self.cluster_bytes
                check(len(chains) == needed, f"chain length does not match file size for {path}")
            positions = [self.cluster_offset(c) for c in chains]
            payload = b"".join(self.data[p:p + self.cluster_bytes] for p in positions)
            rec["clusters"] = chains
            if attr == 0x10:
                check(size == 0, f"directory {path} has nonzero size")
                self.walk(payload, path + "/", first, cluster, positions[0], depth + 1, positions)
            else:
                content = payload[:size]
                rec["sha256"] = sha(content)
                self.files[path] = content
        if directory != "/":
            check(dots == {".", ".."}, f"missing dot entries in {directory}")

    def geometry(self):
        return {"format": "raw-fat16-short-names", "sector_bytes": 512,
                "cluster_bytes": self.cluster_bytes, "clusters": self.cluster_count,
                "fat_offset": self.fat_offset, "fat_bytes": self.fat_bytes,
                "root_offset": self.root_offset, "data_offset": self.data_offset,
                "limits": "raw FAT16 8.3 only; not ISO/GPT/FAT32/LFN"}


def verify(image, expected):
    report = {"status": "fail", "scope": SCOPE,
              "image": str(Path(image).resolve()), "comparisons": [], "errors": []}
    volume = None
    try:
        data = read_bounded(image)
        report["image_sha256"] = sha(data)
        report["image_bytes"] = len(data)
        volume = FAT16(data)
        report["geometry"] = volume.geometry()
        report["entries"] = volume.entries
        used = set()
        for logical, external in expected:
            logical = canonical_path(logical)
            check(logical not in used, f"duplicate expected path {logical}")
            used.add(logical)
            actual = volume.files.get(logical)
            wanted = read_bounded(external)
            item = {"path": logical, "external": str(Path(external).resolve()),
                    "external_bytes": len(wanted), "external_sha256": sha(wanted),
                    "embedded_bytes": len(actual) if actual is not None else None,
                    "embedded_sha256": sha(actual) if actual is not None else None,
                    "match": actual == wanted if actual is not None else False}
            report["comparisons"].append(item)
            if not item["match"]:
                report["errors"].append(("missing path: " if actual is None else "artifact mismatch: ") + logical)
        report["status"] = "fail" if report["errors"] else "pass"
    except (InvalidESP, OSError, struct.error) as exc:
        report["errors"].append(str(exc))
        report["status"] = "fail"
    return report, volume
