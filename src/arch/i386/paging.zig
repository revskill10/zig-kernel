// Identity paging for x86 32-bit: maps low 64 MiB (16 x 4 MiB) as 4 KiB pages, demand-extend to 256 MiB.
const builtin = @import("builtin");

pub const MAX_PT: usize = 64; // 64 * 4MiB = 256 MiB demand window

pub var page_directory: [1024]u32 align(4096) = [_]u32{0} ** 1024;
pub var page_tables: [MAX_PT][1024]u32 align(4096) = [_][1024]u32{ [_]u32{0} ** 1024 } ** MAX_PT;

pub var pf_handled: usize = 0;

pub fn invlpg(addr: usize) void {
    if (comptime builtin.target.os.tag == .freestanding) {
        asm volatile ("invlpg (%[a])" : : [a] "r" (addr) : .{ .memory = true });
    }
}

pub fn paging_init() void {
    // identity map first 16 tables (64 MiB)
    for (0..MAX_PT) |pt_idx| {
        for (0..1024) |i| {
            if (pt_idx < 16) {
                const frame: u32 = @as(u32, @intCast(pt_idx * 1024 + i));
                page_tables[pt_idx][i] = (frame * 4096) | 0x3; // P | RW
            } else {
                page_tables[pt_idx][i] = 0;
            }
        }
    }
    for (0..1024) |i| {
        if (i < 16) {
            page_directory[i] = @as(u32, @truncate(@intFromPtr(&page_tables[i][0]) & 0xFFFFF000)) | 0x3;
        } else if (i < MAX_PT) {
            page_directory[i] = 0;
        } else {
            page_directory[i] = 0;
        }
    }
    if (comptime builtin.target.os.tag == .freestanding) {
        const pdir: u32 = @as(u32, @truncate(@intFromPtr(&page_directory[0])));
        asm volatile ("mov %[p], %%cr3" : : [p] "r" (pdir) : .{ .memory = true });
        var cr0: u32 = asm volatile ("mov %%cr0, %[r]" : [r] "=r" (-> u32));
        cr0 |= 0x80000000;
        asm volatile ("mov %[v], %%cr0" : : [v] "r" (cr0) : .{ .memory = true });
    }
}

pub fn isMapped(vaddr: usize) bool {
    const pd: usize = vaddr >> 22;
    const pt: usize = (vaddr >> 12) & 0x3FF;
    if (pd >= MAX_PT) return false;
    if ((page_directory[pd] & 0x1) == 0) return false;
    return (page_tables[pd][pt] & 0x1) != 0;
}

pub fn getPDE(vaddr: usize) u32 {
    const pd: usize = vaddr >> 22;
    if (pd >= 1024) return 0;
    return page_directory[pd];
}

pub fn getPTE(vaddr: usize) u32 {
    const pd: usize = vaddr >> 22;
    const pt: usize = (vaddr >> 12) & 0x3FF;
    if (pd >= MAX_PT) return 0;
    return page_tables[pd][pt];
}

// handle_mm_fault: Linux-like, called from #PF handler with CR2 fault addr + error code.
// error_code bits: 0=P,1=W,2=U,3=RSVD,4=I.
// Kernel-only entry: supervisor faults get identity RW; user-origin (U set)
// REJECTED with -13 EACCES, nothing installed (Qodo #2). Use
// handle_mm_fault_user when the mm layer authorized the address via VMA.
// Returns 0 ok, -12 ENOMEM out of window, -13 EACCES user fault, -14 EFAULT bogus.
// ponytail: fixed 64 PT identity RW only, no swap/COW here (mm.zig owns VMA/COW).
// ceiling: PTE-level COW refs + swap entries.
pub fn handle_mm_fault(fault_addr: u32, error_code: u32) isize {
    if ((error_code & 0x4) != 0) return -13; // -EACCES: use _user variant after VMA auth
    return mapIdentity(fault_addr, false);
}

