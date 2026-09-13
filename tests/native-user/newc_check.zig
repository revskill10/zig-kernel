// tests/native-user/newc_check.zig — hosted Contract A gate for the one-file
// cpio-newc `/init` lookup. Imports the named `initrd_newc` module; it is not
// runnable via a bare `zig test tests/native-user/newc_check.zig`.
//
//   zig build test-native-user-parsers
//   zig build test-native

const std = @import("std");
const newc = @import("initrd_newc");

const HexStyle = enum { upper, lower, mixed };

const Rec = struct {
    magic: []const u8 = "070701",
    ino: u32 = 1,
    mode: u32 = 0o100755,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u32 = 1,
    mtime: u32 = 0,
    filesize: ?u32 = null,
    devmajor: u32 = 0,
    devminor: u32 = 1,
    rdevmajor: u32 = 0,
    rdevminor: u32 = 0,
    namesize: ?u32 = null,
    check: u32 = 0,
    name: []const u8 = "/init",
    data: []const u8 = "ABCD",
    hex: HexStyle = .upper,
    write_nul: bool = true,
    name_pad: u8 = 0,
    data_pad: u8 = 0,
};

const Built = struct {
    len: usize,
    init_next: usize,
    data_off: usize,
    trailer_off: usize,
};

fn hexDigit(d: u4, style: HexStyle, index: usize) u8 {
    const lower = "0123456789abcdef";
    const upper = "0123456789ABCDEF";
    return switch (style) {
        .upper => upper[d],
        .lower => lower[d],
        .mixed => if (index % 2 == 0) upper[d] else lower[d],
    };
}

fn putHex(dst: []u8, v: u32, style: HexStyle) void {
    var x = v;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        dst[i] = hexDigit(@truncate(x & 0xF), style, i);
        x >>= 4;
    }
}

fn alignUp4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn fieldOff(rec_off: usize, field: usize) usize {
    return rec_off + 6 + field * 8;
}

fn writeRecord(buf: []u8, start: usize, rec: Rec) struct { next: usize, data_off: usize } {
    const filesize: u32 = rec.filesize orelse @intCast(rec.data.len);
    const namesize: u32 = rec.namesize orelse @intCast(rec.name.len + 1);
    var off = start;
    @memcpy(buf[off..][0..6], rec.magic);
    off += 6;
    const vals = [_]u32{
        rec.ino,        rec.mode,      rec.uid,       rec.gid,
        rec.nlink,      rec.mtime,     filesize,      rec.devmajor,
        rec.devminor,   rec.rdevmajor, rec.rdevminor, namesize,
        rec.check,
    };
    for (vals) |v| {
        putHex(buf[off..][0..8], v, rec.hex);
        off += 8;
    }
    @memcpy(buf[off..][0..rec.name.len], rec.name);
    off += rec.name.len;
    if (rec.write_nul) {
        buf[off] = 0;
        off += 1;
    }
    // Header namesize may disagree with the bytes just written; the on-wire
    // name region is namesize bytes from the end of the 110-byte header.
    const name_end = start + @as(usize, @intCast(newc.HEADER_SIZE)) + namesize;
    if (name_end > off) {
        @memset(buf[off..name_end], 0);
    }
    off = name_end;
    const data_off = alignUp4(off);
    if (data_off > off) @memset(buf[off..data_off], rec.name_pad);
    const copy_len = rec.data.len;
    if (copy_len != 0) {
        @memcpy(buf[data_off..][0..copy_len], rec.data);
    }
    const data_end = data_off + copy_len;
    const next = alignUp4(data_end);
    if (next > data_end) @memset(buf[data_end..next], rec.data_pad);
    return .{ .next = next, .data_off = data_off };
}

fn build(buf: []u8, init: Rec, trailer: Rec, tail_zeros: usize) Built {
    const first = writeRecord(buf, 0, init);
    const second = writeRecord(buf, first.next, trailer);
    if (tail_zeros != 0) @memset(buf[second.next .. second.next + tail_zeros], 0);
    return .{
        .len = second.next + tail_zeros,
        .init_next = first.next,
        .data_off = first.data_off,
        .trailer_off = first.next,
    };
}

fn trailerRec(nlink: u32) Rec {
    return .{
        .mode = 0,
        .nlink = nlink,
        .name = "TRAILER!!!",
        .data = "",
    };
}

fn canonical(buf: []u8) Built {
    return build(buf, .{}, trailerRec(1), 0);
}

