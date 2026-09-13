// src/native/initrd_newc — allocation-free one-file cpio newc `/init` lookup.
// Input is the exact payload slice after envelope validation, never the
// envelope itself. This is a strict fixture profile, not general initramfs
// compatibility: exactly `/init` then `TRAILER!!!`, ASCII-hex headers, zero
// padding, and a 64 MiB cap. Unknown host archives are expected to fail.

const std = @import("std");

pub const MAX_PAYLOAD: u64 = 64 * 1024 * 1024;
pub const HEADER_SIZE: u64 = 110;
pub const MAGIC: []const u8 = "070701";
pub const CRC_MAGIC: []const u8 = "070702";
pub const INIT_NAME: []const u8 = "/init";
pub const TRAILER_NAME: []const u8 = "TRAILER!!!";
pub const INIT_NAMESIZE: u32 = 6;
pub const TRAILER_NAMESIZE: u32 = 11;

pub const S_IFMT: u32 = 0o170000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFCHR: u32 = 0o020000;
pub const S_IFBLK: u32 = 0o060000;
pub const S_IFIFO: u32 = 0o010000;
pub const S_IFLNK: u32 = 0o120000;
pub const S_IFSOCK: u32 = 0o140000;
pub const S_ISUID: u32 = 0o4000;
pub const S_ISGID: u32 = 0o2000;
pub const S_ISVTX: u32 = 0o1000;
pub const S_IXUSR: u32 = 0o100;
pub const S_IXGRP: u32 = 0o010;
pub const S_IXOTH: u32 = 0o001;
pub const S_IRWXUGO: u32 = 0o777;

pub const Error = error{
    PayloadTooLarge,
    Truncated,
    BadMagic,
    CrcMagic,
    BadHex,
    BadCheck,
    BadNamesize,
    EmbeddedNul,
    BadName,
    UnknownFile,
    DuplicateName,
    MissingInit,
    MissingTrailer,
    BadTrailer,
    TrailerHasData,
    BadMode,
    BadNlink,
    NoExecutableBit,
    EmptyInit,
    InitTooLarge,
    SizeOverflow,
    BadPadding,
    NonzeroTail,
};

pub const Entry = struct {
    name: []const u8,
    bytes: []const u8,
    offset: u64,
    length: u64,
};

const Record = struct {
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    nlink: u32,
    mtime: u32,
    filesize: u32,
    devmajor: u32,
    devminor: u32,
    rdevmajor: u32,
    rdevminor: u32,
    namesize: u32,
    check: u32,
    name: []const u8,
    data_off: u64,
};

fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.SizeOverflow;
}

fn align4(off: u64) Error!u64 {
    const rem = off & 3;
    if (rem == 0) return off;
    return add(off, 4 - rem);
}

fn hexVal(c: u8) Error!u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.BadHex,
    };
}

fn parseHex8(field: []const u8) Error!u32 {
    var v: u32 = 0;
    for (field[0..8]) |c| {
        v = (v << 4) | try hexVal(c);
    }
    return v;
}

fn sliceRange(payload: []const u8, start: u64, len: u64) Error![]const u8 {
    const end = try add(start, len);
    if (end > payload.len) return error.Truncated;
    return payload[@intCast(start)..@intCast(end)];
}

fn requireZero(payload: []const u8, start: u64, end: u64) Error!void {
    if (end < start) return error.SizeOverflow;
    if (end > payload.len) return error.Truncated;
    for (payload[@intCast(start)..@intCast(end)]) |b| {
        if (b != 0) return error.BadPadding;
    }
}

fn badPath(name: []const u8) bool {
    if (name.len == 0 or name[0] != '/') return true;
    var i: usize = 0;
    while (i < name.len) {
        if (name[i] != '/') {
            i += 1;
            continue;
        }
        if (i + 1 >= name.len) return true;
        if (name[i + 1] == '/') return true;
        var j = i + 1;
        while (j < name.len and name[j] != '/') : (j += 1) {}
        const part = name[i + 1 .. j];
        if (part.len == 1 and part[0] == '.') return true;
        if (part.len == 2 and part[0] == '.' and part[1] == '.') return true;
        i = j;
    }
    return false;
}

fn eqIgnoreAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + ('a' - 'A') else x;
        const yl = if (y >= 'A' and y <= 'Z') y + ('a' - 'A') else y;
        if (xl != yl) return false;
    }
    return true;
}

