"""Minimal FAT16 ESP builder for qualifier tests (stdlib only)."""
from __future__ import annotations

import struct

SECTOR = 512
SPC = 1
CLUSTER = SECTOR * SPC
RESERVED = 1
NFATS = 2
ROOT_ENTRIES = 512
CLUSTER_COUNT = 4085
MEDIA = 0xF8
EOC = 0xFFFF


def name83(name):
    if name in (".", ".."):
        return (name.encode("ascii") + b" " * 11)[:11]
    if "." in name:
        base, ext = name.rsplit(".", 1)
    else:
        base, ext = name, ""
    base = base.upper().encode("ascii")
    ext = ext.upper().encode("ascii")
    if not (1 <= len(base) <= 8 and len(ext) <= 3):
        raise ValueError(name)
    return base.ljust(8) + ext.ljust(3)


def dir_entry(name, attr, cluster, size):
    entry = bytearray(32)
    entry[0:11] = name83(name)
    entry[11] = attr
    struct.pack_into("<H", entry, 26, cluster)
    struct.pack_into("<I", entry, 28, size)
    return bytes(entry)


def fat_sectors_for(clusters):
    need = (clusters + 2) * 2
    return (need + SECTOR - 1) // SECTOR


def build_esp(files):
    """files: mapping of canonical volume paths to bytes, e.g. /ZK/KERNEL.ELF."""
    dirs = set()
    for path in files:
        parts = path.strip("/").split("/")
        for i in range(len(parts) - 1):
            dirs.add("/" + "/".join(parts[: i + 1]))
    dir_list = sorted(dirs, key=lambda p: (p.count("/"), p))
    fat_sectors = fat_sectors_for(CLUSTER_COUNT)
    root_bytes = ROOT_ENTRIES * 32
    data_offset = (RESERVED + NFATS * fat_sectors) * SECTOR + root_bytes
    total = data_offset + CLUSTER_COUNT * CLUSTER
    img = bytearray(total)

    img[0:3] = b"\xEB\x3C\x90"
    img[3:11] = b"ZKNATIVE"
    struct.pack_into("<H", img, 11, SECTOR)
    img[13] = SPC
    struct.pack_into("<H", img, 14, RESERVED)
    img[16] = NFATS
    struct.pack_into("<H", img, 17, ROOT_ENTRIES)
    total_sectors = total // SECTOR
    struct.pack_into("<H", img, 19, total_sectors)
    img[21] = MEDIA
    struct.pack_into("<H", img, 22, fat_sectors)
    struct.pack_into("<H", img, 24, 32)
    struct.pack_into("<H", img, 26, 2)
    img[38] = 0x29
    img[43:54] = b"ZKNATIVE   "
    img[54:62] = b"FAT16   "
    img[510] = 0x55
    img[511] = 0xAA

    next_cluster = 2
    dir_cluster = {}
    for d in dir_list:
        dir_cluster[d] = next_cluster
        next_cluster += 1
    file_cluster = {}
    file_nclusters = {}
    for path, data in files.items():
        if len(data) == 0:
            file_cluster[path] = 0
            file_nclusters[path] = 0
            continue
        n = (len(data) + CLUSTER - 1) // CLUSTER
        file_cluster[path] = next_cluster
        file_nclusters[path] = n
        next_cluster += n
    if next_cluster - 2 > CLUSTER_COUNT:
        raise ValueError("test image too small for payloads")

    fat = bytearray(fat_sectors * SECTOR)
    struct.pack_into("<H", fat, 0, 0xFF00 | MEDIA)
    struct.pack_into("<H", fat, 2, EOC)

    def set_fat(cluster, value):
        struct.pack_into("<H", fat, cluster * 2, value)

    for d, c in dir_cluster.items():
        set_fat(c, EOC)
    for path, start in file_cluster.items():
        n = file_nclusters[path]
        for i in range(n):
            set_fat(start + i, EOC if i + 1 == n else start + i + 1)

    fat_off = RESERVED * SECTOR
    img[fat_off:fat_off + len(fat)] = fat
    img[fat_off + len(fat):fat_off + 2 * len(fat)] = fat

    def parent_of(path):
        path = path.rstrip("/")
        if path.count("/") == 1:
            return "/"
        return path.rsplit("/", 1)[0]

    def children(parent):
        out_dirs = [d for d in dir_list if parent_of(d) == parent]
        out_files = [f for f in files if parent_of(f) == parent]
        return out_dirs, out_files

    def write_dir(buf, parent_path, self_cluster, parent_cluster):
        offset = 0
        if parent_path != "/":
            buf[offset:offset + 32] = dir_entry(".", 0x10, self_cluster, 0)
            offset += 32
            buf[offset:offset + 32] = dir_entry("..", 0x10, parent_cluster, 0)
            offset += 32
        child_dirs, child_files = children(parent_path)
        for d in child_dirs:
            name = d.rsplit("/", 1)[-1]
            buf[offset:offset + 32] = dir_entry(name, 0x10, dir_cluster[d], 0)
            offset += 32
        for f in child_files:
            name = f.rsplit("/", 1)[-1]
            buf[offset:offset + 32] = dir_entry(name, 0x20, file_cluster[f], len(files[f]))
            offset += 32

    root_off = (RESERVED + NFATS * fat_sectors) * SECTOR
    write_dir(memoryview(img)[root_off:root_off + root_bytes], "/", 0, 0)

    def cluster_off(c):
        return data_offset + (c - 2) * CLUSTER

    for d, c in dir_cluster.items():
        parent = d.rsplit("/", 1)[0] or "/"
        parent_c = 0 if parent == "/" else dir_cluster[parent]
        buf = memoryview(img)[cluster_off(c):cluster_off(c) + CLUSTER]
        write_dir(buf, d, c, parent_c)

    for path, data in files.items():
        start = file_cluster[path]
        if start == 0:
            continue
        off = cluster_off(start)
        img[off:off + len(data)] = data

    return bytes(img)


def standard_esp(loader=b"LOADER", kernel=b"KERNEL", initrd=b"INITRD"):
    return build_esp({
        "/EFI/BOOT/BOOTX64.EFI": loader,
        "/ZK/KERNEL.ELF": kernel,
        "/ZK/INITRD.BIN": initrd,
    })
