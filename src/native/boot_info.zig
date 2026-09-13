// src/native/boot_info — versioned, fixed-layout EFI→native handoff contract.
// Frozen by KWP1; any change bumps VERSION and re-qualifies KWP2 gates.
// All addresses are physical, units bytes unless noted. The loader fills the
// header plus a normalized range array copied from the final EFI memory map;
// after ExitBootServices the kernel must not dereference any EFI-owned pointer
// other than ranges recorded here (loader pages, kernel, initramfs, stack and
// this structure are explicitly reserved below).
//
// Layout: header (256 bytes) immediately followed by `range_count` Range
// entries, all inside loader-owned pages of `total_size` bytes.

pub const MAGIC: u64 = 0x3130_544f_4f42_4b5a; // "ZKBOOT01" little-endian
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: u32 = 256;
pub const MAX_RANGES: u32 = 512;
pub const ALIGN: u64 = 4096;

pub const RangeKind = enum(u32) {
    conventional = 0, // free RAM the kernel allocator may claim
    reserved = 1, // firmware/reserved; never touch
    kernel = 2, // loaded kernel payload image
    initramfs = 3, // initramfs blob
    kernel_stack = 4, // owned native kernel stack
    boot_info = 5, // this structure + range array
    loader = 6, // EFI loader image/allocations kept alive for the map
    acpi_reclaim = 7,
    nvs = 8,
    mmio = 9,
    _,
};

pub const Range = extern struct {
    phys_start: u64,
    page_count: u64, // 4096-byte pages
    kind: RangeKind,
    _pad: u32,

    pub fn endAddr(self: Range) u64 {
        return self.phys_start + self.page_count * 4096;
    }
};

pub const BootInfo = extern struct {
    magic: u64 = MAGIC,
    version: u32 = VERSION,
    header_size: u32 = HEADER_SIZE,
    total_size: u32, // header + range array, page multiple
    flags: u32 = 0,

    range_count: u64, // normalized ranges following the header
    efi_desc_size: u32, // provenance: stride of the source EFI map
    efi_desc_version: u32, // provenance: EFI memory descriptor version

    kernel_base: u64, // physical base of the loaded payload
    kernel_size: u64,
    kernel_entry: u64, // ELF e_entry (physical, identity-mapped at handoff)
    initramfs_base: u64,
    initramfs_size: u64,
    stack_base: u64, // low address of owned kernel stack
    stack_size: u64,

    checksum: u64 = 0, // additive sum of all u64 words before this field
    _reserved: [19]u64 = [_]u64{0} ** 19,

    pub fn ranges(self: *const BootInfo) []const Range {
        const base: [*]const Range = @ptrFromInt(@intFromPtr(self) + HEADER_SIZE);
        return base[0..self.range_count];
    }

    pub fn rangesMut(self: *BootInfo) []Range {
        const base: [*]Range = @ptrFromInt(@intFromPtr(self) + HEADER_SIZE);
        return base[0..self.range_count];
    }

    /// Full writable capacity for loader construction, derived from
    /// `total_size` (N1: capacity is separate from the populated count; the
    /// count is published only after conversion succeeds).
    pub fn rangesStorage(self: *BootInfo) []Range {
        const cap = (self.total_size - HEADER_SIZE) / @sizeOf(Range);
        const base: [*]Range = @ptrFromInt(@intFromPtr(self) + HEADER_SIZE);
        return base[0..cap];
    }

    pub fn computeChecksum(self: *const BootInfo) u64 {
        const words: [*]const u64 = @ptrCast(self);
        const n = (@offsetOf(BootInfo, "checksum")) / 8;
        var sum: u64 = 0;
        for (words[0..n]) |w| sum +%= w;
        return sum;
    }

    pub fn stackTop(self: *const BootInfo) u64 {
        return self.stack_base + self.stack_size;
    }

    /// Full structural validation; every check is independently grounded in
    /// the contract above. Returns a named failure for diagnostics.
    pub fn validate(self: *const BootInfo) ValidateError!void {
        if (self.magic != MAGIC) return error.BadMagic;
        if (self.version != VERSION) return error.BadVersion;
        if (self.header_size != HEADER_SIZE) return error.BadHeaderSize;
        if (self.total_size < HEADER_SIZE) return error.BadTotalSize;
        if (self.total_size % ALIGN != 0) return error.MisalignedTotalSize;
        if (self.range_count > MAX_RANGES) return error.TooManyRanges;
        const need: u64 = HEADER_SIZE + self.range_count * @sizeOf(Range);
        if (need > self.total_size) return error.RangesOverflow;
        if (self.checksum != self.computeChecksum()) return error.BadChecksum;
        if (self.kernel_entry < self.kernel_base or
            self.kernel_entry >= self.kernel_base + self.kernel_size)
            return error.EntryOutOfRange;
        if (self.stack_size == 0 or self.stack_size % ALIGN != 0)
            return error.BadStack;
        if (self.kernel_base % ALIGN != 0 or self.initramfs_base % ALIGN != 0)
            return error.MisalignedRegion;
        // Mandatory regions must appear as ranges and must not overlap.
        if (!self.covered(self.kernel_base, self.kernel_size, .kernel))
            return error.KernelNotCovered;
        if (self.initramfs_size != 0 and
            !self.covered(self.initramfs_base, self.initramfs_size, .initramfs))
            return error.InitramfsNotCovered;
        if (!self.covered(self.stack_base, self.stack_size, .kernel_stack))
            return error.StackNotCovered;
        if (!self.covered(@intFromPtr(self), self.total_size, .boot_info))
            return error.BootInfoNotCovered;
        if (rangesOverlap(self.ranges())) return error.OverlappingRanges;
    }

    /// True when `kind` ranges cover `[base, base+size)` without a gap.
    /// Adjacent same-kind fragments (firmware descriptor splits) accumulate;
    /// a hole, a kind mismatch, or an arithmetic wrap fails closed.
    fn covered(self: *const BootInfo, base: u64, size: u64, kind: RangeKind) bool {
        if (size == 0) return false;
        const end = base +% size;
        if (end < base) return false;
        var cursor = base;
        while (cursor < end) {
            var advanced = false;
            for (self.ranges()) |r| {
                if (r.kind != kind or r.page_count == 0) continue;
                const r_end = r.endAddr();
                if (r.phys_start <= cursor and r_end > cursor) {
                    cursor = r_end;
                    advanced = true;
                    break;
                }
            }
            if (!advanced) return false;
        }
        return true;
    }

    pub const ValidateError = error{
        BadMagic,
        BadVersion,
        BadHeaderSize,
        BadTotalSize,
        MisalignedTotalSize,
        TooManyRanges,
        RangesOverflow,
        BadChecksum,
        EntryOutOfRange,
        BadStack,
        MisalignedRegion,
        KernelNotCovered,
        InitramfsNotCovered,
        StackNotCovered,
        BootInfoNotCovered,
        OverlappingRanges,
    };
};

