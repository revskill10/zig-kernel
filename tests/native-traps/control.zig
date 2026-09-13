// tests/native-traps/control.zig — hosted SysV x87 CW/MXCSR preservation.
// Runtime/opaque inputs; not interrupt or boot evidence.
const std = @import("std");
const probes = @import("probes");

fn cw() u16 {
    var value: u16 = 0;
    asm volatile ("fnstcw (%[p])"
        :
        : [p] "r" (&value)
        : .{ .memory = true }
    );
    return value;
}

fn setCw(value: *const u16) void {
    asm volatile ("fldcw (%[p])"
        :
        : [p] "r" (value)
        : .{ .memory = true }
    );
}

fn mxcsr() u32 {
    var value: u32 = 0;
    asm volatile ("stmxcsr (%[p])"
        :
        : [p] "r" (&value)
        : .{ .memory = true }
    );
    return value;
}

fn setMxcsr(value: *const u32) void {
    asm volatile ("ldmxcsr (%[p])"
        :
        : [p] "r" (value)
        : .{ .memory = true }
    );
}

fn opaqueU64(v: u64) u64 {
    var x = v;
    const p: *volatile u64 = &x;
    return p.*;
}

const MXCSR_CONTROL: u32 = 0xFFFFFFC0;

test "SysV timer helper preserves caller x87 CW and MXCSR control" {
    const saved_cw = cw();
    const saved_mx = mxcsr();
    defer {
        setCw(&saved_cw);
        setMxcsr(&saved_mx);
    }
    const initial_cw: u16 = 0x037F;
    const initial_mx: u32 = 0x1F80;
    setCw(&initial_cw);
    setMxcsr(&initial_mx);
    var ticks: u64 = opaqueU64(0);
    const limit = opaqueU64(0);
    const cap = opaqueU64(1);
    const rc = probes.zkTimerSentinelLoop(limit, cap, @intFromPtr(&ticks));
    try std.testing.expectEqual(@as(u64, 1), rc);
    try std.testing.expectEqual(initial_cw, cw());
    try std.testing.expectEqual(initial_mx & MXCSR_CONTROL, mxcsr() & MXCSR_CONTROL);
}

test "SysV timer helper restores control on the timeout return" {
    const saved_cw = cw();
    const saved_mx = mxcsr();
    defer {
        setCw(&saved_cw);
        setMxcsr(&saved_mx);
    }
    const initial_cw: u16 = 0x027F;
    const initial_mx: u32 = 0x1FA0;
    setCw(&initial_cw);
    setMxcsr(&initial_mx);
    var ticks: u64 = opaqueU64(0);
    const rc = probes.zkTimerSentinelLoop(opaqueU64(8), opaqueU64(1), @intFromPtr(&ticks));
    try std.testing.expectEqual(@as(u64, 2), rc);
    try std.testing.expectEqual(initial_cw, cw());
    try std.testing.expectEqual(initial_mx & MXCSR_CONTROL, mxcsr() & MXCSR_CONTROL);
}

test "SysV clobber probe keeps opaque live integer and vector state" {
    const a = opaqueU64(0x1111111111111111);
    const lo = opaqueU64(0xAAAAAAAAAAAAAAAA);
    const hi = opaqueU64(0xBBBBBBBBBBBBBBBB);
    var gpr: u64 = a;
    const vec: @Vector(2, u64) = .{ lo, hi };
    const rc = probes.zkAbiClobberProbe();
    gpr +%= vec[0];
    gpr +%= vec[1];
    try std.testing.expectEqual(@as(u64, 1), rc);
    try std.testing.expectEqual(a +% lo +% hi, gpr);
}
