// tests/native-pmm/check.zig — hosted N3 acceptance for PMM/mapping consistency.
// Imports named `pmm` + `boot_info` modules, so run with CLI wiring:
//   zig test -Mboot_info=src/native/boot_info.zig \
//       --dep boot_info -Mpmm=src/arch/x86_64/native/pmm.zig \
//       --dep boot_info --dep pmm -Mroot=tests/native-pmm/check.zig
// (Root wires it into test-native per muse-n3 build request; bare
// `zig test tests/native-pmm/check.zig` does NOT resolve the imports.)

const std = @import("std");
const boot_info = @import("boot_info");
const pmm = @import("pmm");

const KERNEL_BASE: u64 = 0x200000;
const STACK_BASE: u64 = 0x500000;
const INITRD_BASE: u64 = 0x600000;

/// Build a validated 256 MiB-like BootInfo in `buf`: conventional RAM with
/// owned/kernel/stack/initramfs/boot-info carve-outs, one range straddling
/// the managed ceiling, one fully above it, one reserved region.
fn fixture256(buf: *[16384]u8) *boot_info.BootInfo {
    @memset(buf, 0);
    const info: *boot_info.BootInfo = @ptrCast(@alignCast(buf));
    const self_page = @intFromPtr(info) & ~@as(u64, 4095);
    info.* = .{
        .total_size = 16384,
        .range_count = 0,
        .efi_desc_size = 48,
        .efi_desc_version = 1,
        .kernel_base = KERNEL_BASE,
        .kernel_size = 0x40000,
        .kernel_entry = KERNEL_BASE + 0x100,
        .initramfs_base = INITRD_BASE,
        .initramfs_size = 0x2000,
        .stack_base = STACK_BASE,
        .stack_size = 0x10000,
    };
    const s = info.rangesStorage();
    var n: usize = 0;
    s[n] = .{ .phys_start = 0x0, .page_count = 0x100, .kind = .conventional, ._pad = 0 }; // low RAM incl. firmware hole below
    n += 1;
    s[n] = .{ .phys_start = 0x100000, .page_count = 0x100, .kind = .kernel, ._pad = 0 }; // 1 MiB..2 MiB firmware/loader-owned
    n += 1;
    s[n] = .{ .phys_start = KERNEL_BASE, .page_count = 0x40, .kind = .kernel, ._pad = 0 }; // kernel image ≤ 2 MiB span
    n += 1;
    s[n] = .{ .phys_start = STACK_BASE, .page_count = 0x10, .kind = .kernel_stack, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = INITRD_BASE, .page_count = 0x2, .kind = .initramfs, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = self_page, .page_count = 4, .kind = .boot_info, ._pad = 0 };
    n += 1;
    // Conventional 8 MiB .. (256 MiB + 32 MiB): tail crosses the ceiling.
    s[n] = .{ .phys_start = 0x800000, .page_count = (240 * 1024 * 1024 + 32 * 1024 * 1024) / 4096, .kind = .conventional, ._pad = 0 };
    n += 1;
    // Conventional fully above the ceiling: entirely unmanaged.
    s[n] = .{ .phys_start = 0x20000000, .page_count = 0x1000, .kind = .conventional, ._pad = 0 };
    n += 1;
    // MMIO/reserved holes: excluded, never allocatable.
    s[n] = .{ .phys_start = 0xF0000000, .page_count = 0x100, .kind = .mmio, ._pad = 0 };
    n += 1;
    info.range_count = n;
    info.checksum = info.computeChecksum();
    info.validate() catch @panic("fixture256 must validate");
    return info;
}

