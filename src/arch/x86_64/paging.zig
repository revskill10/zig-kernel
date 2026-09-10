// arch/x86_64/paging — user/kernel split + U-bit fault policy (M2).
// Pure logic, freestanding-safe. Real CR3/PTE wiring lands with x86_64
// baremetal boot (needs QEMU); this file is the testable policy ceiling.
pub const USER_MAX: u64 = 0x00007FFFFFFFFFFF;
pub const KERNEL_BASE: u64 = 0xFFFF800000000000;

pub const PTE_P: u64 = 0x1;
pub const PTE_RW: u64 = 0x2;
pub const PTE_U: u64 = 0x4;

pub var pf_handled: usize = 0;
pub var pf_rejected: usize = 0;

pub fn pteFlags(user: bool) u64 {
    return PTE_P | PTE_RW | (if (user) PTE_U else 0);
}

pub fn isUserHalf(addr: u64) bool { return addr <= USER_MAX; }
pub fn isKernelHalf(addr: u64) bool { return addr >= KERNEL_BASE; }

/// Fault decision: 0 = map, -13 = EACCES reject, -14 = EFAULT non-canonical.
/// err_user = U bit in #PF error code. authorized = mm VMA check passed.
pub fn handleFault(addr: u64, err_user: bool, authorized: bool) isize {
    if (isUserHalf(addr)) {
        if (err_user and !authorized) {
            pf_rejected += 1;
            return -13;
        }
        pf_handled += 1;
        return 0;
    }
    if (isKernelHalf(addr)) {
        if (err_user) {
            pf_rejected += 1; // user touched kernel half
            return -13;
        }
        pf_handled += 1;
        return 0;
    }
    pf_rejected += 1; // non-canonical hole
    return -14;
}

pub fn mapsWithU(addr: u64) bool {
    return isUserHalf(addr);
}

const std = @import("std");

test "paging64: user fault authorized maps" {
    const h = pf_handled;
    try std.testing.expectEqual(@as(isize, 0), handleFault(0x20001000, true, true));
    try std.testing.expectEqual(h + 1, pf_handled);
    try std.testing.expect(pteFlags(true) & PTE_U != 0);
}

test "paging64: user fault unauthorized rejects" {
    const r = pf_rejected;
    try std.testing.expectEqual(@as(isize, -13), handleFault(0x20001000, true, false));
    try std.testing.expectEqual(r + 1, pf_rejected);
    try std.testing.expect(pteFlags(false) & PTE_U == 0);
}

test "paging64: kernel half rejects user, allows supervisor" {
    try std.testing.expectEqual(@as(isize, -13), handleFault(KERNEL_BASE + 0x1000, true, true));
    try std.testing.expectEqual(@as(isize, 0), handleFault(KERNEL_BASE + 0x1000, false, false));
    try std.testing.expect(isKernelHalf(KERNEL_BASE));
    try std.testing.expect(!isUserHalf(KERNEL_BASE));
}

test "paging64: non-canonical hole faults" {
    try std.testing.expectEqual(@as(isize, -14), handleFault(USER_MAX + 1, false, true));
    try std.testing.expectEqual(@as(isize, -14), handleFault(KERNEL_BASE - 1, true, true));
}
