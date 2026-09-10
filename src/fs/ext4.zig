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
