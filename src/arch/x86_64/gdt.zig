// arch/x86_64/gdt — GDT with user segments + TSS + ring-transition policy.
// M2 protected execution: user/kernel selectors, TSS kernel-stack state,
// user-range gate, zk-abi-v1 syscall allowlist, iret validation.
// Freestanding-safe: pure logic, no std at runtime (tests only).
// ponytail: real lgdt/ltr/iret wiring lands with x86_64 baremetal boot (needs QEMU); ceiling: boot_baremetal path.

pub const KERNEL_CODE_SEL: u16 = 0x08;
pub const KERNEL_DATA_SEL: u16 = 0x10;
pub const USER_CODE_SEL: u16 = 0x1B; // index 3, RPL 3
pub const USER_DATA_SEL: u16 = 0x23; // index 4, RPL 3
pub const TSS_SEL: u16 = 0x28; // index 5, RPL 0 (16-byte descriptor, 2 slots)

pub const ACC_KERNEL_CODE: u8 = 0x9A; // P, DPL0, code, readable
pub const ACC_KERNEL_DATA: u8 = 0x92; // P, DPL0, data, writable
pub const ACC_USER_CODE: u8 = 0xFA; // P, DPL3, code, readable
pub const ACC_USER_DATA: u8 = 0xF2; // P, DPL3, data, writable
pub const ACC_TSS: u8 = 0x89; // P, DPL0, 64-bit available TSS

pub const FLG_CODE64: u4 = 0xA; // G=1, D=0, L=1 (long mode code)
pub const FLG_DATA: u4 = 0xC; // G=1, D/B=1, L=0
pub const FLG_TSS: u4 = 0x0;

pub const GDT_COUNT: usize = 7; // null, kcode, kdata, ucode, udata, tss_lo, tss_hi

/// Raw 8-byte segment descriptor. limit is 20-bit (4 KiB units with G=1).
pub fn desc(base: u32, limit: u20, access: u8, flags: u4) u64 {
    const lim: u32 = limit;
    var e: u64 = 0;
    e |= @as(u64, lim & 0xFFFF);
    e |= @as(u64, base & 0xFFFF) << 16;
    e |= @as(u64, (base >> 16) & 0xFF) << 32;
    e |= @as(u64, access) << 40;
    e |= @as(u64, (lim >> 16) & 0x0F) << 48;
    e |= @as(u64, flags) << 52;
    e |= @as(u64, (base >> 24) & 0xFF) << 56;
    return e;
}

pub fn entryAccess(e: u64) u8 { return @truncate((e >> 40) & 0xFF); }
pub fn entryDpl(e: u64) u2 { return @truncate((entryAccess(e) >> 5) & 0x3); }
pub fn entryPresent(e: u64) bool { return (entryAccess(e) & 0x80) != 0; }
pub fn selIndex(sel: u16) u16 { return sel >> 3; }
pub fn selRpl(sel: u16) u2 { return @truncate(sel & 3); }

/// Full GDT image: null + kernel/user code/data + 16-byte TSS descriptor.
pub fn build(tss_base: u64, tss_limit: u32) [GDT_COUNT]u64 {
    const lim: u20 = @truncate(@min(tss_limit, 0xFFFFF));
    return .{
        0,
        desc(0, 0xFFFFF, ACC_KERNEL_CODE, FLG_CODE64),
        desc(0, 0xFFFFF, ACC_KERNEL_DATA, FLG_DATA),
        desc(0, 0xFFFFF, ACC_USER_CODE, FLG_CODE64),
        desc(0, 0xFFFFF, ACC_USER_DATA, FLG_DATA),
        desc(@truncate(tss_base & 0xFFFFFFFF), lim, ACC_TSS, FLG_TSS),
        tss_base >> 32,
    };
}

/// TSS policy state: kernel stack the CPU loads on ring3→0 transition.
pub const Tss = struct { rsp0: u64 = 0, ist: [7]u64 = [_]u64{0} ** 7 };
pub var tss: Tss = .{};
pub fn tssInit(kernel_stack_top: u64) void {
    tss.rsp0 = kernel_stack_top;
    tss.ist[0] = kernel_stack_top;
}

