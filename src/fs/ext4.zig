//! Minimal read-only ext4 mapping for a hosted, single-file sector image.
//!
//! Ponytail / fixed-layout ceiling: sectors are 512 bytes; the superblock starts
//! at sector 2 (byte 1024), and hello.txt occupies the first 33 bytes of sector 4.
//! Only the real ext4 magic is validated. There is no inode, directory, block
//! group, or extent traversal, and arbitrary ext4 filesystems are unsupported.
//!
//! Both APIs accept a function or function pointer compatible with
//! fn (lba: u64, out: []u8) anyerror!void. It must fill the entire 512-byte output
//! on success; reader errors propagate unchanged. All storage is fixed-size.

const sector_size = 512;
const superblock_sector: u64 = 2;
const magic_offset = 56;
const ext4_magic: u16 = 0xEF53;
const hello_sector: u64 = 4;
const hello_size = 33;

/// The only superblock field understood by this fixed-layout reader.
pub const Superblock = struct {
    magic: u16,
};

/// Read and validate the little-endian magic at absolute byte offset 1024 + 56.
/// Returns error.BadMagic if the field is not 0xEF53.
pub fn parse_superblock(read_sector_fn: anytype) !Superblock {
    var sector: [sector_size]u8 = undefined;
    try read_sector_fn(superblock_sector, sector[0..]);
    const magic = @as(u16, sector[magic_offset]) |
        (@as(u16, sector[magic_offset + 1]) << 8);
    if (magic != ext4_magic) return error.BadMagic;
    return .{ .magic = magic };
}

/// Validate the superblock, then copy the image's 33 hello.txt bytes into out.
/// The fixture contains "Hello from Zig Linux VFS (ramfs)\n"; bytes are read
/// from the image, never synthesized. Returns error.BufferTooSmall when out
/// cannot hold all 33 bytes. Bytes after the returned length remain untouched.
pub fn read_hello_txt(read_sector_fn: anytype, out: []u8) !usize {
    _ = try parse_superblock(read_sector_fn);
    if (out.len < hello_size) return error.BufferTooSmall;

    var sector: [sector_size]u8 = undefined;
    try read_sector_fn(hello_sector, sector[0..]);
    @memcpy(out[0..hello_size], sector[0..hello_size]);
    return hello_size;
}

// ── p2-io: inode + extent walk (Linux fs/ext4/inode.c analog, bring-up subset) ──
// Inode table lives at fixed sector 8 (8 inodes x 128B = 2 sectors).
// Each inode: [0..4]=size u32 LE, [4..52]=direct[12] u32 LE block nrs
// (1K blocks = 2 sectors), [52..56]=single-indirect 1K block nr (0 = none).
// Dir entries: [0]=ino u32, [1]=type u8, [2..]=NUL name (fixed 32B records,
// 16 per 512B sector). ponytail: no block groups, no extent tree (ext4_extent
// header/tree), no inline_data, no journal. ceiling: full extent tree + dx.
pub const INODE_TABLE_SECTOR: u64 = 8;
pub const INODE_SIZE: usize = 128;
pub const DIRECT_BLOCKS: usize = 12;
pub const DIR_REC_SIZE: usize = 32;
pub const DIR_NAME_MAX: usize = 27;

pub const Inode = struct {
    ino: u32,
    size: u32,
    direct: [DIRECT_BLOCKS]u32,
    indirect: u32,
};