fn expectErr(err: newc.Error, payload: []const u8) !void {
    try std.testing.expectError(err, newc.parse(payload));
}

test "newc: canonical file+trailer returns borrowed /init" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0xA5);
    const built = canonical(&buf);
    const payload = buf[0..built.len];
    var before: [512]u8 = buf;
    const entry = try newc.parse(payload);
    try std.testing.expectEqualStrings("/init", entry.name);
    try std.testing.expectEqualSlices(u8, "ABCD", entry.bytes);
    try std.testing.expectEqual(@as(u64, built.data_off), entry.offset);
    try std.testing.expectEqual(@as(u64, 4), entry.length);
    try std.testing.expectEqual(@as(usize, 4), entry.bytes.len);
    try std.testing.expectEqual(
        @intFromPtr(payload.ptr) + built.data_off,
        @intFromPtr(entry.bytes.ptr),
    );
    try std.testing.expectEqual(
        @intFromPtr(payload.ptr) + 110,
        @intFromPtr(entry.name.ptr),
    );
    try std.testing.expectEqualSlices(u8, before[0..built.len], payload);
}

test "newc: mixed-case hexadecimal metadata" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    const init = Rec{
        .ino = 0xABCDEF01,
        .mode = 0o100755,
        .uid = 0xA0B0C0D,
        .gid = 0xE0F0123,
        .mtime = 0x89ABCDEF,
        .devmajor = 0xAABBCCDD,
        .devminor = 0x11223344,
        .rdevmajor = 0x55667788,
        .rdevminor = 0x99AAEEFF,
        .hex = .mixed,
        .data = "xy",
    };
    const trailer = Rec{
        .mode = 0,
        .nlink = 0,
        .ino = 0xFEDCBA98,
        .uid = 0x123456,
        .mtime = 0xDEADBEEF,
        .name = "TRAILER!!!",
        .data = "",
        .hex = .lower,
    };
    const built = build(&buf, init, trailer, 0);
    const entry = try newc.parse(buf[0..built.len]);
    try std.testing.expectEqualSlices(u8, "xy", entry.bytes);
    try std.testing.expectEqual(@as(u64, 2), entry.length);
}

test "newc: optional zero tail accepted" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0xA5);
    for ([_]usize{ 0, 1, 3, 4, 16, 32 }) |tail| {
        @memset(&buf, 0xA5);
        const built = build(&buf, .{}, trailerRec(1), tail);
        const entry = try newc.parse(buf[0..built.len]);
        try std.testing.expectEqualSlices(u8, "ABCD", entry.bytes);
    }
}

test "newc: unaligned input subslice" {
    var storage: [520]u8 align(8) = undefined;
    @memset(&storage, 0x3C);
    const payload = storage[1..];
    const built = canonical(payload);
    const entry = try newc.parse(payload[0..built.len]);
    try std.testing.expectEqualSlices(u8, "ABCD", entry.bytes);
    try std.testing.expectEqual(@as(u64, built.data_off), entry.offset);
    try std.testing.expectEqual(
        @intFromPtr(payload.ptr) + built.data_off,
        @intFromPtr(entry.bytes.ptr),
    );
    try std.testing.expect((@intFromPtr(payload.ptr) & 3) != 0);
}

test "newc: uid/gid/mtime/inode/dev metadata may vary" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    const built = build(&buf, .{
        .ino = 42,
        .uid = 1000,
        .gid = 1000,
        .mtime = 1_700_000_000,
        .devmajor = 8,
        .devminor = 2,
        .rdevmajor = 0,
        .rdevminor = 0,
        .mode = 0o100711,
        .data = "Z",
    }, trailerRec(0), 4);
    const entry = try newc.parse(buf[0..built.len]);
    try std.testing.expectEqualSlices(u8, "Z", entry.bytes);
    try std.testing.expectEqual(@as(u64, 1), entry.length);
}

test "newc: each truncated prefix before completed trailer fails" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    const built = canonical(&buf);
    try std.testing.expect(built.len > newc.HEADER_SIZE);
    var n: usize = 0;
    while (n < built.len) : (n += 1) {
        if (newc.parse(buf[0..n])) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    _ = try newc.parse(buf[0..built.len]);

    try expectErr(error.Truncated, buf[0..0]);
    try expectErr(error.Truncated, buf[0..1]);
    try expectErr(error.Truncated, buf[0..6]);
    try expectErr(error.Truncated, buf[0..109]);
    try expectErr(error.Truncated, buf[0..110]);
    try expectErr(error.Truncated, buf[0..115]);
    try expectErr(error.MissingTrailer, buf[0..built.init_next]);
    try expectErr(error.MissingTrailer, buf[0 .. built.len - 1]);
}

