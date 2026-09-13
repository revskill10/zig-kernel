// tests/native-traps — hosted N6 predicates, ABI call fixture, N3 R1 helper.
// Not native boot evidence. Exact PFEC + SysV clobber probe.
const std = @import("std");
const idt = @import("idt");
const alloc_probe = @import("alloc_probe");

test "TrapFrame is 176 bytes with architectural GPR and IRET offsets" {
    try std.testing.expectEqual(@as(usize, 176), @sizeOf(idt.TrapFrame));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(idt.TrapFrame, "r15"));
    try std.testing.expectEqual(@as(usize, 112), @offsetOf(idt.TrapFrame, "rax"));
    try std.testing.expectEqual(@as(usize, 120), @offsetOf(idt.TrapFrame, "vector"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(idt.TrapFrame, "error_code"));
    try std.testing.expectEqual(@as(usize, 136), @offsetOf(idt.TrapFrame, "rip"));
    try std.testing.expectEqual(@as(usize, 144), @offsetOf(idt.TrapFrame, "cs"));
    try std.testing.expectEqual(@as(usize, 152), @offsetOf(idt.TrapFrame, "rflags"));
    try std.testing.expectEqual(@as(usize, 160), @offsetOf(idt.TrapFrame, "rsp"));
    try std.testing.expectEqual(@as(usize, 168), @offsetOf(idt.TrapFrame, "ss"));
}

test "one-shot matcher rejects disarmed wrong-site and exact-error mismatches" {
    const rip: u64 = 0x200010;
    try std.testing.expect(idt.eventMatches(true, 6, rip, false, 0, 0, 6, rip, 0, 0));
    try std.testing.expect(!idt.eventMatches(false, 6, rip, false, 0, 0, 6, rip, 0, 0));
    try std.testing.expect(!idt.eventMatches(true, 6, rip, false, 0, 0, 6, rip + 2, 0, 0));
    try std.testing.expect(!idt.eventMatches(true, 6, rip, false, 0, 0, 14, rip, 0, 0));
}

test "PF matcher exact equality rejects unsupported high bits for each class" {
    const rip: u64 = 0x200010;
    const cr2: u64 = 0x11000000;
    const hi: u64 = 1 << 63;

    try std.testing.expect(idt.eventMatches(true, 14, rip, true, cr2, 0, 14, rip, cr2, 0));
    try std.testing.expect(!idt.eventMatches(true, 14, rip, true, cr2, 0, 14, rip, cr2, 0x20));
    try std.testing.expect(!idt.eventMatches(true, 14, rip, true, cr2, 0, 14, rip, cr2, hi));
    try std.testing.expect(!idt.eventMatches(true, 14, rip, true, cr2, 0, 14, rip, cr2 + 1, 0));

    try std.testing.expect(idt.eventMatches(true, 14, rip, true, cr2, 0x3, 14, rip, cr2, 0x3));
    try std.testing.expect(!idt.eventMatches(true, 14, rip, true, cr2, 0x3, 14, rip, cr2, 0x23));
    try std.testing.expect(!idt.eventMatches(true, 14, rip, true, cr2, 0x3, 14, rip, cr2, 0x3 | hi));
    try std.testing.expect(!idt.eventMatches(true, 14, rip, true, cr2, 0x3, 14, rip, cr2, 0));

    try std.testing.expect(idt.eventMatches(true, 14, rip, true, cr2, 0x11, 14, rip, cr2, 0x11));
    try std.testing.expect(!idt.eventMatches(true, 14, rip, true, cr2, 0x11, 14, rip, cr2, 0x31));
    try std.testing.expect(!idt.eventMatches(true, 14, rip, true, cr2, 0x11, 14, rip, cr2, 0x13));
    try std.testing.expect(!idt.eventMatches(true, 14, rip, true, cr2, 0x11, 14, rip, cr2, 0x11 | hi));
}

test "PFEC constants encode present/write/fetch bits together" {
    try std.testing.expectEqual(@as(u64, 0x1F), idt.PFEC_MASK);
    try std.testing.expectEqual(@as(u64, 0), idt.ERR_PF_NOTPRESENT_READ);
    try std.testing.expectEqual(@as(u64, 0x3), idt.ERR_PF_RO_WRITE);
    try std.testing.expectEqual(@as(u64, 0x11), idt.ERR_PF_NX_FETCH);
}

test "alloc probe writes every offset it later reads" {
    comptime {
        for (alloc_probe.read_offsets) |r| {
            var found = false;
            for (alloc_probe.write_offsets) |w| {
                if (w == r) found = true;
            }
            if (!found) @compileError("reintroduced unwritten probe read");
        }
    }
    var buf: [alloc_probe.PAGE]u8 = undefined;
    for (&buf) |*b| b.* = alloc_probe.S0;
    buf[4094] = alloc_probe.S4095;
    buf[4095] = alloc_probe.S4095;
    const p: [*]volatile u8 = &buf;
    alloc_probe.writeSentinels(p);
    try std.testing.expect(alloc_probe.checkSentinels(p));
    try std.testing.expectEqual(alloc_probe.S1, buf[1]);
    try std.testing.expectEqual(alloc_probe.S4094, buf[4094]);
    try std.testing.expectEqual(alloc_probe.FILL, buf[2]);
}

test "IDT gate encode still reconstructs high handler addresses" {
    const handler: u64 = 0xA1B2C3D4E5F60718;
    const gate = idt.encodeGate(handler, 0x08, 1, idt.TRAP_GATE);
    try std.testing.expectEqual(handler, idt.gateHandler(gate));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(idt.IdtEntry));
}

fn opaqueU64(v: u64) u64 {
    var x = v;
    const p: *volatile u64 = &x;
    return p.*;
}

test "SysV assembly helper call keeps opaque live integer and vector state" {
    const a = opaqueU64(0x1111111111111111);
    const lo = opaqueU64(0xAAAAAAAAAAAAAAAA);
    const hi = opaqueU64(0xBBBBBBBBBBBBBBBB);
    var gpr: u64 = a;
    const vec: @Vector(2, u64) = .{ lo, hi };
    const rc = idt.probes.zkAbiClobberProbe();
    gpr +%= vec[0];
    gpr +%= vec[1];
    try std.testing.expectEqual(@as(u64, 1), rc);
    try std.testing.expectEqual(a +% lo +% hi, gpr);
}