/// Parse magic, the thirteen ASCII-hex fields, the NUL-terminated name, and
/// the 4-byte name padding. File bytes are not required yet so declared
/// `/init` sizes can fail as InitTooLarge rather than Truncated.
fn parseHeaderName(payload: []const u8, start: u64) Error!Record {
    const hdr = try sliceRange(payload, start, HEADER_SIZE);
    const magic = hdr[0..6];
    if (std.mem.eql(u8, magic, CRC_MAGIC)) return error.CrcMagic;
    if (!std.mem.eql(u8, magic, MAGIC)) return error.BadMagic;

    const ino = try parseHex8(hdr[6..14]);
    const mode = try parseHex8(hdr[14..22]);
    const uid = try parseHex8(hdr[22..30]);
    const gid = try parseHex8(hdr[30..38]);
    const nlink = try parseHex8(hdr[38..46]);
    const mtime = try parseHex8(hdr[46..54]);
    const filesize = try parseHex8(hdr[54..62]);
    const devmajor = try parseHex8(hdr[62..70]);
    const devminor = try parseHex8(hdr[70..78]);
    const rdevmajor = try parseHex8(hdr[78..86]);
    const rdevminor = try parseHex8(hdr[86..94]);
    const namesize = try parseHex8(hdr[94..102]);
    const check = try parseHex8(hdr[102..110]);
    if (check != 0) return error.BadCheck;
    if (namesize == 0) return error.BadNamesize;

    const name_off = try add(start, HEADER_SIZE);
    const name_raw = try sliceRange(payload, name_off, namesize);
    if (name_raw[name_raw.len - 1] != 0) return error.BadNamesize;
    const name_body = name_raw[0 .. name_raw.len - 1];
    for (name_body) |c| {
        if (c == 0) return error.EmbeddedNul;
    }

    const name_end = try add(name_off, namesize);
    const data_off = try align4(name_end);
    try requireZero(payload, name_end, data_off);

    return .{
        .ino = ino,
        .mode = mode,
        .uid = uid,
        .gid = gid,
        .nlink = nlink,
        .mtime = mtime,
        .filesize = filesize,
        .devmajor = devmajor,
        .devminor = devminor,
        .rdevmajor = rdevmajor,
        .rdevminor = rdevminor,
        .namesize = namesize,
        .check = check,
        .name = name_body,
        .data_off = data_off,
    };
}

fn takeFile(payload: []const u8, rec: Record) Error!struct { data: []const u8, next: u64 } {
    const data = try sliceRange(payload, rec.data_off, rec.filesize);
    const data_end = try add(rec.data_off, rec.filesize);
    const next = try align4(data_end);
    try requireZero(payload, data_end, next);
    return .{ .data = data, .next = next };
}

fn checkInitMode(rec: Record) Error!void {
    if (rec.mode & S_IFMT != S_IFREG) return error.BadMode;
    if (rec.mode & ~@as(u32, S_IFREG | S_IRWXUGO) != 0) return error.BadMode;
    if (rec.mode & (S_IXUSR | S_IXGRP | S_IXOTH) == 0) return error.NoExecutableBit;
    if (rec.nlink != 1) return error.BadNlink;
    if (rec.filesize == 0) return error.EmptyInit;
    if (rec.filesize > MAX_PAYLOAD) return error.InitTooLarge;
    const data_end = try add(rec.data_off, rec.filesize);
    if (data_end > MAX_PAYLOAD) return error.InitTooLarge;
}

fn checkTrailer(rec: Record) Error!void {
    if (rec.filesize != 0) return error.TrailerHasData;
    if (rec.mode != 0) return error.BadTrailer;
    if (rec.nlink != 0 and rec.nlink != 1) return error.BadNlink;
}

fn classifyFirstName(name: []const u8) Error!void {
    if (std.mem.eql(u8, name, INIT_NAME)) return;
    if (std.mem.eql(u8, name, TRAILER_NAME)) return error.MissingInit;
    if (badPath(name) or eqIgnoreAscii(name, INIT_NAME)) return error.BadName;
    return error.UnknownFile;
}

fn classifySecondName(name: []const u8) Error!void {
    if (std.mem.eql(u8, name, TRAILER_NAME)) return;
    if (std.mem.eql(u8, name, INIT_NAME)) return error.DuplicateName;
    if (badPath(name) or eqIgnoreAscii(name, INIT_NAME)) return error.BadName;
    return error.BadTrailer;
}

/// Discover the single regular `/init` member. Succeeds only after the
/// trailer and every tail byte have been validated.
pub fn parse(payload: []const u8) Error!Entry {
    if (payload.len > MAX_PAYLOAD) return error.PayloadTooLarge;
    if (payload.len < HEADER_SIZE) return error.Truncated;

    const init_rec = try parseHeaderName(payload, 0);
    try classifyFirstName(init_rec.name);
    if (init_rec.namesize != INIT_NAMESIZE) return error.BadNamesize;
    try checkInitMode(init_rec);
    const init_file = try takeFile(payload, init_rec);

    if (init_file.next >= payload.len) return error.MissingTrailer;
    const trailer = parseHeaderName(payload, init_file.next) catch |err| switch (err) {
        error.Truncated => return error.MissingTrailer,
        else => |e| return e,
    };
    try classifySecondName(trailer.name);
    if (trailer.namesize != TRAILER_NAMESIZE) return error.BadNamesize;
    try checkTrailer(trailer);
    const trailer_file = takeFile(payload, trailer) catch |err| switch (err) {
        error.Truncated => return error.MissingTrailer,
        else => |e| return e,
    };

    var i: usize = @intCast(trailer_file.next);
    while (i < payload.len) : (i += 1) {
        if (payload[i] != 0) return error.NonzeroTail;
    }

    return .{
        .name = init_rec.name,
        .bytes = init_file.data,
        .offset = init_rec.data_off,
        .length = init_rec.filesize,
    };
}

comptime {
    if (HEADER_SIZE != 110) @compileError("newc header size drift");
    if (MAGIC.len + 13 * 8 != HEADER_SIZE) @compileError("newc field layout drift");
    if (INIT_NAME.len + 1 != INIT_NAMESIZE) @compileError("/init namesize drift");
    if (TRAILER_NAME.len + 1 != TRAILER_NAMESIZE) @compileError("trailer namesize drift");
    if (CRC_MAGIC.len != 6) @compileError("crc magic length drift");
}
