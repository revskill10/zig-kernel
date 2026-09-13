// arch/x86_64/native/pmm — first-slice physical page accounting.
// 256 MiB qualification profile: only conventional pages below MANAGED_TOP
// are published; conventional pages at/above the ceiling are reported as
// unmanaged, every non-conventional page as excluded. Owned ranges
// (kernel/stack/initramfs/boot-info/loader/firmware) are non-conventional
// in a validated BootInfo, so enumeration can never hand them out; freePage
// additionally re-checks the cached map. Fail-closed: any init error leaves
// zero published pages and uninitialized state. MANAGED_TOP must equal
// paging.MAP_TOP (asserted at comptime in src/native/main.zig).
// ponytail: bitmap allocator + per-CPU caches land in KWP3 with real paging;
// ceiling: full MM with COW/demand-fault policy per audits/kernel-distro.md Z3.

const boot_info = @import("boot_info");
const std = @import("std");

pub const PAGE: u64 = 4096;
pub const MANAGED_TOP: u64 = 256 * 1024 * 1024;
pub const MANAGED_PAGES: usize = MANAGED_TOP / PAGE; // 65536

var backing: [MANAGED_PAGES]u64 = undefined;
const BACKING_LIMIT: usize = backing.len;

var free_stack: []u64 = &.{};
var free_count: usize = 0;
var total_pages: u64 = 0;
var used_pages: u64 = 0;
var unmanaged_pages: u64 = 0;
var excluded_pages: u64 = 0;
var initialized: bool = false;
var cached: ?*const boot_info.BootInfo = null;

pub const Stats = struct {
    total: u64,
    free: u64,
    used: u64,
    unmanaged: u64, // conventional pages at/above MANAGED_TOP (clipped, not usable)
    excluded: u64, // non-conventional pages (owned/reserved/firmware, never usable)
};

pub const InitError = error{
    BadBootInfo,
    MisalignedRange,
    RangeOverflow,
    TooManyPages,
};

fn rangeUsable(r: boot_info.Range) bool {
    return r.kind == .conventional and r.page_count > 0;
}

fn reset() void {
    free_stack = &.{};
    free_count = 0;
    total_pages = 0;
    used_pages = 0;
    unmanaged_pages = 0;
    excluded_pages = 0;
    initialized = false;
    cached = null;
}

/// Build the free stack from validated BootInfo ranges, clipped to the
/// mapped domain. Publishes accounting only on full success.
pub fn init(info: *const boot_info.BootInfo) InitError!void {
    reset();
    info.validate() catch return error.BadBootInfo;
    var count: usize = 0;
    var total: u64 = 0;
    var unmanaged: u64 = 0;
    var excluded: u64 = 0;
    for (info.ranges()) |r| {
        if (r.page_count == 0) return error.BadBootInfo;
        if (!rangeUsable(r)) {
            excluded = std.math.add(u64, excluded, r.page_count) catch
                return error.RangeOverflow;
            continue;
        }
        // Allocatable ranges must be page-aligned with checked bounds.
        if (r.phys_start % PAGE != 0) return error.MisalignedRange;
        const bytes = std.math.mul(u64, r.page_count, PAGE) catch
            return error.RangeOverflow;
        const end = std.math.add(u64, r.phys_start, bytes) catch
            return error.RangeOverflow;
        if (r.phys_start >= MANAGED_TOP) {
            unmanaged = std.math.add(u64, unmanaged, r.page_count) catch
                return error.RangeOverflow;
            continue;
        }
        const first_end = @min(end, MANAGED_TOP);
        const managed_n: u64 = (first_end - r.phys_start) / PAGE;
        unmanaged = std.math.add(u64, unmanaged, r.page_count - managed_n) catch
            return error.RangeOverflow;
        var i: u64 = 0;
        while (i < managed_n) : (i += 1) {
            if (count >= BACKING_LIMIT) return error.TooManyPages;
            backing[count] = r.phys_start + i * PAGE;
            count += 1;
        }
        total = std.math.add(u64, total, managed_n) catch
            return error.RangeOverflow;
    }
    free_stack = backing[0..count];
    free_count = count;
    total_pages = total;
    unmanaged_pages = unmanaged;
    excluded_pages = excluded;
    used_pages = 0;
    cached = info;
    initialized = true;
}

pub fn isInitialized() bool {
    return initialized;
}

/// Page-aligned and inside the mapped/managed domain (necessary, not
/// sufficient: the cached map decides ownership).
pub fn inManagedDomain(paddr: u64) bool {
    return paddr % PAGE == 0 and paddr < MANAGED_TOP;
}

/// True when `paddr` is a conventional (allocatable, not owned/reserved)
/// page of the cached map. False before init or for any owned address.
pub fn isAllocatable(paddr: u64) bool {
    if (!inManagedDomain(paddr)) return false;
    const info = cached orelse return false;
    for (info.ranges()) |r| {
        const bytes = std.math.mul(u64, r.page_count, PAGE) catch return false;
        const end = std.math.add(u64, r.phys_start, bytes) catch return false;
        if (paddr >= r.phys_start and paddr < end) return rangeUsable(r);
    }
    return false;
}

pub fn allocPage() ?u64 {
    if (!initialized) return null;
    if (free_count == 0) return null;
    free_count -= 1;
    free_stack = backing[0..free_count];
    used_pages += 1;
    return backing[free_count];
}

/// Return a page. True on acceptance; false (no state change) for
/// uninitialized, unaligned, out-of-domain, owned/reserved/unknown, full, or
/// double (already-free, including never-allocated) pages.
pub fn freePage(paddr: u64) bool {
    if (!initialized) return false;
    if (!isAllocatable(paddr)) return false;
    for (backing[0..free_count]) |q| {
        if (q == paddr) return false;
    }
    if (free_count >= BACKING_LIMIT) return false;
    backing[free_count] = paddr;
    free_count += 1;
    free_stack = backing[0..free_count];
    if (used_pages > 0) used_pages -= 1;
    return true;
}

pub fn stats() Stats {
    return .{
        .total = total_pages,
        .free = free_count,
        .used = used_pages,
        .unmanaged = unmanaged_pages,
        .excluded = excluded_pages,
    };
}
