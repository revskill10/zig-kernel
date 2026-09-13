// tools/mkinitramfs — build the KWP2 smoke initramfs blob.
// Deterministic fixed payload; real file tables land with KWP4.
// Usage: mkinitramfs --out <path>

const std = @import("std");
const initramfs = @import("initramfs");

const PAYLOAD = "zk-native initramfs v1 (KWP2 smoke payload)\n";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator(); // one-shot tool: process-lifetime arena, no leak noise

    var out_path: ?[]const u8 = null;
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    defer it.deinit();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            out_path = it.next() orelse return error.MissingOut;
        }
    }
    const out = out_path orelse return error.MissingOut;

    var h = initramfs.Header{
        .payload_size = PAYLOAD.len,
        .payload_checksum = initramfs.checksumPayload(PAYLOAD),
    };
    var blob: [initramfs.HEADER_SIZE + PAYLOAD.len]u8 = undefined;
    @memcpy(blob[0..initramfs.HEADER_SIZE], std.mem.asBytes(&h));
    @memcpy(blob[initramfs.HEADER_SIZE..], PAYLOAD);
    _ = try initramfs.validate(&blob); // self-check before writing

    if (std.fs.path.dirname(out)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = &blob });
}