pub const Ring = enum { ring0, ring3 };

/// Only ring0 may mask the timer / run privileged ops (cli/hlt/lgdt/ltr).
pub fn preemptDisableAllowed(ring: Ring) bool { return ring == .ring0; }
pub fn privilegedOpAllowed(ring: Ring) bool { return ring == .ring0; }

/// Canonical low-half user address split (long mode).
pub const USER_MAX: u64 = 0x00007FFFFFFFFFFF;
pub fn isUserAddr(addr: u64) bool { return addr <= USER_MAX; }
pub fn isUserRange(addr: u64, len: u64) bool {
    if (len == 0) return isUserAddr(addr);
    const end = addr +% (len - 1);
    if (end < addr) return false; // wrapped
    return end <= USER_MAX;
}

pub const PROT_READ: u32 = 1;
pub const PROT_WRITE: u32 = 2;

/// Checked user-memory copy gate: VMA containment + prot + user-half + no wrap.
pub fn userCopyAllowed(vma_start: u64, vma_end: u64, vma_prot: u32, addr: u64, len: u64, write: bool) bool {
    if (len == 0) return true;
    if (write and (vma_prot & PROT_WRITE) == 0) return false;
    if (!write and (vma_prot & PROT_READ) == 0) return false;
    const end = addr +% len;
    if (end < addr) return false; // wrapped
    if (addr < vma_start or end > vma_end) return false;
    return isUserRange(addr, len);
}

/// zk-abi-v1 syscall allowlist (docs/sandbox-abi.md). All else → ENOSYS/guest_failure.
pub fn syscallAllowed(nr: usize) bool {
    return switch (nr) {
        1, 2, 3, 4, 5, 6, 15, 31, 34, 48, 50, 53 => true,
        else => false,
    };
}

/// iretq to user mode valid only with user code/data selectors.
pub fn iretToUserValid(cs: u16, ss: u16) bool {
    return cs == USER_CODE_SEL and ss == USER_DATA_SEL;
}

const std = @import("std");

test "gdt: selector indices and RPL" {
    try std.testing.expectEqual(@as(u16, 1), selIndex(KERNEL_CODE_SEL));
    try std.testing.expectEqual(@as(u16, 2), selIndex(KERNEL_DATA_SEL));
    try std.testing.expectEqual(@as(u16, 3), selIndex(USER_CODE_SEL));
    try std.testing.expectEqual(@as(u16, 4), selIndex(USER_DATA_SEL));
    try std.testing.expectEqual(@as(u16, 5), selIndex(TSS_SEL));
    try std.testing.expectEqual(@as(u2, 0), selRpl(KERNEL_CODE_SEL));
    try std.testing.expectEqual(@as(u2, 3), selRpl(USER_CODE_SEL));
    try std.testing.expectEqual(@as(u2, 3), selRpl(USER_DATA_SEL));
    try std.testing.expectEqual(@as(u2, 0), selRpl(TSS_SEL));
}

test "gdt: access bytes carry DPL + present" {
    try std.testing.expect(entryPresent(desc(0, 0xFFFFF, ACC_KERNEL_CODE, FLG_CODE64)));
    try std.testing.expectEqual(@as(u2, 0), entryDpl(desc(0, 0xFFFFF, ACC_KERNEL_CODE, FLG_CODE64)));
    try std.testing.expectEqual(@as(u2, 0), entryDpl(desc(0, 0xFFFFF, ACC_KERNEL_DATA, FLG_DATA)));
    try std.testing.expectEqual(@as(u2, 3), entryDpl(desc(0, 0xFFFFF, ACC_USER_CODE, FLG_CODE64)));
    try std.testing.expectEqual(@as(u2, 3), entryDpl(desc(0, 0xFFFFF, ACC_USER_DATA, FLG_DATA)));
    try std.testing.expectEqual(@as(u2, 0), entryDpl(desc(0, 104, ACC_TSS, FLG_TSS)));
}

