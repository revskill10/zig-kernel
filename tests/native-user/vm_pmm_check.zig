// tests/native-user/vm_pmm_check.zig — PMM-backed adapter accounting/policy.
// Uses the test page-bytes seam; not native physical-memory evidence and
// never @ptrFromInt on synthetic IDs.

const std = @import("std");
const boot_info = @import("boot_info");
const pmm = @import("pmm");
const adapter_mod = @import("user_vm_pmm");
const vm = @import("user_vm");
const elf = @import("user_elf");

const PAGE: u64 = 4096;
const KERNEL_BASE: u64 = 0x200000;
const STACK_BASE: u64 = 0x500000;
const INITRD_BASE: u64 = 0x600000;

var store_bytes: [64][PAGE]u8 align(4096) = undefined;
var store_phys: [64]u64 = [_]u64{0} ** 64;
var store_used: [64]bool = [_]bool{false} ** 64;
var access_n: usize = 0;
var fail_access_at: ?usize = null;
var resolver_calls: usize = 0;

fn resetStore() void {
    @memset(&store_used, false);
    access_n = 0;
    fail_access_at = null;
    resolver_calls = 0;
}

fn resolver(phys: u64) adapter_mod.AccessError!*[PAGE]u8 {
    resolver_calls += 1;
    const n = access_n;
    access_n += 1;
    if (fail_access_at) |f| {
        if (n == f) return error.PageAccess;
    }
    if (phys == 0) return error.PhysicalZero;
    var i: usize = 0;
    while (i < store_phys.len) : (i += 1) {
        if (store_used[i] and store_phys[i] == phys) return &store_bytes[i];
    }
    i = 0;
    while (i < store_used.len) : (i += 1) {
        if (!store_used[i]) {
            store_used[i] = true;
            store_phys[i] = phys;
            @memset(&store_bytes[i], 0xA5);
            return &store_bytes[i];
        }
    }
    return error.PageAccess;
}

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
    s[n] = .{ .phys_start = 0x0, .page_count = 0x100, .kind = .conventional, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = 0x100000, .page_count = 0x100, .kind = .kernel, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = KERNEL_BASE, .page_count = 0x40, .kind = .kernel, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = STACK_BASE, .page_count = 0x10, .kind = .kernel_stack, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = INITRD_BASE, .page_count = 0x2, .kind = .initramfs, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = self_page, .page_count = 4, .kind = .boot_info, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = 0x800000, .page_count = (240 * 1024 * 1024 + 32 * 1024 * 1024) / 4096, .kind = .conventional, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = 0x20000000, .page_count = 0x1000, .kind = .conventional, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = 0xF0000000, .page_count = 0x100, .kind = .mmio, ._pad = 0 };
    n += 1;
    info.range_count = n;
    info.checksum = info.computeChecksum();
    info.validate() catch @panic("fixture256 must validate");
    return info;
}

fn fixtureOnlyZero(buf: *[16384]u8) *boot_info.BootInfo {
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
    s[n] = .{ .phys_start = 0x0, .page_count = 1, .kind = .conventional, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = KERNEL_BASE, .page_count = 0x40, .kind = .kernel, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = STACK_BASE, .page_count = 0x10, .kind = .kernel_stack, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = INITRD_BASE, .page_count = 0x2, .kind = .initramfs, ._pad = 0 };
    n += 1;
    s[n] = .{ .phys_start = self_page, .page_count = 4, .kind = .boot_info, ._pad = 0 };
    n += 1;
    info.range_count = n;
    info.checksum = info.computeChecksum();
    info.validate() catch @panic("fixtureOnlyZero must validate");
    return info;
}

fn w8(buf: []u8, off: usize, v: u8) void {
    buf[off] = v;
}
fn w16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}
fn w32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}
fn w64(buf: []u8, off: usize, v: u64) void {
    var i: usize = 0;
    var x = v;
    while (i < 8) : (i += 1) {
        buf[off + i] = @truncate(x);
        x >>= 8;
    }
}

