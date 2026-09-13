// tests/native-tables — hosted fixtures for native GDT/IDT production types.
// Layout sizes plus encode/decode of the same helpers init/verify/setGate use.
// Not runtime boot/LTR/SGDT evidence; those remain a coordinator QEMU gate.
const std = @import("std");
const gdt = @import("gdt");
const idt = @import("idt");

test "GDT table pointer is the 10-byte hardware operand" {
    try std.testing.expectEqual(@as(usize, 10), @sizeOf(gdt.GdtPointer));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(gdt.GdtPointer));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(gdt.GdtPointer, "limit"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(gdt.GdtPointer, "base"));
    try std.testing.expectEqual(@sizeOf(gdt.GdtPointer), @sizeOf(gdt.GdtPointerTest));
}

test "GDTR operand stores limit then unaligned 64-bit base" {
    const gp = gdt.GdtPointer{ .limit = 0x1234, .base = 0x0102030405060708 };
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 8, 7, 6, 5, 4, 3, 2, 1 }, std.mem.asBytes(&gp));
}

test "TSS64 size and architectural field offsets" {
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(gdt.Tss64));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(gdt.Tss64));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(gdt.Tss64, "rsp0"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(gdt.Tss64, "rsp1"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(gdt.Tss64, "rsp2"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(gdt.Tss64, "ist1"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(gdt.Tss64, "ist2"));
    try std.testing.expectEqual(@as(usize, 84), @offsetOf(gdt.Tss64, "ist7"));
    try std.testing.expectEqual(@as(usize, 92), @offsetOf(gdt.Tss64, "_reserved2"));
    try std.testing.expectEqual(@as(usize, 100), @offsetOf(gdt.Tss64, "_reserved3"));
    try std.testing.expectEqual(@as(usize, 102), @offsetOf(gdt.Tss64, "iopb_offset"));
    try std.testing.expectEqual(@as(u20, 103), gdt.TSS_LIMIT);
}

test "TSS storage alignment is independent of type alignment" {
    try std.testing.expectEqual(@as(usize, 1), @alignOf(gdt.Tss64));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(&gdt.tss) % 16);
}

test "selector index TI and RPL fields" {
    try std.testing.expectEqual(@as(u16, 1), gdt.selectorIndex(gdt.KERNEL_CODE_SEL));
    try std.testing.expectEqual(@as(u1, 0), gdt.selectorTi(gdt.KERNEL_CODE_SEL));
    try std.testing.expectEqual(@as(u2, 0), gdt.selectorRpl(gdt.KERNEL_CODE_SEL));
    try std.testing.expectEqual(@as(u16, 2), gdt.selectorIndex(gdt.KERNEL_DATA_SEL));
    try std.testing.expectEqual(@as(u2, 0), gdt.selectorRpl(gdt.KERNEL_DATA_SEL));
    try std.testing.expectEqual(@as(u16, 3), gdt.selectorIndex(gdt.USER_DATA_SEL));
    try std.testing.expectEqual(@as(u2, 3), gdt.selectorRpl(gdt.USER_DATA_SEL));
    try std.testing.expectEqual(@as(u16, 4), gdt.selectorIndex(gdt.USER_CODE_SEL));
    try std.testing.expectEqual(@as(u2, 3), gdt.selectorRpl(gdt.USER_CODE_SEL));
    try std.testing.expectEqual(@as(u16, 5), gdt.selectorIndex(gdt.TSS_SEL));
    try std.testing.expectEqual(@as(u1, 0), gdt.selectorTi(gdt.TSS_SEL));
    try std.testing.expectEqual(@as(u2, 0), gdt.selectorRpl(gdt.TSS_SEL));
}

test "production segment descriptors match architectural bytes" {
    try std.testing.expectEqual(@as(u64, 0x00AF9A000000FFFF), gdt.encodeSegment(0, 0xFFFFF, gdt.ACC_KERNEL_CODE, gdt.FLG_CODE64));
    try std.testing.expectEqual(@as(u64, 0x00CF92000000FFFF), gdt.encodeSegment(0, 0xFFFFF, gdt.ACC_KERNEL_DATA, gdt.FLG_DATA));
    try std.testing.expectEqual(@as(u64, 0x00CFF2000000FFFF), gdt.encodeSegment(0, 0xFFFFF, gdt.ACC_USER_DATA, gdt.FLG_DATA));
    try std.testing.expectEqual(@as(u64, 0x00AFFA000000FFFF), gdt.encodeSegment(0, 0xFFFFF, gdt.ACC_USER_CODE, gdt.FLG_CODE64));
}

test "TSS encode/decode uses base at bits 16-31 not the limit word" {
    const base: u64 = 0xA1B2C3D4E5F60718;
    const limit: u20 = 0xABC67;
    const encoded = gdt.encodeTssDescriptor(base, limit, gdt.ACC_TSS_AVAILABLE);
    try std.testing.expectEqual(@as(u64, 0xE50A89F60718BC67), encoded.lo);
    try std.testing.expectEqual(@as(u64, 0xA1B2C3D4), encoded.hi);
    const lo_bytes = encoded.lo;
    try std.testing.expectEqualSlices(u8, &.{ 0x67, 0xBC, 0x18, 0x07, 0xF6, 0x89, 0x0A, 0xE5 }, std.mem.asBytes(&lo_bytes));
    try std.testing.expectEqual(@as(u64, 0xBC67), encoded.lo & 0xFFFF);
    try std.testing.expectEqual(@as(u64, 0x0718), (encoded.lo >> 16) & 0xFFFF);
    try std.testing.expect((encoded.lo & 0xFFFF) != (base & 0xFFFF));

    const decoded = gdt.decodeTssDescriptor(encoded.lo, encoded.hi);
    try std.testing.expectEqual(base, decoded.base);
    try std.testing.expectEqual(limit, decoded.limit);
    try std.testing.expectEqual(gdt.ACC_TSS_AVAILABLE, decoded.access);
    try std.testing.expectEqual(@as(u4, 0), decoded.flags);
    try std.testing.expectEqual(@as(u32, 0), decoded.reserved_hi);

    const wrong_base = (encoded.lo & 0xFFFF) |
        (((encoded.lo >> 32) & 0xFF) << 16) |
        (((encoded.lo >> 56) & 0xFF) << 24) |
        ((encoded.hi & 0xFFFFFFFF) << 32);
    try std.testing.expect(wrong_base != base);
    try std.testing.expectEqual(@as(u64, 0xA1B2C3D4E5F6BC67), wrong_base);
}

test "TSS encode/decode second asymmetric fixture and reserved high bits" {
    const base: u64 = 0x0102030405060708;
    const limit: u20 = 0x103;
    const encoded = gdt.encodeTssDescriptor(base, limit, gdt.ACC_TSS_BUSY);
    const decoded = gdt.decodeTssDescriptor(encoded.lo, encoded.hi);
    try std.testing.expectEqual(base, decoded.base);
    try std.testing.expectEqual(limit, decoded.limit);
    try std.testing.expectEqual(gdt.ACC_TSS_BUSY, decoded.access);
    try std.testing.expectEqual(@as(u32, 0), decoded.reserved_hi);

    const junk_hi = encoded.hi | (@as(u64, 0xAABBCCDD) << 32);
    const junk = gdt.decodeTssDescriptor(encoded.lo, junk_hi);
    try std.testing.expectEqual(base, junk.base);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), junk.reserved_hi);
}