/// Adjacent ranges of the same kind may touch; distinct ranges may not overlap.
pub fn rangesOverlap(rs: []const Range) bool {
    for (rs, 0..) |a, i| {
        if (a.page_count == 0) return true; // zero-length range is malformed
        for (rs[i + 1 ..]) |b| {
            if (b.page_count == 0) return true;
            const a_end = a.endAddr();
            const b_end = b.endAddr();
            if (a.phys_start < b_end and b.phys_start < a_end) return true;
        }
    }
    return false;
}

comptime {
    if (@sizeOf(BootInfo) != HEADER_SIZE) @compileError("BootInfo header drift");
    if (@sizeOf(Range) != 24) @compileError("Range layout drift");
}

const std = @import("std");

/// Fully deterministic fixture: entire storage zeroed first, header written
/// before any range slice is derived (N5).
fn fixture(buf: *[4096]u8) *BootInfo {
    @memset(buf, 0);
    // N5: every caller passes an align(4096) stack buffer, so the alignment
    // assertion holds; the unaligned *[4096]u8 parameter type just cannot
    // prove it without an explicit alignCast.
    const info: *BootInfo = @ptrCast(@alignCast(buf));
    info.* = .{
        .total_size = 4096,
        .range_count = 5,
        .efi_desc_size = 48,
        .efi_desc_version = 1,
        .kernel_base = 0x200000,
        .kernel_size = 0x40000,
        .kernel_entry = 0x200100,
        .initramfs_base = 0x400000,
        .initramfs_size = 0x2000,
        .stack_base = 0x500000,
        .stack_size = 0x10000,
    };
    const ranges = info.rangesMut();
    ranges[0] = .{ .phys_start = 0x200000, .page_count = 0x40, .kind = .kernel, ._pad = 0 };
    ranges[1] = .{ .phys_start = 0x400000, .page_count = 0x2, .kind = .initramfs, ._pad = 0 };
    ranges[2] = .{ .phys_start = 0x500000, .page_count = 0x10, .kind = .kernel_stack, ._pad = 0 };
    const self_page = @intFromPtr(info) & ~@as(u64, 4095);
    ranges[3] = .{ .phys_start = self_page, .page_count = 1, .kind = .boot_info, ._pad = 0 };
    ranges[4] = .{ .phys_start = 0x600000, .page_count = 0x100, .kind = .conventional, ._pad = 0 };
    info.checksum = info.computeChecksum();
    return info;
}

test "boot_info: valid fixture passes" {
    var buf: [4096]u8 align(4096) = undefined;
    const info = fixture(&buf);
    try info.validate();
    try std.testing.expectEqual(@as(u64, 5), info.range_count);
    try std.testing.expectEqual(@as(usize, (4096 - HEADER_SIZE) / @sizeOf(Range)), info.rangesStorage().len);
}