fn tinyElf(buf: *[0x2000]u8) []u8 {
    @memset(buf, 0);
    @memcpy(buf[0..4], "\x7fELF");
    w8(buf, 4, elf.ELFCLASS64);
    w8(buf, 5, elf.ELFDATA2LSB);
    w8(buf, 6, elf.EV_CURRENT);
    w8(buf, 7, elf.ELFOSABI_NONE);
    w8(buf, 8, 0);
    w16(buf, 16, elf.ET_EXEC);
    w16(buf, 18, elf.EM_X86_64);
    w32(buf, 20, 1);
    w64(buf, 24, elf.IMAGE_LO);
    w64(buf, 32, elf.EHDR_SIZE);
    w16(buf, 52, elf.EHDR_SIZE);
    w16(buf, 54, elf.PHDR_SIZE);
    w16(buf, 56, 2);
    const at = elf.EHDR_SIZE;
    w32(buf, at + 0, elf.PT_LOAD);
    w32(buf, at + 4, elf.PF_R | elf.PF_X);
    w64(buf, at + 8, 0x1000);
    w64(buf, at + 16, elf.IMAGE_LO);
    w64(buf, at + 32, 0x20);
    w64(buf, at + 40, 0x20);
    w64(buf, at + 48, PAGE);
    const at2 = elf.EHDR_SIZE + elf.PHDR_SIZE;
    w32(buf, at2 + 0, elf.PT_GNU_STACK);
    w32(buf, at2 + 4, elf.PF_R | elf.PF_W);
    w64(buf, at2 + 48, 16);
    buf[0x1000] = 0x90;
    return buf[0..0x2000];
}

fn kernelTmpl() vm.KernelTemplate {
    return .{
        .root_phys = 0x00200000,
        .pdpt0_entry = 0x00300000 | vm.PTE_P | vm.PTE_W,
    };
}

test "adapter alloc/free matches PMM accounting via test storage" {
    var buf: [16384]u8 align(4096) = undefined;
    try pmm.init(fixture256(&buf));
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;

    var owned_buf: [32]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);
    const before = pmm.stats();
    const phys = try ad.allocPage();
    try std.testing.expect(pmm.inManagedDomain(phys));
    try std.testing.expect(pmm.isAllocatable(phys));
    try std.testing.expect(phys != 0);
    try std.testing.expectEqual(before.used + 1, pmm.stats().used);
    try std.testing.expectEqual(before.free - 1, pmm.stats().free);
    const page = try ad.pageBytes(phys);
    try std.testing.expectEqual(@as(u8, 0xA5), page[0]);
    try std.testing.expect(ad.freePage(phys));
    try std.testing.expectEqual(before.used, pmm.stats().used);
    try std.testing.expectEqual(before.free, pmm.stats().free);
}

test "adapter rejects reserved non-conventional and out-of-domain frames" {
    var buf: [16384]u8 align(4096) = undefined;
    try pmm.init(fixture256(&buf));
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;
    var owned_buf: [32]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);

    try std.testing.expectError(error.NotOwnedFrame, ad.pageBytes(KERNEL_BASE));
    try std.testing.expectError(error.NotOwnedFrame, ad.pageBytes(STACK_BASE));
    try std.testing.expectError(error.NotOwnedFrame, ad.pageBytes(INITRD_BASE));
    try std.testing.expectError(error.FrameOutOfDomain, ad.pageBytes(pmm.MANAGED_TOP));
    try std.testing.expectError(error.FrameUnaligned, ad.pageBytes(0x800001));
    try std.testing.expectError(error.PhysicalZero, ad.pageBytes(0));
    try std.testing.expect(!ad.freePage(KERNEL_BASE));
    try std.testing.expect(!ad.freePage(0xF0000000));
}

