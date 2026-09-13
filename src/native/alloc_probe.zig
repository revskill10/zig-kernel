// src/native/alloc_probe — deterministic volatile page sentinels (N3 R1).
// Every offset later read is written first. Full-page init so leftover
// physical contents cannot satisfy or fail a check. Hosted tests import
// this file; native main file-imports it. No PMM implementation here.

pub const PAGE: usize = 4096;
pub const FILL: u8 = 0x11;
pub const S0: u8 = 0xA5;
pub const S1: u8 = 0x22;
pub const S100: u8 = 0x5A;
pub const S2048: u8 = 0x3C;
pub const S4094: u8 = 0x44;
pub const S4095: u8 = 0xC3;

/// Offsets the probe writes and later reads. READ must stay a subset of WRITE.
pub const write_offsets = [_]usize{ 0, 1, 0x100, 2048, 4094, 4095 };
pub const read_offsets = write_offsets;

comptime {
    for (read_offsets) |r| {
        var found = false;
        for (write_offsets) |w| {
            if (w == r) found = true;
        }
        if (!found) @compileError("alloc probe reads an offset it does not write");
    }
}

pub fn writeSentinels(p: [*]volatile u8) void {
    var i: usize = 0;
    while (i < PAGE) : (i += 1) p[i] = FILL;
    p[0] = S0;
    p[1] = S1;
    p[0x100] = S100;
    p[2048] = S2048;
    p[4094] = S4094;
    p[4095] = S4095;
}

pub fn checkSentinels(p: [*]const volatile u8) bool {
    return p[0] == S0 and p[1] == S1 and p[0x100] == S100 and
        p[2048] == S2048 and p[4094] == S4094 and p[4095] == S4095 and
        p[2] == FILL and p[4093] == FILL;
}

const std = @import("std");

test "writes every offset later read and ignores poison leftovers" {
    var buf: [PAGE]u8 = undefined;
    for (&buf) |*b| b.* = S0;
    buf[4094] = S4095;
    buf[4095] = S4095;
    const p: [*]volatile u8 = &buf;
    writeSentinels(p);
    try std.testing.expect(checkSentinels(p));
}