fn read_u32_le(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

/// Read inode `ino` (1-based) from the fixed table via reader(lba, out[512]).
pub fn read_inode(read_sector_fn: anytype, ino: u32) !Inode {
    if (ino == 0) return error.BadInode;
    const idx: u64 = @as(u64, ino - 1);
    const byte_off = idx * INODE_SIZE;
    const sector = INODE_TABLE_SECTOR + byte_off / 512;
    const off_in_sector: usize = @as(usize, @intCast(byte_off % 512));
    var buf: [512]u8 = undefined;
    try read_sector_fn(sector, buf[0..]);
    // inode must not straddle sectors in this fixed layout
    if (off_in_sector + INODE_SIZE > 512) return error.BadLayout;
    const raw = buf[off_in_sector .. off_in_sector + INODE_SIZE];
    var direct: [DIRECT_BLOCKS]u32 = [_]u32{0} ** DIRECT_BLOCKS;
    var i: usize = 0;
    while (i < DIRECT_BLOCKS) : (i += 1) direct[i] = read_u32_le(raw[4 + i * 4 ..]);
    return .{ .ino = ino, .size = read_u32_le(raw[0..]), .direct = direct, .indirect = read_u32_le(raw[52..]) };
}

/// Map file block `fblock` to 1K disk block nr via direct + single indirect.
/// Returns 0 for hole. indirect block holds 256 u32 LE entries (1 sector).
pub fn file_block_to_disk(read_sector_fn: anytype, inode: Inode, fblock: u32) !u32 {
    if (fblock < DIRECT_BLOCKS) return inode.direct[fblock];
    if (inode.indirect == 0) return 0;
    const idx = fblock - DIRECT_BLOCKS;
    if (idx >= 256) return error.FileTooBig;
    // 1K block = 2 sectors; indirect block nr -> sector = nr * 2
    var sec: [512]u8 = undefined;
    const half: u64 = if (idx < 128) 0 else 1;
    try read_sector_fn(@as(u64, inode.indirect) * 2 + half, sec[0..]);
    const off: usize = @as(usize, @intCast(idx % 128)) * 4;
    return read_u32_le(sec[off..]);
}

/// Single dir record: ino + type + NUL name.
pub const DirEnt = struct { ino: u32, ftype: u8, name_len: usize, name: [DIR_NAME_MAX]u8 };

/// Read dir record `index` (0-based, 16 per sector) from 1K data block `blk1k`
/// via reader. Returns error.DirEnd when index >= 32 (2 sectors x 16).
pub fn read_dirent(read_sector_fn: anytype, blk1k: u32, index: usize) !DirEnt {
    if (index >= 32) return error.DirEnd;
    var sec: [512]u8 = undefined;
    const sector: u64 = @as(u64, blk1k) * 2 + @as(u64, index / 16);
    try read_sector_fn(sector, sec[0..]);
    const off = (index % 16) * DIR_REC_SIZE;
    const rec = sec[off .. off + DIR_REC_SIZE];
    const ino = read_u32_le(rec[0..]);
    if (ino == 0) return error.DirEnd;
    var ent: DirEnt = .{ .ino = ino, .ftype = rec[4], .name_len = 0, .name = [_]u8{0} ** DIR_NAME_MAX };
    var n: usize = 0;
    while (n < DIR_NAME_MAX and rec[5 + n] != 0) : (n += 1) ent.name[n] = rec[5 + n];
    ent.name_len = n;
    return ent;
}

test "ext4: superblock magic ok" {
    const testing = @import("std").testing;
    const Stub = struct {
        fn read(lba: u64, out: []u8) !void {
            if (lba != 2 or out.len != 512) return error.UnexpectedRead;
            @memset(out, 0);
            out[56] = 0x53;
            out[57] = 0xEF;
        }
    };
    const superblock = try parse_superblock(Stub.read);
    try testing.expectEqual(@as(u16, 0xEF53), superblock.magic);
}

test "ext4: bad magic fails" {
    const testing = @import("std").testing;
    const Stub = struct {
        fn read(lba: u64, out: []u8) !void {
            if (lba != 2 or out.len != 512) return error.UnexpectedRead;
            @memset(out, 0);
            // Reversed bytes must not be accepted as little-endian ext4 magic.
            out[56] = 0xEF;
            out[57] = 0x53;
        }
    };
    try testing.expectError(error.BadMagic, parse_superblock(Stub.read));
    var out: [33]u8 = [_]u8{0xA5} ** 33;
    try testing.expectError(error.BadMagic, read_hello_txt(Stub.read, out[0..]));
    try testing.expectEqualSlices(u8, &([_]u8{0xA5} ** 33), out[0..]);
}

test "ext4: hello content" {
    const testing = @import("std").testing;
    const Fixture = struct {
        fn read(lba: u64, out: []u8) !void {
            if (out.len != 512) return error.UnexpectedRead;
            @memset(out, 0);
            switch (lba) {
                2 => {
                    out[56] = 0x53;
                    out[57] = 0xEF;
                },
                4 => @memcpy(out[0..33], "Hello from Zig Linux VFS (ramfs)\n"),
                else => return error.UnexpectedRead,
            }
        }

        fn read_changed(lba: u64, out: []u8) !void {
            try read(lba, out);
            if (lba == 4) out[0] = 'J';
        }
    };

    var out: [40]u8 = [_]u8{0xA5} ** 40;
    const count = try read_hello_txt(Fixture.read, out[0..]);
    try testing.expectEqual(@as(usize, 33), count);
    try testing.expectEqualStrings("Hello from Zig Linux VFS (ramfs)\n", out[0..count]);
    try testing.expectEqualSlices(u8, &([_]u8{0xA5} ** 7), out[count..]);

    // A different image must yield different bytes, rather than canned content.
    const changed_count = try read_hello_txt(Fixture.read_changed, out[0..]);
    try testing.expectEqualStrings("Jello from Zig Linux VFS (ramfs)\n", out[0..changed_count]);

    var short: [32]u8 = [_]u8{0xA5} ** 32;
    try testing.expectError(error.BufferTooSmall, read_hello_txt(Fixture.read, short[0..]));
    try testing.expectEqualSlices(u8, &([_]u8{0xA5} ** 32), short[0..]);
}

test "ext4: reader errors propagate" {
    const testing = @import("std").testing;
    const Stub = struct {
        fn fail_superblock(_: u64, _: []u8) error{ReadFailed}!void {
            return error.ReadFailed;
        }

        fn fail_data(lba: u64, out: []u8) !void {
            if (lba != 2) return error.ReadFailed;
            @memset(out, 0);
            out[56] = 0x53;
            out[57] = 0xEF;
        }
    };

    try testing.expectError(error.ReadFailed, parse_superblock(Stub.fail_superblock));
    var out: [33]u8 = [_]u8{0xA5} ** 33;
    try testing.expectError(error.ReadFailed, read_hello_txt(Stub.fail_superblock, out[0..]));
    try testing.expectError(error.ReadFailed, read_hello_txt(Stub.fail_data, out[0..]));
    try testing.expectEqualSlices(u8, &([_]u8{0xA5} ** 33), out[0..]);
}