test "gdt: build table layout" {
    const t = build(0x1_2345_6780, 104);
    try std.testing.expectEqual(@as(u64, 0), t[0]);
    try std.testing.expectEqual(ACC_KERNEL_CODE, entryAccess(t[1]));
    try std.testing.expectEqual(ACC_KERNEL_DATA, entryAccess(t[2]));
    try std.testing.expectEqual(ACC_USER_CODE, entryAccess(t[3]));
    try std.testing.expectEqual(ACC_USER_DATA, entryAccess(t[4]));
    try std.testing.expectEqual(ACC_TSS, entryAccess(t[5]));
    try std.testing.expectEqual(@as(u64, 0x1), t[6]); // base>>32
    try std.testing.expectEqual(@as(u2, 3), entryDpl(t[3]));
}

test "gdt: user range split + wrap" {
    try std.testing.expect(isUserRange(0, 4096));
    try std.testing.expect(isUserRange(USER_MAX, 1));
    try std.testing.expect(!isUserRange(USER_MAX, 2));
    try std.testing.expect(!isUserRange(USER_MAX + 1, 1));
    try std.testing.expect(!isUserRange(0xFFFF800000000000, 8)); // kernel half
    try std.testing.expect(!isUserRange(0xFFFFFFFFFFFFFF00, 0x200)); // wrap
    try std.testing.expect(isUserAddr(0));
}

test "gdt: zk-abi-v1 allowlist" {
    const allowed = [_]usize{ 1, 2, 3, 4, 5, 6, 15, 31, 34, 48, 50, 53 };
    for (allowed) |nr| try std.testing.expect(syscallAllowed(nr));
    try std.testing.expect(!syscallAllowed(14)); // fork
    try std.testing.expect(!syscallAllowed(17)); // execve
    try std.testing.expect(!syscallAllowed(39)); // socket
    try std.testing.expect(!syscallAllowed(999));
}

test "gdt: ring policy + iret gate" {
    try std.testing.expect(preemptDisableAllowed(.ring0));
    try std.testing.expect(!preemptDisableAllowed(.ring3));
    try std.testing.expect(privilegedOpAllowed(.ring0));
    try std.testing.expect(!privilegedOpAllowed(.ring3));
    try std.testing.expect(iretToUserValid(USER_CODE_SEL, USER_DATA_SEL));
    try std.testing.expect(!iretToUserValid(KERNEL_CODE_SEL, KERNEL_DATA_SEL));
    try std.testing.expect(!iretToUserValid(USER_CODE_SEL, KERNEL_DATA_SEL));
}

test "gdt: user copy gate" {
    const vs: u64 = 0x20000000;
    const ve: u64 = 0x20008000;
    try std.testing.expect(userCopyAllowed(vs, ve, PROT_READ | PROT_WRITE, vs + 0x1000, 64, true));
    try std.testing.expect(userCopyAllowed(vs, ve, PROT_READ | PROT_WRITE, vs, ve - vs, false));
    try std.testing.expect(!userCopyAllowed(vs, ve, PROT_READ, vs, 64, true)); // RO + write
    try std.testing.expect(!userCopyAllowed(vs, ve, PROT_WRITE, vs, 64, false)); // WO + read
    try std.testing.expect(!userCopyAllowed(vs, ve, PROT_READ | PROT_WRITE, ve - 32, 64, false)); // spills past VMA
    try std.testing.expect(!userCopyAllowed(vs, ve, PROT_READ | PROT_WRITE, vs - 8, 8, false)); // starts before VMA
    try std.testing.expect(!userCopyAllowed(vs, ve, PROT_READ | PROT_WRITE, 0xFFFF800000000000, 8, false)); // kernel half
    try std.testing.expect(!userCopyAllowed(vs, ve, PROT_READ | PROT_WRITE, 0xFFFFFFFFFFFFF000, 0x2000, false)); // wrap
    try std.testing.expect(userCopyAllowed(vs, ve, PROT_READ, vs, 0, true)); // zero len harmless
}

test "gdt: tss kernel stack" {
    tssInit(0x90000);
    try std.testing.expectEqual(@as(u64, 0x90000), tss.rsp0);
    try std.testing.expectEqual(@as(u64, 0x90000), tss.ist[0]);
    tssInit(0);
}
