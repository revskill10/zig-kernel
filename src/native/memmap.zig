// src/native/memmap — memory-map normalization for the EFI→native handoff.
// Pure logic, host-testable: the EFI loader feeds raw descriptors, the same
// code runs in hosted fixtures (N1 repair). Owned handoff regions (kernel,
// initramfs, stack, BootInfo) are carved out of their source descriptors so
// no two recorded ranges ever overlap. Capacity exhaustion is an error,
// never a silent drop.

pub const boot_info = @import("boot_info");

pub const PAGE: u64 = 4096;
/// Scratch fragment ceiling per descriptor. Four disjoint owned spans add at
/// most two fragments each (≤9 live); anything beyond this is a malformed
/// overlapping-owned input and fails closed instead of overflowing scratch.
const MAX_PIECES: usize = 32;

pub const Desc = struct {
    start: u64, // physical, page-aligned
    pages: u64,
    kind: boot_info.RangeKind,
};

pub const Span = struct {
    base: u64,
    size: u64, // page multiple; zero-size spans are skipped
    kind: boot_info.RangeKind,
};

pub const Error = error{
    Capacity,
    AddressOverflow,
    Misaligned,
    FragmentCapacity,
};

fn emit(storage: []boot_info.Range, n: *usize, start: u64, end: u64, kind: boot_info.RangeKind) Error!void {
    if (end <= start) return;
    if (n.* >= storage.len) return error.Capacity;
    storage[n.*] = .{
        .phys_start = start,
        .page_count = (end - start) / PAGE,
        .kind = kind,
        ._pad = 0,
    };
    n.* += 1;
}

/// Normalize `descs` into `storage`, carving each owned span out of the
/// descriptor it sits in. Returns the populated range count. All address
/// arithmetic is checked: a wrapping descriptor or owned span, a misaligned
/// input, or fragment/storage exhaustion is an error, never a silent drop.
/// An owned span outside every descriptor is ignored here; the caller's
/// `BootInfo.validate` then fails coverage, keeping the handoff fail-closed.
pub fn normalize(descs: []const Desc, owned: []const Span, storage: []boot_info.Range) Error!usize {
    var n: usize = 0;
    for (descs) |d| {
        if (d.pages == 0) continue;
        if (d.start % PAGE != 0) return error.Misaligned;
        const bytes = std.math.mul(u64, d.pages, PAGE) catch return error.AddressOverflow;
        const d_end = std.math.add(u64, d.start, bytes) catch return error.AddressOverflow;
        // Piece list starts as the whole descriptor; each owned span splits it.
        var pieces: [MAX_PIECES]Span = undefined;
        var pc: usize = 1;
        pieces[0] = .{ .base = d.start, .size = d_end - d.start, .kind = d.kind };
        for (owned) |o| {
            if (o.size == 0) continue;
            if (o.base % PAGE != 0 or o.size % PAGE != 0) return error.Misaligned;
            const o_end = std.math.add(u64, o.base, o.size) catch return error.AddressOverflow;
            var next: usize = 0;
            var new_pieces: [MAX_PIECES]Span = undefined;
            for (pieces[0..pc]) |p| {
                // p.base + p.size <= d_end or <= o_end by construction, so
                // this cannot wrap; the pieces below stay inside [d, d_end].
                const p_end = p.base + p.size;
                if (o_end <= p.base or o.base >= p_end) {
                    if (next >= new_pieces.len) return error.FragmentCapacity;
                    new_pieces[next] = p;
                    next += 1;
                    continue;
                }
                if (o.base > p.base) {
                    if (next >= new_pieces.len) return error.FragmentCapacity;
                    new_pieces[next] = .{ .base = p.base, .size = o.base - p.base, .kind = p.kind };
                    next += 1;
                }
                if (next >= new_pieces.len) return error.FragmentCapacity;
                new_pieces[next] = .{
                    .base = @max(o.base, p.base),
                    .size = @min(o_end, p_end) - @max(o.base, p.base),
                    .kind = o.kind,
                };
                next += 1;
                if (o_end < p_end) {
                    if (next >= new_pieces.len) return error.FragmentCapacity;
                    new_pieces[next] = .{ .base = o_end, .size = p_end - o_end, .kind = p.kind };
                    next += 1;
                }
            }
            for (new_pieces[0..next], 0..) |np, i| pieces[i] = np;
            pc = next;
        }
        for (pieces[0..pc]) |p| {
            // p.base + p.size <= d_end by construction; cannot wrap.
            try emit(storage, &n, p.base, p.base + p.size, p.kind);
        }
    }
    return n;
}

const std = @import("std");

fn range(start: u64, pages: u64, kind: boot_info.RangeKind) boot_info.Range {
    return .{ .phys_start = start, .page_count = pages, .kind = kind, ._pad = 0 };
}

test "memmap: plain descriptors pass through" {
    var storage: [8]boot_info.Range = undefined;
    const descs = [_]Desc{
        .{ .start = 0x0, .pages = 0x10, .kind = .conventional },
        .{ .start = 0x10000, .pages = 0x20, .kind = .reserved },
    };
    const n = try normalize(&descs, &.{}, &storage);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 0x10), storage[0].page_count);
    try std.testing.expectEqual(boot_info.RangeKind.reserved, storage[1].kind);
}