fn mapIdentity(fault_addr: u32, user: bool) isize {
    const pd: usize = @as(usize, @intCast(fault_addr >> 22));
    const pt: usize = @as(usize, @intCast((fault_addr >> 12) & 0x3FF));
    const frame: u32 = fault_addr & 0xFFFFF000;
    if (pd >= MAX_PT) return -12;
    if (pd >= 1024) return -14;
    const ubit: u32 = if (user) 0x4 else 0;
    if ((page_directory[pd] & 0x1) == 0) {
        page_directory[pd] = @as(u32, @truncate(@intFromPtr(&page_tables[pd][0]) & 0xFFFFF000)) | 0x3 | ubit;
    } else if (user) {
        page_directory[pd] |= 0x4;
    }
    const pte = &page_tables[pd][pt];
    if ((pte.* & 0x1) == 0) {
        pte.* = frame | 0x3 | ubit;
    } else {
        pte.* |= 0x2;
        if (user) pte.* |= 0x4;
    }
    invlpg(@intCast(fault_addr));
    pf_handled += 1;
    return 0;
}

/// User-authorized fault: installs a U-bit PTE, but ONLY when the caller
/// (mm layer) already validated the address against a VMA (findVma + prot).
/// user_allowed=false behaves exactly like handle_mm_fault (reject U).
/// No imports: paging stays freestanding-safe; mm.zig owns VMA policy.
/// ponytail: identity frame (no frame allocator yet); ceiling: buddy frame.
pub fn handle_mm_fault_user(fault_addr: u32, error_code: u32, user_allowed: bool) isize {
    const is_user = (error_code & 0x4) != 0;
    if (is_user and !user_allowed) return -13;
    return mapIdentity(fault_addr, is_user);
}

const std = @import("std");
test "paging: handle_mm_fault maps unmapped page" {
    paging_init();
    const addr1: u32 = 0x05000000;
    try std.testing.expect(!isMapped(addr1));
    try std.testing.expect(getPDE(addr1) == 0);
    const before = pf_handled;
    const rc = handle_mm_fault(addr1, 0x2);
    try std.testing.expect(rc == 0);
    try std.testing.expect(isMapped(addr1));
    try std.testing.expect((getPTE(addr1) & 0x1) != 0);
    try std.testing.expect(pf_handled == before + 1);
    const rc2 = handle_mm_fault(addr1, 0x2);
    try std.testing.expect(rc2 == 0);
    try std.testing.expect(pf_handled == before + 2);
}

test "paging: handle_mm_fault rejects user fault" {
    paging_init();
    const before = pf_handled;
    const rc = handle_mm_fault(0x05000000, 0x6); // U|W user-origin write fault
    try std.testing.expect(rc == -13);
    try std.testing.expect(!isMapped(0x05000000));
    try std.testing.expect(pf_handled == before); // no mapping installed, no count
}

test "paging: handle_mm_fault out of range" {
    paging_init();
    const bad: u32 = @as(u32, MAX_PT) << 22;
    const rc = handle_mm_fault(bad, 0);
    try std.testing.expect(rc == -12);
}

test "paging: isMapped for identity region" {
    paging_init();
    try std.testing.expect(isMapped(0x00100000));
    try std.testing.expect(!isMapped(0x07000000));
}

test "paging: handle_mm_fault_user maps U-bit when authorized" {
    paging_init();
    const rc = handle_mm_fault_user(0x05000000, 0x6, true);
    try std.testing.expect(rc == 0);
    try std.testing.expect(isMapped(0x05000000));
    try std.testing.expect((getPTE(0x05000000) & 0x4) != 0); // U bit set
    try std.testing.expect((getPDE(0x05000000) & 0x4) != 0);
}

test "paging: handle_mm_fault_user rejects unauthorized U fault" {
    paging_init();
    const before = pf_handled;
    const rc = handle_mm_fault_user(0x05000000, 0x6, false);
    try std.testing.expect(rc == -13);
    try std.testing.expect(!isMapped(0x05000000));
    try std.testing.expect(pf_handled == before);
}