test "physical frame zero is rejected and released without a null pointer" {
    var buf: [16384]u8 align(4096) = undefined;
    try pmm.init(fixtureOnlyZero(&buf));
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;
    var owned_buf: [4]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);
    const before = pmm.stats();
    try std.testing.expectEqual(@as(u64, 1), before.total);
    try std.testing.expectError(error.PhysicalZero, ad.allocPage());
    try std.testing.expectEqual(before.used, pmm.stats().used);
    try std.testing.expectEqual(before.free, pmm.stats().free);
    try std.testing.expectError(error.PhysicalZero, ad.pageBytes(0));
}

test "construct/destroy through adapter restores PMM counts; storage starts poisoned" {
    var buf: [16384]u8 align(4096) = undefined;
    try pmm.init(fixture256(&buf));
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;

    var owned_buf: [64]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);
    var jbuf: [64]u64 = undefined;
    var journal = vm.Journal.init(&jbuf);
    var space = vm.AddressSpace.init(&journal);
    var img_buf: [0x2000]u8 = undefined;
    const img = tinyElf(&img_buf);
    const before = pmm.stats();
    try vm.construct(&ad, img, kernelTmpl(), &space);
    try std.testing.expectEqual(before.used + space.ownedCount(), pmm.stats().used);
    var i: usize = 0;
    while (i < space.ownedCount()) : (i += 1) {
        const f = journal.frames[i];
        try std.testing.expect(pmm.inManagedDomain(f));
        try std.testing.expect(f < pmm.MANAGED_TOP);
        try std.testing.expect(f != 0);
    }
    try vm.destroy(&ad, &space, .inactive);
    try std.testing.expectEqual(before.used, pmm.stats().used);
    try std.testing.expectEqual(before.free, pmm.stats().free);
}

test "adapter construction failure rolls PMM accounting back" {
    var buf: [16384]u8 align(4096) = undefined;
    try pmm.init(fixture256(&buf));
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;

    var owned_buf: [64]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);
    var jbuf: [64]u64 = undefined;
    var journal = vm.Journal.init(&jbuf);
    var space = vm.AddressSpace.init(&journal);
    var img_buf: [0x2000]u8 = undefined;
    const img = tinyElf(&img_buf);
    const before = pmm.stats();
    fail_access_at = 0;
    try std.testing.expectError(error.PageAccess, vm.construct(&ad, img, kernelTmpl(), &space));
    try std.testing.expectEqual(before.used, pmm.stats().used);
    try std.testing.expectEqual(before.free, pmm.stats().free);
    try std.testing.expectEqual(vm.State.empty, space.state);
}

test "PMM does not zero; constructor zeros through the test seam" {
    var buf: [16384]u8 align(4096) = undefined;
    try pmm.init(fixture256(&buf));
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;
    var owned_buf: [8]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);
    const phys = try ad.allocPage();
    const page = try ad.pageBytes(phys);
    try std.testing.expectEqual(@as(u8, 0xA5), page[0]);
    try std.testing.expect(ad.freePage(phys));
}

