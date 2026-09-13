// src/native/initramfs — initramfs blob contract (KWP2 first slice).
// Fixed 64-byte header followed by payload. The EFI loader validates the
// header before handoff; the kernel re-validates after handoff. A real file
// table lands with KWP4 durable VFS; ceiling: cpio/newc or a zk-native table.

pub const MAGIC: u64 = 0x3146_4d52_5449_4e49; // "INITRMF1" little-endian
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: u32 = 64;

pub const Header = extern struct {
    magic: u64 = MAGIC,
    version: u32 = VERSION,
    header_size: u32 = HEADER_SIZE,
    payload_size: u64, // bytes following the header
    payload_checksum: u64, // additive u64 sum over payload (padded to 8)
    _reserved: [4]u64 = [_]u64{0} ** 4,
};

pub const Error = error{ Truncated, BadMagic, BadVersion, BadHeaderSize, SizeOverflow, BadChecksum };

pub fn checksumPayload(payload: []const u8) u64 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i + 8 <= payload.len) : (i += 8) {
        sum +%= std.mem.bytesToValue(u64, payload[i..][0..8]);
    }
    if (i < payload.len) {
        var tail: [8]u8 = [_]u8{0} ** 8;
        @memcpy(tail[0 .. payload.len - i], payload[i..]);
        sum +%= std.mem.bytesToValue(u64, &tail);
    }
    return sum;
}

/// Validate the blob header and payload checksum. The header is returned by
/// value so `blob` needs no alignment.
pub fn validate(blob: []const u8) Error!Header {
    if (blob.len < HEADER_SIZE) return error.Truncated;
    const h: Header = std.mem.bytesToValue(Header, blob[0..HEADER_SIZE]);
    if (h.magic != MAGIC) return error.BadMagic;
    if (h.version != VERSION) return error.BadVersion;
    if (h.header_size != HEADER_SIZE) return error.BadHeaderSize;
    if (h.payload_size > blob.len - HEADER_SIZE) return error.SizeOverflow;
    const payload = blob[HEADER_SIZE..][0..@intCast(h.payload_size)];
    if (checksumPayload(payload) != h.payload_checksum) return error.BadChecksum;
    return h;
}

pub fn payloadOf(blob: []const u8, h: Header) []const u8 {
    return blob[HEADER_SIZE..][0..@intCast(h.payload_size)];
}

const std = @import("std");

test "initramfs: round trip + rejection matrix" {
    const payload = "hello-initramfs";
    var blob: [HEADER_SIZE + 64]u8 = undefined;
    @memset(&blob, 0);
    var h = Header{ .payload_size = payload.len, .payload_checksum = checksumPayload(payload) };
    @memcpy(blob[0..HEADER_SIZE], std.mem.asBytes(&h));
    @memcpy(blob[HEADER_SIZE..][0..payload.len], payload);
    const got = try validate(blob[0 .. HEADER_SIZE + payload.len]);
    try std.testing.expectEqual(@as(u64, payload.len), got.payload_size);
    try std.testing.expectEqualStrings(payload, payloadOf(&blob, got));

    try std.testing.expectError(error.Truncated, validate(blob[0..8]));
    h.magic = 0;
    @memcpy(blob[0..HEADER_SIZE], std.mem.asBytes(&h));
    try std.testing.expectError(error.BadMagic, validate(&blob));
    h = .{ .payload_size = 999, .payload_checksum = 0 };
    @memcpy(blob[0..HEADER_SIZE], std.mem.asBytes(&h));
    try std.testing.expectError(error.SizeOverflow, validate(blob[0 .. HEADER_SIZE + payload.len]));
    h = .{ .payload_size = payload.len, .payload_checksum = 0 };
    @memcpy(blob[0..HEADER_SIZE], std.mem.asBytes(&h));
    try std.testing.expectError(error.BadChecksum, validate(blob[0 .. HEADER_SIZE + payload.len]));
}

comptime {
    if (@sizeOf(Header) != HEADER_SIZE) @compileError("initramfs header drift");
}