test "available vs busy system-bit handling" {
    try std.testing.expect(gdt.isAvailableSystemTssDpl0(gdt.ACC_TSS_AVAILABLE));
    try std.testing.expect(!gdt.isBusySystemTssDpl0(gdt.ACC_TSS_AVAILABLE));
    try std.testing.expect(gdt.isBusySystemTssDpl0(gdt.ACC_TSS_BUSY));
    try std.testing.expect(!gdt.isAvailableSystemTssDpl0(gdt.ACC_TSS_BUSY));
    try std.testing.expect(gdt.accessSystem(gdt.ACC_TSS_AVAILABLE));
    try std.testing.expect(gdt.accessSystem(gdt.ACC_TSS_BUSY));
    try std.testing.expectEqual(@as(u4, 0x9), gdt.accessType(gdt.ACC_TSS_AVAILABLE));
    try std.testing.expectEqual(@as(u4, 0xB), gdt.accessType(gdt.ACC_TSS_BUSY));
    try std.testing.expect(gdt.accessPresent(gdt.ACC_TSS_BUSY));
    try std.testing.expectEqual(@as(u2, 0), gdt.accessDpl(gdt.ACC_TSS_BUSY));

    // S=1 code/data lookalikes with the same type nibble must not pass.
    try std.testing.expect(!gdt.accessSystem(0x99));
    try std.testing.expect(!gdt.accessSystem(0x9B));
    try std.testing.expect(!gdt.isBusySystemTssDpl0(0x9B));
    try std.testing.expect(!gdt.isBusySystemTssDpl0(0x99));
    try std.testing.expect(!gdt.isBusySystemTssDpl0(0x0B)); // not present
    try std.testing.expect(!gdt.isBusySystemTssDpl0(0xAB)); // DPL1 system busy
    try std.testing.expect(!gdt.isAvailableSystemTssDpl0(0x99));

    const avail = gdt.encodeTssDescriptor(0x1000, 103, gdt.ACC_TSS_AVAILABLE);
    const busy = gdt.encodeTssDescriptor(0x1000, 103, gdt.ACC_TSS_BUSY);
    try std.testing.expectEqual(gdt.ACC_TSS_AVAILABLE, gdt.decodeTssDescriptor(avail.lo, avail.hi).access);
    try std.testing.expectEqual(gdt.ACC_TSS_BUSY, gdt.decodeTssDescriptor(busy.lo, busy.hi).access);
    try std.testing.expect(avail.lo != busy.lo);
}