test "adapter live ownership rejects eligible-free foreign other-adapter and post-release" {
    var buf: [16384]u8 align(4096) = undefined;
    try pmm.init(fixture256(&buf));
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;

    var a_store: [16]u64 = undefined;
    var b_store: [16]u64 = undefined;
    var a = adapter_mod.Adapter.init(&a_store);
    var b = adapter_mod.Adapter.init(&b_store);
    const before = pmm.stats();

    const eligible_free: u64 = 0x1000;
    try std.testing.expect(pmm.isAllocatable(eligible_free));
    try std.testing.expect(!a.owns(eligible_free));
    const calls0 = resolver_calls;
    try std.testing.expectError(error.NotOwnedFrame, a.pageBytes(eligible_free));
    try std.testing.expect(!a.freePage(eligible_free));
    try std.testing.expectEqual(calls0, resolver_calls);
    try std.testing.expectEqual(before.used, pmm.stats().used);
    try std.testing.expectEqual(before.free, pmm.stats().free);

    const foreign = pmm.allocPage() orelse return error.NoPage;
    try std.testing.expect(pmm.isAllocatable(foreign));
    try std.testing.expectError(error.NotOwnedFrame, a.pageBytes(foreign));
    try std.testing.expect(!a.freePage(foreign));
    try std.testing.expectEqual(before.used + 1, pmm.stats().used);
    try std.testing.expect(pmm.freePage(foreign));
    try std.testing.expectEqual(before.used, pmm.stats().used);

    const pa = try a.allocPage();
    try std.testing.expectEqual(@as(usize, 1), a.ownedCount());
    try std.testing.expect(a.owns(pa));
    try std.testing.expect(!b.owns(pa));
    const calls1 = resolver_calls;
    try std.testing.expectError(error.NotOwnedFrame, b.pageBytes(pa));
    try std.testing.expect(!b.freePage(pa));
    try std.testing.expectEqual(calls1, resolver_calls);
    try std.testing.expectEqual(@as(usize, 1), a.ownedCount());
    const page = try a.pageBytes(pa);
    try std.testing.expectEqual(@as(u8, 0xA5), page[0]);

    const pb = try b.allocPage();
    try std.testing.expect(pb != pa);
    try std.testing.expectError(error.NotOwnedFrame, a.pageBytes(pb));
    try std.testing.expect(!a.freePage(pb));
    try std.testing.expect(b.freePage(pb));
    try std.testing.expectEqual(@as(usize, 0), b.ownedCount());
    try std.testing.expectError(error.NotOwnedFrame, b.pageBytes(pb));
    try std.testing.expect(!b.freePage(pb));

    try std.testing.expect(a.freePage(pa));
    try std.testing.expectEqual(@as(usize, 0), a.ownedCount());
    try std.testing.expectError(error.NotOwnedFrame, a.pageBytes(pa));
    try std.testing.expect(!a.freePage(pa));
    try std.testing.expectEqual(before.used, pmm.stats().used);
    try std.testing.expectEqual(before.free, pmm.stats().free);
}

test "adapter refused PMM free retains per-adapter ownership" {
    var buf: [16384]u8 align(4096) = undefined;
    try pmm.init(fixture256(&buf));
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;

    var owned_buf: [8]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);
    const phys = try ad.allocPage();
    const used_after_alloc = pmm.stats().used;
    try std.testing.expect(pmm.freePage(phys));
    try std.testing.expectEqual(used_after_alloc - 1, pmm.stats().used);
    try std.testing.expect(ad.owns(phys));
    try std.testing.expect(!ad.freePage(phys));
    try std.testing.expectEqual(@as(usize, 1), ad.ownedCount());
    try std.testing.expect(ad.owns(phys));
    const page = try ad.pageBytes(phys);
    try std.testing.expectEqual(@as(u8, 0xA5), page[0]);
}

test "hosted resolver is not invoked for unowned synthetic IDs" {
    var buf: [16384]u8 align(4096) = undefined;
    try pmm.init(fixture256(&buf));
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;

    var owned_buf: [4]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);
    const calls = resolver_calls;
    try std.testing.expectError(error.NotOwnedFrame, ad.pageBytes(0x800000));
    try std.testing.expectEqual(calls, resolver_calls);
}