test "newc: malformed hex every header field class" {
    var buf: [512]u8 = undefined;
    const poisons = [_]u8{ 'G', 'g', ' ', '+', '-', 0, 'x', '\t', '\n' };
    var field: usize = 0;
    while (field < 13) : (field += 1) {
        for (poisons) |p| {
            @memset(&buf, 0);
            const built = canonical(&buf);
            buf[fieldOff(0, field) + 7] = p;
            try expectErr(error.BadHex, buf[0..built.len]);
        }
        @memset(&buf, 0);
        const built = canonical(&buf);
        buf[fieldOff(0, field) + 0] = '/';
        try expectErr(error.BadHex, buf[0..built.len]);
    }

    @memset(&buf, 0);
    const trailer_hex = canonical(&buf);
    buf[fieldOff(trailer_hex.trailer_off, 5) + 3] = 'G';
    try expectErr(error.BadHex, buf[0..trailer_hex.len]);
}

test "newc: invalid magic and CRC" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    var built = canonical(&buf);
    @memcpy(buf[0..6], "070702");
    try expectErr(error.CrcMagic, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    @memcpy(buf[0..6], "070700");
    try expectErr(error.BadMagic, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    @memcpy(buf[0..6], "070707");
    try expectErr(error.BadMagic, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    @memcpy(buf[0..6], "070701");
    buf[0] = '1';
    try expectErr(error.BadMagic, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    @memcpy(buf[built.trailer_off..][0..6], "070702");
    try expectErr(error.CrcMagic, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    @memcpy(buf[built.trailer_off..][0..6], "xxxxxx");
    try expectErr(error.BadMagic, buf[0..built.len]);
}

test "newc: namesize zero oversized missing and embedded NUL" {
    var buf: [512]u8 = undefined;

    @memset(&buf, 0);
    var built = canonical(&buf);
    putHex(buf[fieldOff(0, 11)..][0..8], 0, .upper);
    try expectErr(error.BadNamesize, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    buf[110 + 5] = 'X';
    try expectErr(error.BadNamesize, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .namesize = 5, .name = "/init", .write_nul = false, .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.BadNamesize, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .namesize = 7, .name = "/init", .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.EmbeddedNul, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    buf[110 + 2] = 0;
    try expectErr(error.EmbeddedNul, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    putHex(buf[fieldOff(0, 11)..][0..8], 64, .upper);
    if (newc.parse(buf[0..built.len])) |_| {
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expect(e == error.BadNamesize or e == error.EmbeddedNul);
    }

    @memset(&buf, 0);
    built = canonical(&buf);
    putHex(buf[fieldOff(built.trailer_off, 11)..][0..8], 10, .upper);
    try expectErr(error.BadNamesize, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    putHex(buf[fieldOff(built.trailer_off, 11)..][0..8], 12, .upper);
    try expectErr(error.EmbeddedNul, buf[0..built.len]);
}

test "newc: traversal relative unknown and duplicate names" {
    var buf: [512]u8 = undefined;

    const bad_first = [_][]const u8{
        "init",
        "./init",
        "../init",
        "/.",
        "/..",
        "/./init",
        "/../init",
        "//init",
        "/init/",
        "/init//x",
        "/init/../x",
        "",
        "/Init",
        "/INIT",
        "/initt",
    };
    for (bad_first) |name| {
        @memset(&buf, 0);
        const namesize: u32 = if (name.len == 0) 1 else @intCast(name.len + 1);
        const built = build(&buf, .{
            .name = name,
            .namesize = namesize,
            .data = "ABCD",
        }, trailerRec(1), 0);
        const err = newc.parse(buf[0..built.len]);
        if (err) |_| return error.TestUnexpectedResult else |e| {
            try std.testing.expect(e == error.BadName or e == error.UnknownFile or e == error.BadNamesize);
        }
    }

    @memset(&buf, 0);
    var built = build(&buf, .{ .name = "init", .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.BadName, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .name = "/Init", .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.BadName, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .name = "/foo", .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.UnknownFile, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .name = "/bin/sh", .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.UnknownFile, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .name = "TRAILER!!!", .mode = 0, .nlink = 1, .data = "" }, trailerRec(1), 0);
    try expectErr(error.MissingInit, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{}, .{ .name = "/init", .mode = 0o100755, .nlink = 1, .data = "ABCD" }, 0);
    try expectErr(error.DuplicateName, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{}, .{ .name = "/foo", .mode = 0, .nlink = 1, .data = "" }, 0);
    try expectErr(error.BadTrailer, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{}, .{ .name = "trailer!!!", .mode = 0, .nlink = 1, .data = "" }, 0);
    try expectErr(error.BadName, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{}, .{ .name = "TRAILER!!", .mode = 0, .nlink = 1, .data = "" }, 0);
    try expectErr(error.BadName, buf[0..built.len]);
}

test "newc: each unsupported file type and nlink" {
    var buf: [512]u8 = undefined;
    const types = [_]u32{
        newc.S_IFDIR,
        newc.S_IFCHR,
        newc.S_IFBLK,
        newc.S_IFIFO,
        newc.S_IFLNK,
        newc.S_IFSOCK,
        0,
        0o150000,
        0o030000,
        0o070000,
        0o160000,
    };
    for (types) |t| {
        @memset(&buf, 0);
        const built = build(&buf, .{ .mode = t | 0o755, .data = "ABCD" }, trailerRec(1), 0);
        try expectErr(error.BadMode, buf[0..built.len]);
    }

    @memset(&buf, 0);
    var built = build(&buf, .{ .mode = newc.S_IFREG | newc.S_ISUID | 0o755, .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.BadMode, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .mode = newc.S_IFREG | newc.S_ISGID | 0o755, .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.BadMode, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .mode = newc.S_IFREG | newc.S_ISVTX | 0o755, .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.BadMode, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .mode = newc.S_IFREG | 0o755 | 0x10000, .data = "ABCD" }, trailerRec(1), 0);
    try expectErr(error.BadMode, buf[0..built.len]);

    const nlinks = [_]u32{ 0, 2, 3, 0xFFFFFFFF };
    for (nlinks) |nlink| {
        @memset(&buf, 0);
        built = build(&buf, .{ .nlink = nlink, .data = "ABCD" }, trailerRec(1), 0);
        try expectErr(error.BadNlink, buf[0..built.len]);
    }
}

test "newc: zero-size init, no executable bit, bad check" {
    var buf: [512]u8 = undefined;

    @memset(&buf, 0);
    var built = build(&buf, .{ .data = "" }, trailerRec(1), 0);
    try expectErr(error.EmptyInit, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .filesize = 0, .data = "" }, trailerRec(1), 0);
    try expectErr(error.EmptyInit, buf[0..built.len]);

    const no_exec = [_]u32{ 0o100644, 0o100600, 0o100444, 0o100000, 0o100640 };
    for (no_exec) |mode| {
        @memset(&buf, 0);
        built = build(&buf, .{ .mode = mode, .data = "ABCD" }, trailerRec(1), 0);
        try expectErr(error.NoExecutableBit, buf[0..built.len]);
    }

    const yes_exec = [_]u32{ 0o100755, 0o100744, 0o100711, 0o100701, 0o100070 };
    for (yes_exec) |mode| {
        @memset(&buf, 0);
        built = build(&buf, .{ .mode = mode, .data = "ABCD" }, trailerRec(1), 0);
        _ = try newc.parse(buf[0..built.len]);
    }

    @memset(&buf, 0);
    built = canonical(&buf);
    putHex(buf[fieldOff(0, 12)..][0..8], 1, .upper);
    try expectErr(error.BadCheck, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    putHex(buf[fieldOff(built.trailer_off, 12)..][0..8], 0x10, .upper);
    try expectErr(error.BadCheck, buf[0..built.len]);
}

test "newc: nonzero name and data padding" {
    var buf: [512]u8 = undefined;

    @memset(&buf, 0);
    var built = build(&buf, .{ .data = "A" }, trailerRec(1), 0);
    const init_data_end = built.data_off + 1;
    try std.testing.expect(alignUp4(init_data_end) > init_data_end);
    buf[init_data_end] = 1;
    try expectErr(error.BadPadding, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{ .data = "AB" }, trailerRec(1), 0);
    buf[built.data_off + 2] = 0xFF;
    try expectErr(error.BadPadding, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    const trailer_name_end = built.trailer_off + @as(usize, @intCast(newc.HEADER_SIZE)) + 11;
    try std.testing.expect(alignUp4(trailer_name_end) > trailer_name_end);
    buf[trailer_name_end] = 1;
    try expectErr(error.BadPadding, buf[0..built.len]);
}

test "newc: wrong absent truncated trailer and trailer with data" {
    var buf: [512]u8 = undefined;

    @memset(&buf, 0);
    const first = writeRecord(&buf, 0, .{});
    try expectErr(error.MissingTrailer, buf[0..first.next]);

    @memset(&buf, 0);
    var built = canonical(&buf);
    try expectErr(error.MissingTrailer, buf[0 .. built.trailer_off + 1]);
    try expectErr(error.MissingTrailer, buf[0 .. built.trailer_off + 109]);
    try expectErr(error.MissingTrailer, buf[0 .. built.len - 1]);

    @memset(&buf, 0);
    built = build(&buf, .{}, .{
        .mode = 0,
        .nlink = 1,
        .name = "TRAILER!!!",
        .data = "x",
    }, 0);
    try expectErr(error.TrailerHasData, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    putHex(buf[fieldOff(built.trailer_off, 6)..][0..8], 4, .upper);
    try expectErr(error.TrailerHasData, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{}, .{
        .mode = 0o100755,
        .nlink = 1,
        .name = "TRAILER!!!",
        .data = "",
    }, 0);
    try expectErr(error.BadTrailer, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{}, .{
        .mode = 0,
        .nlink = 2,
        .name = "TRAILER!!!",
        .data = "",
    }, 0);
    try expectErr(error.BadNlink, buf[0..built.len]);

    @memset(&buf, 0);
    built = build(&buf, .{}, trailerRec(0), 0);
    _ = try newc.parse(buf[0..built.len]);
}

test "newc: appended archive and nonzero tail" {
    var buf: [1024]u8 = undefined;
    @memset(&buf, 0);
    var built = canonical(&buf);
    buf[built.len] = 1;
    try expectErr(error.NonzeroTail, buf[0 .. built.len + 1]);

    @memset(&buf, 0);
    built = canonical(&buf);
    const extra = writeRecord(buf[built.len..], 0, .{
        .name = "/init",
        .data = "EFGH",
    });
    try expectErr(error.NonzeroTail, buf[0 .. built.len + extra.next]);

    @memset(&buf, 0);
    built = canonical(&buf);
    @memcpy(buf[built.len..][0..6], "070701");
    try expectErr(error.NonzeroTail, buf[0 .. built.len + 6]);

    @memset(&buf, 0);
    built = build(&buf, .{}, trailerRec(1), 8);
    buf[built.len - 1] = 0x01;
    try expectErr(error.NonzeroTail, buf[0..built.len]);
}

test "newc: oversized input and declared sizes out of range" {
    const a = std.testing.allocator;
    const too_big = try a.alloc(u8, @intCast(newc.MAX_PAYLOAD + 1));
    defer a.free(too_big);
    try expectErr(error.PayloadTooLarge, too_big);

    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    var built = canonical(&buf);
    putHex(buf[fieldOff(0, 6)..][0..8], @intCast(newc.MAX_PAYLOAD + 1), .upper);
    try expectErr(error.InitTooLarge, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    putHex(buf[fieldOff(0, 6)..][0..8], @intCast(newc.MAX_PAYLOAD), .upper);
    try expectErr(error.InitTooLarge, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    putHex(buf[fieldOff(0, 6)..][0..8], 0x1000, .upper);
    try expectErr(error.Truncated, buf[0..built.len]);

    @memset(&buf, 0);
    built = canonical(&buf);
    putHex(buf[fieldOff(0, 11)..][0..8], 0x01000000, .upper);
    try expectErr(error.Truncated, buf[0..built.len]);
}

test "newc: executable-only permission bits and trailer nlink 0 or 1" {
    var buf: [512]u8 = undefined;
    @memset(&buf, 0);
    var built = build(&buf, .{ .mode = 0o100001, .data = "A" }, trailerRec(0), 0);
    var entry = try newc.parse(buf[0..built.len]);
    try std.testing.expectEqualSlices(u8, "A", entry.bytes);

    @memset(&buf, 0);
    built = build(&buf, .{ .mode = 0o100010, .data = "B" }, trailerRec(1), 1);
    entry = try newc.parse(buf[0..built.len]);
    try std.testing.expectEqualSlices(u8, "B", entry.bytes);

    @memset(&buf, 0);
    built = build(&buf, .{ .mode = 0o100100, .data = "C" }, trailerRec(1), 0);
    entry = try newc.parse(buf[0..built.len]);
    try std.testing.expectEqualSlices(u8, "C", entry.bytes);
}