test "memmap: owned span carved from the middle of a descriptor" {
    var storage: [8]boot_info.Range = undefined;
    const descs = [_]Desc{.{ .start = 0x200000, .pages = 0x100, .kind = .loader }};
    const owned = [_]Span{.{ .base = 0x208000, .size = 0x40000, .kind = .kernel }};
    const n = try normalize(&descs, &owned, &storage);
    try std.testing.expectEqual(@as(usize, 3), n);
    // loader [0x200000,0x208000), kernel [0x208000,0x248000), loader [0x248000,0x300000)
    try std.testing.expectEqual(boot_info.RangeKind.loader, storage[0].kind);
    try std.testing.expectEqual(@as(u64, 0x200000), storage[0].phys_start);
    try std.testing.expectEqual(@as(u64, 0x8), storage[0].page_count);
    try std.testing.expectEqual(boot_info.RangeKind.kernel, storage[1].kind);
    try std.testing.expectEqual(@as(u64, 0x40), storage[1].page_count);
    try std.testing.expectEqual(boot_info.RangeKind.loader, storage[2].kind);
    try std.testing.expectEqual(@as(u64, 0x248000), storage[2].phys_start);
    try std.testing.expectEqual(@as(u64, 0xB8), storage[2].page_count);
    // Total pages conserved.
    const total = storage[0].page_count + storage[1].page_count + storage[2].page_count;
    try std.testing.expectEqual(@as(u64, 0x100), total);
}

test "memmap: multiple owned spans in one descriptor stay disjoint" {
    var storage: [8]boot_info.Range = undefined;
    const descs = [_]Desc{.{ .start = 0x0, .pages = 0x100, .kind = .conventional }};
    const owned = [_]Span{
        .{ .base = 0x10000, .size = 0x10000, .kind = .kernel_stack },
        .{ .base = 0x40000, .size = 0x20000, .kind = .initramfs },
    };
    const n = try normalize(&descs, &owned, &storage);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expect(!boot_info.rangesOverlap(storage[0..n]));
}

test "memmap: exact capacity accepted, overflow is an error not a drop" {
    var storage: [2]boot_info.Range = undefined;
    const descs = [_]Desc{
        .{ .start = 0x0, .pages = 0x10, .kind = .conventional },
        .{ .start = 0x10000, .pages = 0x10, .kind = .conventional },
    };
    try std.testing.expectEqual(@as(usize, 2), try normalize(&descs, &.{}, &storage));
    const descs3 = [_]Desc{
        .{ .start = 0x0, .pages = 0x10, .kind = .conventional },
        .{ .start = 0x10000, .pages = 0x10, .kind = .conventional },
        .{ .start = 0x20000, .pages = 0x10, .kind = .conventional },
    };
    try std.testing.expectError(error.Capacity, normalize(&descs3, &.{}, &storage));
}

test "memmap: zero-page descriptors skipped" {
    var storage: [4]boot_info.Range = undefined;
    const descs = [_]Desc{
        .{ .start = 0x0, .pages = 0, .kind = .conventional },
        .{ .start = 0x1000, .pages = 1, .kind = .conventional },
    };
    try std.testing.expectEqual(@as(usize, 1), try normalize(&descs, &.{}, &storage));
}

test "memmap: misaligned descriptor rejected" {
    var storage: [4]boot_info.Range = undefined;
    const descs = [_]Desc{.{ .start = 0x1001, .pages = 1, .kind = .conventional }};
    try std.testing.expectError(error.Misaligned, normalize(&descs, &.{}, &storage));
}

test "memmap: misaligned owned span rejected" {
    var storage: [4]boot_info.Range = undefined;
    const descs = [_]Desc{.{ .start = 0x0, .pages = 0x10, .kind = .conventional }};
    const owned = [_]Span{.{ .base = 0x1001, .size = 0x1000, .kind = .kernel }};
    try std.testing.expectError(error.Misaligned, normalize(&descs, &owned, &storage));
}

test "memmap: descriptor address overflow rejected" {
    var storage: [4]boot_info.Range = undefined;
    // pages*4096 == 2^52 * 2^12 == 2^64 wraps u64.
    const wrap_mul = [_]Desc{.{ .start = 0x1000, .pages = 0x10000000000000, .kind = .conventional }};
    try std.testing.expectError(error.AddressOverflow, normalize(&wrap_mul, &.{}, &storage));
    // start+bytes wraps u64.
    const wrap_add = [_]Desc{.{ .start = 0xFFFFFFFFFFFFF000, .pages = 2, .kind = .conventional }};
    try std.testing.expectError(error.AddressOverflow, normalize(&wrap_add, &.{}, &storage));
}

test "memmap: wrapping owned span rejected" {
    var storage: [4]boot_info.Range = undefined;
    const descs = [_]Desc{.{ .start = 0x0, .pages = 0x10, .kind = .conventional }};
    const owned = [_]Span{.{ .base = 0xFFFFFFFFFFFFF000, .size = 0x2000, .kind = .kernel }};
    try std.testing.expectError(error.AddressOverflow, normalize(&descs, &owned, &storage));
}

test "memmap: fragment exhaustion fails closed" {
    var storage: [64]boot_info.Range = undefined;
    const descs = [_]Desc{.{ .start = 0x0, .pages = 0x100, .kind = .conventional }};
    // 16 disjoint owned spans need 1+2*16=33 fragments > 32 scratch.
    var owned: [16]Span = undefined;
    for (&owned, 0..) |*o, i| {
        o.* = .{
            .base = 0x1000 + @as(u64, i) * 0x4000,
            .size = 0x1000,
            .kind = .kernel,
        };
    }
    try std.testing.expectError(error.FragmentCapacity, normalize(&descs, &owned, &storage));
}