test "n3: 256MiB profile totals, clipping and exclusion accounting" {
    var buf: [16384]u8 align(4096) = undefined;
    const info = fixture256(&buf);
    try pmm.init(info);
    const st = pmm.stats();
    // Managed: 0x0/0x100 + 0x800000..256MiB tail portion.
    const expect_total: u64 = 0x100 + (pmm.MANAGED_TOP - 0x800000) / 4096;
    try std.testing.expectEqual(expect_total, st.total);
    try std.testing.expectEqual(st.total, st.free);
    try std.testing.expectEqual(@as(u64, 0), st.used);
    // Unmanaged: 24 MiB tail above the ceiling (272 MiB range less the
    // 248 MiB managed portion) + 0x1000 pages fully above the ceiling.
    try std.testing.expectEqual(@as(u64, (24 * 1024 * 1024) / 4096 + 0x1000), st.unmanaged);
    // Excluded: firmware block + kernel + stack + initramfs + boot-info + mmio.
    try std.testing.expectEqual(@as(u64, 0x100 + 0x40 + 0x10 + 0x2 + 4 + 0x100), st.excluded);
}

test "n3: alloc returns mapped usable non-owned pages; exhaustion is null" {
    var buf: [16384]u8 align(4096) = undefined;
    const info = fixture256(&buf);
    try pmm.init(info);
    const before = pmm.stats();
    var n: u64 = 0;
    while (pmm.allocPage()) |pg| {
        try std.testing.expect(pmm.inManagedDomain(pg));
        try std.testing.expect(pmm.isAllocatable(pg));
        n += 1;
    }
    try std.testing.expectEqual(before.total, n);
    try std.testing.expectEqual(@as(u64, 0), pmm.stats().free);
    try std.testing.expect(pmm.allocPage() == null); // exhaustion, not TooManyPages
}

test "n3: invalid frees rejected, double free rejected, accounting restored" {
    var buf: [16384]u8 align(4096) = undefined;
    const info = fixture256(&buf);
    try pmm.init(info);
    const before = pmm.stats();
    const pg = pmm.allocPage() orelse return error.NoPage;
    try std.testing.expectEqual(before.free - 1, pmm.stats().free);
    // Unaligned, above-ceiling, owned, MMIO, unknown-conventional all rejected.
    try std.testing.expect(!pmm.freePage(pg + 1)); // unaligned
    try std.testing.expect(!pmm.freePage(pmm.MANAGED_TOP)); // above ceiling
    try std.testing.expect(!pmm.freePage(KERNEL_BASE)); // owned kernel
    try std.testing.expect(!pmm.freePage(STACK_BASE)); // owned stack
    try std.testing.expect(!pmm.freePage(0xF0000000)); // mmio
    try std.testing.expect(!pmm.freePage(0x700000)); // conventional hole unknown to map
    try std.testing.expectEqual(before.free - 1, pmm.stats().free);
    // Valid free accepted once, then double free rejected with no drift.
    try std.testing.expect(pmm.freePage(pg));
    try std.testing.expectEqual(before.free, pmm.stats().free);
    try std.testing.expect(!pmm.freePage(pg)); // double free
    try std.testing.expectEqual(before.free, pmm.stats().free);
    try std.testing.expectEqual(before.used, pmm.stats().used);
}

test "n3: pre-init alloc/free are inert; bad BootInfo fails closed" {
    // Force a fresh uninitialized view by feeding a bad map first.
    var buf: [16384]u8 align(4096) = undefined;
    @memset(&buf, 0);
    const bad: *boot_info.BootInfo = @ptrCast(@alignCast(&buf));
    bad.* = .{
        .total_size = 16384,
        .range_count = 0,
        .efi_desc_size = 48,
        .efi_desc_version = 1,
        .kernel_base = KERNEL_BASE,
        .kernel_size = 0x1000,
        .kernel_entry = KERNEL_BASE,
        .initramfs_base = INITRD_BASE,
        .initramfs_size = 0x1000,
        .stack_base = STACK_BASE,
        .stack_size = 0x1000,
    };
    bad.checksum = bad.computeChecksum();
    try std.testing.expectError(error.BadBootInfo, pmm.init(bad)); // zero ranges: coverage fails
    try std.testing.expect(!pmm.isInitialized());
    try std.testing.expect(pmm.allocPage() == null);
    try std.testing.expect(!pmm.freePage(0x800000));
    const st = pmm.stats();
    try std.testing.expectEqual(@as(u64, 0), st.total);
    try std.testing.expectEqual(@as(u64, 0), st.free);
    try std.testing.expect(!pmm.isAllocatable(0x800000));
}
