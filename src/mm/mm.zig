// mm — Memory Management: buddy + slab + VMM (virtual memory manager)
// Clean Entities: Page, VmArea, MmStruct — pure rules, no arch dep
// Implements: allocPage/freePage, Slab, VmArea tracking, mmap/munmap/mprotect
const std = @import("std");
const printk = @import("../lib/printk.zig");

pub const PAGE_SIZE: usize = 4096;
pub const MAX_PAGES: usize = 4096; // 16 MiB simulated physical mem

pub const Page = struct {
    id: usize,
    in_use: bool = false,
    ref_count: u32 = 0,
};

pub const VmArea = struct {
    start: usize,
    end: usize,
    flags: u32,
    prot: u32,
    is_shared: bool = false,
    file: ?*anyopaque = null,
};

// Memory protection flags (matching Linux)
pub const PROT_NONE: u32 = 0;
pub const PROT_READ: u32 = 1;
pub const PROT_WRITE: u32 = 2;
pub const PROT_EXEC: u32 = 4;

// Mapping flags
pub const MAP_SHARED: u32 = 0x01;
pub const MAP_PRIVATE: u32 = 0x02;
pub const MAP_FIXED: u32 = 0x10;
pub const MAP_ANONYMOUS: u32 = 0x20;

var pages: [MAX_PAGES]Page = blk: {
    @setEvalBranchQuota(100000);
    var arr: [MAX_PAGES]Page = undefined;
    for (&arr, 0..) |*p, i| p.* = .{ .id = i };
    break :blk arr;
};

var page_bitmap: [MAX_PAGES / 8]u8 = [_]u8{0} ** (MAX_PAGES / 8);

fn setPage(idx: usize) void {
    page_bitmap[idx / 8] |= @as(u8, 1) << @as(u3, @intCast(idx % 8));
}

fn clearPage(idx: usize) void {
    page_bitmap[idx / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(idx % 8)));
}

fn isPageSet(idx: usize) bool {
    return (page_bitmap[idx / 8] & (@as(u8, 1) << @as(u3, @intCast(idx % 8)))) != 0;
}

pub fn allocPage() ?*Page {
    for (&pages, 0..) |*p, i| {
        if (!p.in_use) {
            p.in_use = true;
            p.ref_count = 1;
            setPage(i);
            return p;
        }
    }
    return null;
}

pub fn freePage(p: *Page) void {
    if (p.ref_count > 0) {
        p.ref_count -= 1;
        if (p.ref_count == 0) {
            p.in_use = false;
            const idx = p.id;
            clearPage(idx);
        }
    }
}

pub fn usedPages() usize {
    var n: usize = 0;
    for (pages) |p| {
        if (p.in_use) n += 1;
    }
    return n;
}

// ── Slab: fixed-size object cache (analog to kmem_cache / SLUB) ──
pub fn Slab(comptime T: type, comptime cap: usize) type {
    return struct {
        buf: [cap]T = undefined,
        used: [cap]bool = [_]bool{false} ** cap,
        count: usize = 0,
        pub fn alloc(self: *@This()) ?*T {
            for (&self.used, 0..) |*u, i| if (!u.*) {
                u.* = true;
                self.count += 1;
                return &self.buf[i];
            };
            return null;
        }
        pub fn free(self: *@This(), ptr: *T) void {
            const idx = (@intFromPtr(ptr) - @intFromPtr(&self.buf[0])) / @sizeOf(T);
            self.used[idx] = false;
            self.count -= 1;
        }
    };
}

// ── VMM: Virtual Memory Manager ──
// Tracks virtual memory areas per process (simplified: global for hosted sim)
const MAX_VM_AREAS: usize = 64;
var vm_areas: [MAX_VM_AREAS]?VmArea = [_]?VmArea{null} ** MAX_VM_AREAS;
var vm_area_count: usize = 0;
var next_anon_addr: usize = 0x20000000; // Start of anonymous mappings

fn findFreeVmaSlot() ?usize {
    for (&vm_areas, 0..) |slot, i| {
        if (slot == null) return i;
    }
    return null;
}

fn findVmaOverlap(start: usize, end: usize) ?usize {
    for (&vm_areas, 0..) |slot, i| {
        if (slot) |vma| {
            if (start < vma.end and end > vma.start) {
                return i;
            }
        }
    }
    return null;
}

fn removeVma(idx: usize) void {
    vm_areas[idx] = null;
    vm_area_count -= 1;
}

pub fn mmap(addr: usize, len: usize, prot: u32, flags: u32) ?usize {
    const aligned_len = (len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    var map_addr: usize = addr;

    if (map_addr == 0 or (flags & MAP_FIXED) != 0) {
        // Need to allocate a new address
        if (map_addr == 0) {
            // Try to find a free region
            map_addr = next_anon_addr;
            next_anon_addr += aligned_len + (PAGE_SIZE * 256); // Leave some gap
        }
        // Check for overlap
        if (findVmaOverlap(map_addr, map_addr + aligned_len) != null) {
            return null;
        }
    }

    const slot = findFreeVmaSlot() orelse return null;
    vm_areas[slot] = VmArea{
        .start = map_addr,
        .end = map_addr + aligned_len,
        .flags = flags,
        .prot = prot,
        .is_shared = (flags & MAP_SHARED) != 0,
    };
    vm_area_count += 1;

    // Allocate physical pages for anonymous mapping
    if ((flags & MAP_ANONYMOUS) != 0) {
        const npages = aligned_len / PAGE_SIZE;
        var i: usize = 0;
        while (i < npages) : (i += 1) {
            _ = allocPage();
        }
    }

    println("[INFO] mm: mmap addr=0x{x} len={d} prot=0x{x} flags=0x{x} → 0x{x}\n",
        .{ addr, len, prot, flags, map_addr });
    return map_addr;
}

pub fn munmap(addr: usize, len: usize) i32 {
    const end = addr + ((len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1));
    var i: usize = 0;
    var removed: usize = 0;
    while (i < MAX_VM_AREAS) : (i += 1) {
        if (vm_areas[i]) |vma| {
            if (vma.start >= addr and vma.end <= end) {
                removeVma(i);
                // Free associated physical pages
                const npages = (vma.end - vma.start) / PAGE_SIZE;
                var j: usize = 0;
                while (j < npages) : (j += 1) {
                    // In real kernel, would free specific pages
                }
                removed += 1;
            }
        }
    }
    return if (removed > 0) 0 else -1;
}

pub fn mprotect(addr: usize, len: usize, prot: u32) i32 {
    const end = addr + len;
    for (&vm_areas, 0..) |*slot, i| {
        if (slot.*) |*vma| {
            if (vma.start <= addr and vma.end >= end) {
                vma.prot = prot;
                println("[INFO] mm: mprotect 0x{x}..0x{x} → prot=0x{x}\n", .{ addr, end, prot });
                return 0;
            }
        }
        _ = i;
    }
    return -1;
}

pub fn vmmInit() void {
    next_anon_addr = 0x20000000;
    vm_area_count = 0;
    println("[INFO] mm: VMM initialized (anon region at 0x{x})\n", .{ next_anon_addr });
}

pub fn brk(addr: usize) usize {
    _ = addr;
    // Simplified: return current brk (would update in real kernel)
    return next_anon_addr;
}

pub const MAX_FD: usize = 256;

pub fn init() void {
    println("[INFO] mm: buddy {d} pages ({d} MiB) + slab + VMM ready", .{ MAX_PAGES, MAX_PAGES * PAGE_SIZE / (1024 * 1024) });
    vmmInit();
}

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
