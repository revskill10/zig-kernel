// supervisor/frame — control-channel framing (M4).
// Length-prefixed binary frames over serial/vsock: magic + type + len + payload + crc32.
// Guest messages never grant permissions; supervisor validates every frame.
// Pure + tested. CBOR payload support lands with guest agent (M4b).
const std = @import("std");

pub const MAGIC: u32 = 0x5A4B5342; // 'ZK SB'
pub const MAX_PAYLOAD: usize = 1 << 20; // 1 MiB

pub const MsgType = enum(u8) {
    hello = 1,
    ready = 2,
    exec = 3,
    started = 4,
    stdio = 5,
    exit = 6,
    file_put = 7,
    file_get = 8,
    file_data = 9,
    err = 255,
    _,
};

pub fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        crc ^= b;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            crc = if (crc & 1 != 0) (crc >> 1) ^ 0xEDB88320 else crc >> 1;
        }
    }
    return crc ^ 0xFFFFFFFF;
}

/// Encode frame into out. Returns bytes used. Caller sizes out as len+13.
pub fn encode(ty: MsgType, payload: []const u8, out: []u8) !usize {
    if (payload.len > MAX_PAYLOAD) return error.TooBig;
    const need = 4 + 1 + 4 + payload.len + 4;
    if (out.len < need) return error.NoSpace;
    std.mem.writeInt(u32, out[0..4], MAGIC, .little);
    out[4] = @intFromEnum(ty);
    std.mem.writeInt(u32, out[5..9], @intCast(payload.len), .little);
    @memcpy(out[9 .. 9 + payload.len], payload);
    std.mem.writeInt(u32, out[9 + payload.len ..][0..4], crc32(payload), .little);
    return need;
}

pub const Decoded = struct { ty: MsgType, payload: []const u8, consumed: usize };

/// Decode one frame from buf. Errors: short (need more), bad magic/crc/len.
pub fn decode(buf: []const u8) !Decoded {
    if (buf.len < 13) return error.Short;
    if (std.mem.readInt(u32, buf[0..4], .little) != MAGIC) return error.BadMagic;
    const ty: MsgType = @enumFromInt(buf[4]);
    const len = std.mem.readInt(u32, buf[5..9], .little);
    if (len > MAX_PAYLOAD) return error.TooBig;
    if (buf.len < 13 + @as(usize, len)) return error.Short;
    const payload = buf[9 .. 9 + len];
    const want = std.mem.readInt(u32, buf[9 + len ..][0..4], .little);
    if (crc32(payload) != want) return error.BadCrc;
    return .{ .ty = ty, .payload = payload, .consumed = 13 + len };
}

test "frame: encode→decode roundtrip" {
    var buf: [64]u8 = undefined;
    const n = try encode(.exec, "hello-guest", &buf);
    try std.testing.expectEqual(@as(usize, 13 + 11), n);
    const d = try decode(buf[0..n]);
    try std.testing.expect(d.ty == .exec);
    try std.testing.expectEqualStrings("hello-guest", d.payload);
    try std.testing.expectEqual(n, d.consumed);
}

test "frame: rejects bad magic/crc/truncation/oversize" {
    var buf: [64]u8 = undefined;
    const n = try encode(.stdio, "data", &buf);
    try std.testing.expectError(error.Short, decode(buf[0..5]));
    var bad = buf;
    bad[0] ^= 0xFF;
    try std.testing.expectError(error.BadMagic, decode(bad[0..n]));
    bad = buf;
    bad[n - 1] ^= 0xFF;
    try std.testing.expectError(error.BadCrc, decode(bad[0..n]));
    bad = buf;
    std.mem.writeInt(u32, bad[5..9], MAX_PAYLOAD + 1, .little);
    try std.testing.expectError(error.TooBig, decode(bad[0..n]));
    // two frames back-to-back: consumed splits stream
    var two: [128]u8 = undefined;
    const n1 = try encode(.hello, "a", &two);
    const n2 = try encode(.ready, "b", two[n1..]);
    const d1 = try decode(two[0 .. n1 + n2]);
    try std.testing.expectEqual(n1, d1.consumed);
    const d2 = try decode(two[n1 .. n1 + n2]);
    try std.testing.expect(d2.ty == .ready);
}