test "adapter does not claim zero released when PMM free refuses" {
    var buf: [16384]u8 align(4096) = undefined;
    const info = fixtureOnlyZero(&buf);
    try pmm.init(info);
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;

    var owned_buf: [4]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);
    const before = pmm.stats();
    try std.testing.expectEqual(@as(u64, 1), before.total);
    try std.testing.expectEqual(@as(u64, 0), before.used);

    // freePage re-checks the cached map. Marking the published zero range
    // non-conventional after init makes PMM refuse the return without a
    // pmm.zig edit. A just-allocated conventional zero otherwise always
    // frees successfully, so this is the injectable refusal seam.
    info.rangesStorage()[0].kind = .kernel;
    const phys = try ad.allocPage();
    try std.testing.expectEqual(@as(u64, 0), phys);
    try std.testing.expectEqual(@as(usize, 1), ad.ownedCount());
    try std.testing.expect(ad.owns(0));
    try std.testing.expectEqual(before.used + 1, pmm.stats().used);
    try std.testing.expectEqual(before.free - 1, pmm.stats().free);
    try std.testing.expectError(error.PhysicalZero, ad.pageBytes(0));
    try std.testing.expect(!ad.freePage(0));
    try std.testing.expectEqual(@as(usize, 1), ad.ownedCount());
    try std.testing.expect(ad.owns(0));
    try std.testing.expectEqual(before.used + 1, pmm.stats().used);

    info.rangesStorage()[0].kind = .conventional;
    try std.testing.expect(ad.freePage(0));
    try std.testing.expectEqual(@as(usize, 0), ad.ownedCount());
    try std.testing.expect(!ad.owns(0));
    try std.testing.expectEqual(before.used, pmm.stats().used);
    try std.testing.expectEqual(before.free, pmm.stats().free);
    try std.testing.expectError(error.PhysicalZero, ad.pageBytes(0));
    try std.testing.expect(!ad.freePage(0));
}

test "PMM adapter zero release refusal is core ReleaseFailed and blocks reuse" {
    var buf: [16384]u8 align(4096) = undefined;
    const info = fixtureOnlyZero(&buf);
    try pmm.init(info);
    resetStore();
    adapter_mod.page_bytes_resolver = resolver;
    defer adapter_mod.page_bytes_resolver = null;

    var owned_buf: [8]u64 = undefined;
    var ad = adapter_mod.Adapter.init(&owned_buf);
    var jbuf: [64]u64 = undefined;
    var journal = vm.Journal.init(&jbuf);
    var space = vm.AddressSpace.init(&journal);
    var img_buf: [0x2000]u8 = undefined;
    const img = tinyElf(&img_buf);
    const used_before = pmm.stats().used;

    info.rangesStorage()[0].kind = .kernel;
    try std.testing.expectError(error.ReleaseFailed, vm.construct(&ad, img, kernelTmpl(), &space));
    try std.testing.expectEqual(vm.State.destroyed, space.state);
    try std.testing.expect(space.owns_zero);
    try std.testing.expectEqual(@as(usize, 1), space.ownedCount());
    try std.testing.expectEqual(@as(usize, 0), journal.count);
    try std.testing.expectEqual(@as(u64, 0), space.failed_release_frame);
    try std.testing.expectEqual(@as(usize, 1), ad.ownedCount());
    try std.testing.expect(ad.owns(0));
    try std.testing.expectEqual(used_before + 1, pmm.stats().used);
    try std.testing.expectError(error.InvalidState, vm.reset(&space));
    try std.testing.expectError(error.InvalidState, vm.construct(&ad, img, kernelTmpl(), &space));
    try std.testing.expectEqual(@as(usize, 1), ad.ownedCount());
    try std.testing.expectEqual(used_before + 1, pmm.stats().used);

    try std.testing.expectError(error.ReleaseFailed, vm.retryRelease(&ad, &space));
    try std.testing.expect(space.owns_zero);
    try std.testing.expectEqual(@as(usize, 1), ad.ownedCount());

    info.rangesStorage()[0].kind = .conventional;
    try vm.retryRelease(&ad, &space);
    try std.testing.expectEqual(@as(usize, 0), space.ownedCount());
    try std.testing.expect(!space.owns_zero);
    try std.testing.expectEqual(@as(usize, 0), ad.ownedCount());
    try std.testing.expectEqual(used_before, pmm.stats().used);
    try vm.reset(&space);
    try std.testing.expectEqual(vm.State.empty, space.state);
}