test "IDT pointer is the 10-byte hardware operand" {
    try std.testing.expectEqual(@as(usize, 10), @sizeOf(idt.IdtPointer));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(idt.IdtPointer));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(idt.IdtPointer, "limit"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(idt.IdtPointer, "base"));
    try std.testing.expectEqual(@as(u16, 4095), idt.IDT_LIMIT);
}

test "IDT gate stride and field bit offsets" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(idt.IdtEntry));
    try std.testing.expectEqual(@as(usize, 128), @bitSizeOf(idt.IdtEntry));
    try std.testing.expectEqual(@as(usize, 16), @bitOffsetOf(idt.IdtEntry, "selector"));
    try std.testing.expectEqual(@as(usize, 32), @bitOffsetOf(idt.IdtEntry, "ist"));
    try std.testing.expectEqual(@as(usize, 40), @bitOffsetOf(idt.IdtEntry, "type_attr"));
    try std.testing.expectEqual(@as(usize, 48), @bitOffsetOf(idt.IdtEntry, "offset_mid"));
    try std.testing.expectEqual(@as(usize, 64), @bitOffsetOf(idt.IdtEntry, "offset_hi"));
    try std.testing.expectEqual(@as(usize, 96), @bitOffsetOf(idt.IdtEntry, "_zero1"));
    try std.testing.expectEqual(@sizeOf(idt.IdtEntry), @sizeOf(idt.IdtEntryTest));
}

test "IDT encode reconstructs high handler addresses and reserved bits" {
    const handler: u64 = 0x0102030405060708;
    const gate = idt.encodeGate(handler, gdt.KERNEL_CODE_SEL, 1, idt.TRAP_GATE);
    try std.testing.expectEqual(handler, idt.gateHandler(gate));
    try std.testing.expectEqual(@as(u16, 0x0708), gate.offset_lo);
    try std.testing.expectEqual(@as(u16, 0x0506), gate.offset_mid);
    try std.testing.expectEqual(@as(u32, 0x01020304), gate.offset_hi);
    try std.testing.expectEqual(gdt.KERNEL_CODE_SEL, gate.selector);
    try std.testing.expectEqual(@as(u3, 1), gate.ist);
    try std.testing.expectEqual(idt.TRAP_GATE, gate.type_attr);
    try std.testing.expectEqual(@as(u5, 0), gate._zero0);
    try std.testing.expectEqual(@as(u32, 0), gate._zero1);
    try std.testing.expectEqualSlices(u8, &.{
        0x08, 0x07, 0x08, 0x00, 0x01, 0x8F, 0x06, 0x05,
        0x04, 0x03, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00,
    }, std.mem.asBytes(&gate));
}

test "IDT encode second asymmetric handler and interrupt-gate attr" {
    const handler: u64 = 0xA1B2C3D4E5F60718;
    const gate = idt.encodeGate(handler, gdt.KERNEL_CODE_SEL, 0, idt.INT_GATE);
    try std.testing.expectEqual(handler, idt.gateHandler(gate));
    try std.testing.expectEqual(@as(u16, 0x0718), gate.offset_lo);
    try std.testing.expectEqual(@as(u16, 0xE5F6), gate.offset_mid);
    try std.testing.expectEqual(@as(u32, 0xA1B2C3D4), gate.offset_hi);
    try std.testing.expectEqual(idt.INT_GATE, gate.type_attr);
    try std.testing.expectEqual(@as(u3, 0), gate.ist);

    const canonical = idt.encodeGate(0xFFFF800012345678, gdt.KERNEL_CODE_SEL, 1, idt.TRAP_GATE);
    try std.testing.expectEqual(@as(u64, 0xFFFF800012345678), idt.gateHandler(canonical));
    try std.testing.expectEqual(@as(u32, 0xFFFF8000), canonical.offset_hi);
}