test "boot_info: magic/version/checksum rejection" {
    var buf: [4096]u8 align(4096) = undefined;
    var info = fixture(&buf);
    info.magic = 0;
    try std.testing.expectError(error.BadMagic, info.validate());
    info = fixture(&buf);
    info.version = 99;
    try std.testing.expectError(error.BadVersion, info.validate());
    info = fixture(&buf);
    info.kernel_size += 8; // checksum now stale
    try std.testing.expectError(error.BadChecksum, info.validate());
}

test "boot_info: entry outside kernel image rejected" {
    var buf: [4096]u8 align(4096) = undefined;
    const info = fixture(&buf);
    info.kernel_entry = 0x200000 - 8;
    info.checksum = info.computeChecksum();
    try std.testing.expectError(error.EntryOutOfRange, info.validate());
}

test "boot_info: overlapping reserved ranges rejected" {
    var buf: [4096]u8 align(4096) = undefined;
    const info = fixture(&buf);
    // Shove the conventional range into the kernel image.
    info.rangesMut()[4].phys_start = 0x200000 + 0x1000;
    info.checksum = info.computeChecksum();
    try std.testing.expectError(error.OverlappingRanges, info.validate());
}

test "boot_info: missing stack coverage rejected" {
    var buf: [4096]u8 align(4096) = undefined;
    const info = fixture(&buf);
    info.rangesMut()[2].kind = .conventional;
    info.checksum = info.computeChecksum();
    try std.testing.expectError(error.StackNotCovered, info.validate());
}

test "boot_info: truncated range array rejected" {
    var buf: [4096]u8 align(4096) = undefined;
    const info = fixture(&buf);
    info.range_count = 300; // 256 + 300*24 > 4096
    info.checksum = info.computeChecksum();
    try std.testing.expectError(error.RangesOverflow, info.validate());
}

test "boot_info: adjacent kernel fragments covering a split owned span validate" {
    // B2: firmware split at 0x201000, owned kernel [0x200000, 0x202000).
    // Neither fragment alone contains the span; accumulation must succeed.
    var buf: [4096]u8 align(4096) = undefined;
    @memset(&buf, 0);
    const info: *BootInfo = @ptrCast(@alignCast(&buf));
    info.* = .{
        .total_size = 4096,
        .range_count = 5,
        .efi_desc_size = 48,
        .efi_desc_version = 1,
        .kernel_base = 0x200000,
        .kernel_size = 0x2000,
        .kernel_entry = 0x200000,
        .initramfs_base = 0x400000,
        .initramfs_size = 0x1000,
        .stack_base = 0x500000,
        .stack_size = 0x1000,
    };
    const ranges = info.rangesMut();
    ranges[0] = .{ .phys_start = 0x200000, .page_count = 1, .kind = .kernel, ._pad = 0 };
    ranges[1] = .{ .phys_start = 0x201000, .page_count = 1, .kind = .kernel, ._pad = 0 };
    ranges[2] = .{ .phys_start = 0x400000, .page_count = 1, .kind = .initramfs, ._pad = 0 };
    ranges[3] = .{ .phys_start = 0x500000, .page_count = 1, .kind = .kernel_stack, ._pad = 0 };
    const self_page = @intFromPtr(info) & ~@as(u64, 4095);
    ranges[4] = .{ .phys_start = self_page, .page_count = 1, .kind = .boot_info, ._pad = 0 };
    info.checksum = info.computeChecksum();
    try std.testing.expect(!rangesOverlap(info.ranges()));
    try info.validate();
}

test "boot_info: gapped kernel fragments fail coverage" {
    var buf: [4096]u8 align(4096) = undefined;
    @memset(&buf, 0);
    const info: *BootInfo = @ptrCast(@alignCast(&buf));
    info.* = .{
        .total_size = 4096,
        .range_count = 5,
        .efi_desc_size = 48,
        .efi_desc_version = 1,
        .kernel_base = 0x200000,
        .kernel_size = 0x2000,
        .kernel_entry = 0x200000,
        .initramfs_base = 0x400000,
        .initramfs_size = 0x1000,
        .stack_base = 0x500000,
        .stack_size = 0x1000,
    };
    const ranges = info.rangesMut();
    ranges[0] = .{ .phys_start = 0x200000, .page_count = 1, .kind = .kernel, ._pad = 0 };
    ranges[1] = .{ .phys_start = 0x202000, .page_count = 1, .kind = .kernel, ._pad = 0 };
    ranges[2] = .{ .phys_start = 0x400000, .page_count = 1, .kind = .initramfs, ._pad = 0 };
    ranges[3] = .{ .phys_start = 0x500000, .page_count = 1, .kind = .kernel_stack, ._pad = 0 };
    const self_page = @intFromPtr(info) & ~@as(u64, 4095);
    ranges[4] = .{ .phys_start = self_page, .page_count = 1, .kind = .boot_info, ._pad = 0 };
    info.checksum = info.computeChecksum();
    try std.testing.expectError(error.KernelNotCovered, info.validate());
}
