// boot/uefi/elf64 — validated ELF64 x86-64 payload loader for the EFI stub.
// Pure logic, no EFI/host imports: the same code is exercised by hosted
// negative fixtures (tests/native-boot) and runs inside the loader.
//
// Two phases: plan() validates the image and computes a segment/span plan
// against a required physical load base; execute() copies file bytes and
// zeroes BSS into identity-mapped destination memory. Nothing here trusts the
// file: bounds, overflow, alignment congruence, overlap, entry containment
// and segment flags are all checked before a single byte is copied.

pub const MAX_PHDRS: u32 = 64;

/// The kernel payload must stay inside the first 2 MiB block above the load
/// base: the native page tables split that block into 4 KiB leaves and the
/// identity-mapped ET_EXEC contract places vaddr == paddr.
pub const MAX_KERNEL_SPAN: u64 = 0x200000;

pub const Ehdr = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

pub const Phdr = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    @"align": u64,
};

pub const PT_LOAD: u32 = 1;
pub const PF_X: u32 = 1;
pub const PF_W: u32 = 2;
pub const PF_R: u32 = 4;

const ET_EXEC: u16 = 2;
const EM_X86_64: u16 = 62;

pub const Error = error{
    Truncated,
    BadMagic,
    BadClass,
    BadEndian,
    BadVersion,
    BadType,
    BadMachine,
    BadHeaderSize,
    BadPhdrSize,
    TooManyPhdrs,
    PhdrTableOutOfBounds,
    NoLoadSegments,
    SegmentFileOverflow,
    SegmentMemUnderflow,
    SegmentAddressOverflow,
    SegmentAlignCongruence,
    SegmentOverlap,
    IdentityMismatch,
    BaseMismatch,
    EntryOutOfRange,
    EntryNotFileBacked,
    SpanTooLarge,
};

pub const Segment = struct {
    paddr: u64, // destination physical address
    file_off: u64,
    filesz: u64,
    memsz: u64,
    end: u64, // checked paddr + memsz
    flags: u32,
};

pub const Plan = struct {
    entry: u64,
    base: u64, // lowest PT_LOAD paddr (== required base)
    end: u64, // one past the highest PT_LOAD byte (memsz)
    span: u64, // end - base
    segments: [MAX_PHDRS]Segment,
    segment_count: u32,

    pub fn segSlice(self: *const Plan) []const Segment {
        return self.segments[0..self.segment_count];
    }
};

fn readInt(comptime T: type, bytes: []const u8, off: u64) Error!T {
    if (off + @sizeOf(T) > bytes.len) return error.Truncated;
    return std.mem.bytesToValue(T, bytes[off..][0..@sizeOf(T)]);
}

/// Validate `bytes` as an ET_EXEC x86-64 payload that must land at physical
/// `required_base` (page-aligned). On success returns the copy/zero plan.
pub fn plan(bytes: []const u8, required_base: u64) Error!Plan {
    if (bytes.len < @sizeOf(Ehdr)) return error.Truncated;
    const eh: Ehdr = readInt(Ehdr, bytes, 0) catch return error.Truncated;
    if (!std.mem.eql(u8, eh.ident[0..4], "\x7fELF")) return error.BadMagic;
    if (eh.ident[4] != 2) return error.BadClass; // ELFCLASS64
    if (eh.ident[5] != 1) return error.BadEndian; // little-endian
    if (eh.ident[6] != 1 or eh.version != 1) return error.BadVersion;
    if (eh.type != ET_EXEC) return error.BadType;
    if (eh.machine != EM_X86_64) return error.BadMachine;
    if (eh.ehsize < @sizeOf(Ehdr)) return error.BadHeaderSize;
    if (eh.phentsize < @sizeOf(Phdr)) return error.BadPhdrSize;
    if (eh.phnum == 0) return error.NoLoadSegments;
    if (eh.phnum > MAX_PHDRS) return error.TooManyPhdrs;
    const ph_end = std.math.add(u64, eh.phoff,
        std.math.mul(u64, eh.phentsize, eh.phnum) catch return error.PhdrTableOutOfBounds,
    ) catch return error.PhdrTableOutOfBounds;
    if (ph_end > bytes.len) return error.PhdrTableOutOfBounds;

    var result: Plan = .{
        .entry = eh.entry,
        .base = 0,
        .end = 0,
        .span = 0,
        .segments = undefined,
        .segment_count = 0,
    };
    var count: u32 = 0;
    var lowest: u64 = std.math.maxInt(u64);
    var highest: u64 = 0;
    var i: u16 = 0;
    while (i < eh.phnum) : (i += 1) {
        const ph: Phdr = readInt(Phdr, bytes, eh.phoff + @as(u64, i) * eh.phentsize) catch
            return error.PhdrTableOutOfBounds;
        if (ph.type != PT_LOAD) continue;
        // Validate every PT_LOAD header before it is skipped or copied: a
        // non-identity or file-heavy zero-size segment is still a contract
        // violation, not a silent no-op.
        if (ph.filesz > ph.memsz) return error.SegmentMemUnderflow;
        if (ph.vaddr != ph.paddr) return error.IdentityMismatch;
        if (ph.memsz == 0) {
            // Genuinely empty load: still must declare a valid alignment.
            if (ph.@"align" > 1) {
                if (!std.math.isPowerOfTwo(ph.@"align")) return error.SegmentAlignCongruence;
                if (ph.paddr % ph.@"align" != ph.offset % ph.@"align")
                    return error.SegmentAlignCongruence;
            }
            continue;
        }
        const file_end = std.math.add(u64, ph.offset, ph.filesz) catch
            return error.SegmentFileOverflow;
        if (file_end > bytes.len) return error.SegmentFileOverflow;
        const seg_end = std.math.add(u64, ph.paddr, ph.memsz) catch
            return error.SegmentAddressOverflow;
        if (ph.@"align" > 1) {
            if (!std.math.isPowerOfTwo(ph.@"align")) return error.SegmentAlignCongruence;
            if (ph.paddr % ph.@"align" != ph.offset % ph.@"align")
                return error.SegmentAlignCongruence;
        }
        result.segments[count] = .{
            .paddr = ph.paddr,
            .file_off = ph.offset,
            .filesz = ph.filesz,
            .memsz = ph.memsz,
            .end = seg_end,
            .flags = ph.flags,
        };
        count += 1;
        lowest = @min(lowest, ph.paddr);
        highest = @max(highest, seg_end);
    }
    if (count == 0) return error.NoLoadSegments;
    if (lowest != required_base) return error.BaseMismatch;
    if (required_base % 4096 != 0) return error.BaseMismatch;

    // Overlap: every PT_LOAD pair must be disjoint (adjacency allowed).
    for (result.segments[0..count], 0..) |a, ai| {
        for (result.segments[ai + 1 .. count]) |b| {
            if (a.paddr < b.end and b.paddr < a.end) return error.SegmentOverlap;
        }
    }

    // Entry must lie in the file-backed region of an executable PT_LOAD segment
    // (not in its zero-filled BSS tail) and inside the 2 MiB window.
    var entry_ok = false;
    for (result.segments[0..count]) |s| {
        if ((s.flags & PF_X) != 0) {
            const file_end = std.math.add(u64, s.paddr, s.filesz) catch 0;
            if (eh.entry >= s.paddr and eh.entry < file_end) entry_ok = true;
        }
    }
    if (!entry_ok) return error.EntryNotFileBacked;

    result.base = lowest;
    result.end = highest;
    result.span = highest - lowest;
    result.segment_count = count;

    // The whole image must fit inside the 2 MiB identity window above base.
    // Use a single checked window end so a near-max base maps to a typed error
    // instead of an overflow panic.
    const window_end = std.math.add(u64, result.base, MAX_KERNEL_SPAN) catch
        return error.SpanTooLarge;
    if (result.span > MAX_KERNEL_SPAN) return error.SpanTooLarge;
    if (eh.entry < result.base or eh.entry >= window_end)
        return error.EntryOutOfRange;

    return result;
}

/// Copy file bytes and zero BSS. `dest` covers [p.base, p.end) and indexes by
/// physical address minus base. Only callable after plan() succeeded.
pub fn execute(p: *const Plan, bytes: []const u8, dest: []u8) void {
    for (p.segSlice()) |s| {
        const off: usize = @intCast(s.paddr - p.base);
        const fsz: usize = @intCast(s.filesz);
        const msz: usize = @intCast(s.memsz);
        const foff: usize = @intCast(s.file_off);
        @memcpy(dest[off .. off + fsz], bytes[foff .. foff + fsz]);
        @memset(dest[off + fsz .. off + msz], 0);
    }
}

const std = @import("std");

comptime {
    if (@sizeOf(Ehdr) != 64) @compileError("Ehdr layout drift");
    if (@sizeOf(Phdr) != 56) @compileError("Phdr layout drift");
}

// ---- hosted contract fixtures (also driven from tests/native-boot) ----

pub const FixtureBuilder = struct {
    buf: std.ArrayList(u8),

    pub fn init() FixtureBuilder {
        return .{ .buf = .empty };
    }

    pub fn deinit(self: *FixtureBuilder, a: std.mem.Allocator) void {
        self.buf.deinit(a);
    }

    /// Minimal two-segment payload: RX text at base, RW data+BSS above.
    pub fn minimal(self: *FixtureBuilder, a: std.mem.Allocator, base: u64) ![]u8 {
        const text_off: u64 = 0x100;
        const data_off: u64 = 0x200;
        try self.buf.resize(a, 0x300);
        @memset(self.buf.items, 0);
        var eh: Ehdr = std.mem.zeroes(Ehdr);
        @memcpy(eh.ident[0..4], "\x7fELF");
        eh.ident[4] = 2;
        eh.ident[5] = 1;
        eh.ident[6] = 1;
        eh.type = ET_EXEC;
        eh.machine = EM_X86_64;
        eh.version = 1;
        eh.entry = base + 0x10;
        eh.phoff = @sizeOf(Ehdr);
        eh.ehsize = @sizeOf(Ehdr);
        eh.phentsize = @sizeOf(Phdr);
        eh.phnum = 2;
        self.poke(Ehdr, 0, eh);
        self.poke(Phdr, @sizeOf(Ehdr), .{
            .type = PT_LOAD, .flags = PF_R | PF_X, .offset = text_off,
            .vaddr = base, .paddr = base, .filesz = 0x40, .memsz = 0x40,
            .@"align" = 0x100,
        });
        self.poke(Phdr, @sizeOf(Ehdr) + @sizeOf(Phdr), .{
            .type = PT_LOAD, .flags = PF_R | PF_W, .offset = data_off,
            .vaddr = base + 0x1000, .paddr = base + 0x1000, .filesz = 0x20,
            .memsz = 0x80, .@"align" = 0x100,
        });
        for (0..0x40) |i| self.buf.items[text_off + i] = @intCast(0x90 +% i);
        for (0..0x20) |i| self.buf.items[data_off + i] = @intCast(i);
        return self.buf.items;
    }

    pub fn poke(self: *FixtureBuilder, comptime T: type, off: u64, v: T) void {
        const b = std.mem.toBytes(v);
        @memcpy(self.buf.items[off..][0..b.len], &b);
    }
};

test "elf64: minimal fixture plans and executes" {
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const bytes = try fb.minimal(a, 0x200000);
    const p = try plan(bytes, 0x200000);
    try std.testing.expectEqual(@as(u64, 0x200010), p.entry);
    try std.testing.expectEqual(@as(u32, 2), p.segment_count);
    try std.testing.expectEqual(@as(u64, 0x1080), p.span);
    var dest: [0x1080]u8 = undefined;
    @memset(&dest, 0xAA);
    execute(&p, bytes, &dest);
    try std.testing.expectEqual(@as(u8, 0x90), dest[0]);
    try std.testing.expectEqual(@as(u8, 0x90 + 63), dest[63]);
    try std.testing.expectEqual(@as(u8, 0), dest[0x1000]);
    try std.testing.expectEqual(@as(u8, 31), dest[0x1000 + 31]);
    try std.testing.expectEqual(@as(u8, 0), dest[0x1000 + 32]); // BSS zeroed
    try std.testing.expectEqual(@as(u8, 0), dest[0x107F]);
}

test "elf64: rejection matrix" {
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);

    // Truncated image.
    try std.testing.expectError(error.Truncated, plan(good[0..32], 0x200000));
    // Bad magic.
    fb.poke(u8, 0, 0);
    try std.testing.expectError(error.BadMagic, plan(good, 0x200000));
    fb.poke(u8, 0, 0x7F);
    // 32-bit class.
    fb.poke(u8, 4, 1);
    try std.testing.expectError(error.BadClass, plan(good, 0x200000));
    fb.poke(u8, 4, 2);
    // Big-endian.
    fb.poke(u8, 5, 2);
    try std.testing.expectError(error.BadEndian, plan(good, 0x200000));
    fb.poke(u8, 5, 1);
    // Wrong machine (aarch64).
    fb.poke(u16, 18, 183);
    try std.testing.expectError(error.BadMachine, plan(good, 0x200000));
    fb.poke(u16, 18, 62);
    // ET_DYN rejected.
    fb.poke(u16, 16, 3);
    try std.testing.expectError(error.BadType, plan(good, 0x200000));
    fb.poke(u16, 16, 2);
    // Wrong required base.
    try std.testing.expectError(error.BaseMismatch, plan(good, 0x300000));
    // Entry outside executable/file-backed segment.
    fb.poke(u64, 24, 0x200000 + 0x1000); // entry into RW segment
    try std.testing.expectError(error.EntryNotFileBacked, plan(good, 0x200000));
    fb.poke(u64, 24, 0x200010);
    // Segment filesz > memsz.
    fb.poke(u64, @sizeOf(Ehdr) + 32, 0x40); // filesz
    fb.poke(u64, @sizeOf(Ehdr) + 40, 0x20); // memsz
    try std.testing.expectError(error.SegmentMemUnderflow, plan(good, 0x200000));
    fb.poke(u64, @sizeOf(Ehdr) + 32, 0x40);
    fb.poke(u64, @sizeOf(Ehdr) + 40, 0x40);
    // Segment file bytes past EOF: filesz <= memsz but offset+filesz > len.
    fb.poke(u64, @sizeOf(Ehdr) + 32, 0x1000); // filesz
    fb.poke(u64, @sizeOf(Ehdr) + 40, 0x1000); // memsz (kept >= filesz so the
    // file-bounds check, not SegmentMemUnderflow, is what rejects this)
    try std.testing.expectError(error.SegmentFileOverflow, plan(good, 0x200000));
    fb.poke(u64, @sizeOf(Ehdr) + 32, 0x40);
    fb.poke(u64, @sizeOf(Ehdr) + 40, 0x40);
}

test "elf64: overlapping segments rejected" {
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);
    // Move data segment down into the text segment (align 0x10 keeps the
    // paddr/offset congruence valid so the overlap check is what fires).
    fb.poke(u64, @sizeOf(Ehdr) + @sizeOf(Phdr) + 16, 0x200010); // vaddr
    fb.poke(u64, @sizeOf(Ehdr) + @sizeOf(Phdr) + 24, 0x200010); // paddr
    fb.poke(u64, @sizeOf(Ehdr) + @sizeOf(Phdr) + 48, 0x10); // align
    try std.testing.expectError(error.SegmentOverlap, plan(good, 0x200000));
}

test "elf64: phdr table out of bounds rejected" {
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);
    fb.poke(u16, 56, 500); // phnum beyond EOF and MAX_PHDRS
    try std.testing.expectError(error.TooManyPhdrs, plan(good, 0x200000));
    fb.poke(u16, 56, 3);
    fb.poke(u64, 32, 0xFFFF00); // phoff near EOF
    try std.testing.expectError(error.PhdrTableOutOfBounds, plan(good, 0x200000));
}

// Phdr field byte offsets within the first (text) program header.
const ph0_vaddr: u64 = @sizeOf(Ehdr) + 16;
const ph0_paddr: u64 = @sizeOf(Ehdr) + 24;
const ph0_filesz: u64 = @sizeOf(Ehdr) + 32;
const ph0_memsz: u64 = @sizeOf(Ehdr) + 40;
// Second (data) program header field offsets.
const ph1_vaddr: u64 = @sizeOf(Ehdr) + @sizeOf(Phdr) + 16;
const ph1_paddr: u64 = @sizeOf(Ehdr) + @sizeOf(Phdr) + 24;
const ph1_filesz: u64 = @sizeOf(Ehdr) + @sizeOf(Phdr) + 32;
const ph1_memsz: u64 = @sizeOf(Ehdr) + @sizeOf(Phdr) + 40;

test "elf64: non-identity vaddr!=paddr rejected" {
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);
    fb.poke(u64, ph0_vaddr, 0x200000 + 0x1000); // vaddr drifts from paddr
    try std.testing.expectError(error.IdentityMismatch, plan(good, 0x200000));
}

test "elf64: exact 2MiB span accepted" {
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);
    fb.poke(u64, ph1_filesz, 0);
    fb.poke(u64, ph1_memsz, 0); // drop data segment
    fb.poke(u64, ph0_filesz, 0x40);
    fb.poke(u64, ph0_memsz, MAX_KERNEL_SPAN); // span == exactly 2 MiB
    const p = try plan(good, 0x200000);
    try std.testing.expectEqual(@as(u64, MAX_KERNEL_SPAN), p.span);
}

test "elf64: span one past 2MiB rejected" {
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);
    fb.poke(u64, ph1_filesz, 0);
    fb.poke(u64, ph1_memsz, 0);
    fb.poke(u64, ph0_filesz, 0x40);
    fb.poke(u64, ph0_memsz, MAX_KERNEL_SPAN + 1); // span exceeds window
    try std.testing.expectError(error.SpanTooLarge, plan(good, 0x200000));
}

test "elf64: near-u64 memsz overflow rejected" {
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);
    fb.poke(u64, ph1_filesz, 0);
    fb.poke(u64, ph1_memsz, 0);
    fb.poke(u64, ph0_filesz, 0x40);
    fb.poke(u64, ph0_memsz, 0xFFFF_FFFF_FFFF_F000); // paddr + memsz overflows
    try std.testing.expectError(error.SegmentAddressOverflow, plan(good, 0x200000));
}

test "elf64: zero-file large-BSS accepted" {
    // Entry stays in the file-backed text segment; the data segment is pure
    // BSS (filesz 0, memsz 0x1000) and must be zeroed by execute().
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);
    fb.poke(u64, ph0_filesz, 0x40); // text remains file-backed (entry here)
    fb.poke(u64, ph0_memsz, 0x40);
    fb.poke(u64, ph1_filesz, 0);
    fb.poke(u64, ph1_memsz, 0x1000);
    const p = try plan(good, 0x200000);
    try std.testing.expectEqual(@as(u64, 0x2000), p.span);
    var dest: [0x2000]u8 = undefined;
    @memset(&dest, 0xAA);
    execute(&p, good, &dest);
    try std.testing.expectEqual(@as(u8, 0x90), dest[0]); // text file bytes copied
    try std.testing.expectEqual(@as(u8, 0), dest[0x1000]); // BSS zeroed
}

test "elf64: entry in BSS tail of executable segment rejected" {
    // PF_X, filesz 0, memsz > 0, entry == paddr must be rejected: the entry
    // would land in zero-filled memory, not file-backed executable code.
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);
    fb.poke(u64, ph1_filesz, 0);
    fb.poke(u64, ph1_memsz, 0);
    fb.poke(u64, ph0_filesz, 0); // text has no file bytes
    fb.poke(u64, ph0_memsz, 0x1000);
    try std.testing.expectError(error.EntryNotFileBacked, plan(good, 0x200000));
}

test "elf64: zero-size PT_LOAD validated before skip" {
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);

    // memsz 0 with nonzero file bytes -> SegmentMemUnderflow (not silently skipped).
    {
        const b = try fb.minimal(a, 0x200000);
        fb.poke(u64, ph1_filesz, 1);
        fb.poke(u64, ph1_memsz, 0);
        try std.testing.expectError(error.SegmentMemUnderflow, plan(b, 0x200000));
    }

    // memsz == filesz == 0 but non-identity -> IdentityMismatch.
    {
        const b = try fb.minimal(a, 0x200000);
        fb.poke(u64, ph1_paddr, 0x200000); // vaddr (base+0x1000) != paddr (base)
        fb.poke(u64, ph1_filesz, 0);
        fb.poke(u64, ph1_memsz, 0);
        try std.testing.expectError(error.IdentityMismatch, plan(b, 0x200000));
    }

    // Identity, file/zero zero-size load is a harmless no-op: a valid nonempty
    // text segment still establishes the entry and the plan succeeds.
    {
        const b = try fb.minimal(a, 0x200000);
        fb.poke(u64, ph1_filesz, 0);
        fb.poke(u64, ph1_memsz, 0);
        const p = try plan(b, 0x200000);
        try std.testing.expectEqual(@as(u32, 1), p.segment_count);
    }
}

test "elf64: near-max aligned base rejected (checked arithmetic)" {
    // A base near u64 max makes the 2 MiB window overflow the address space; the
    // loader must return a typed error, not a safety trap or wrapped window.
    // Build the single-segment image directly (filesz/memsz small, so the
    // segment end is in-range) so the window check itself is what fires.
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const base: u64 = 0xFFFF_FFFF_FFFF_F000; // page-aligned
    try fb.buf.resize(a, 0x100);
    @memset(fb.buf.items, 0);
    var eh: Ehdr = std.mem.zeroes(Ehdr);
    @memcpy(eh.ident[0..4], "\x7fELF");
    eh.ident[4] = 2;
    eh.ident[5] = 1;
    eh.ident[6] = 1;
    eh.type = ET_EXEC;
    eh.machine = EM_X86_64;
    eh.version = 1;
    eh.entry = base;
    eh.phoff = @sizeOf(Ehdr);
    eh.ehsize = @sizeOf(Ehdr);
    eh.phentsize = @sizeOf(Phdr);
    eh.phnum = 1;
    fb.poke(Ehdr, 0, eh);
    fb.poke(Phdr, @sizeOf(Ehdr), .{
        .type = PT_LOAD, .flags = PF_R | PF_X, .offset = 0,
        .vaddr = base, .paddr = base, .filesz = 0x40, .memsz = 0x40,
        .@"align" = 0x1000,
    });
    const b = fb.buf.items;
    try std.testing.expectError(error.SpanTooLarge, plan(b, base));
}

test "elf64: entry at high window edge not file-backed rejected" {
    // Entry at the window edge lands beyond the text segment's file-backed
    // region, so the file-backed executable-entry contract rejects it.
    const a = std.testing.allocator;
    var fb = FixtureBuilder.init();
    defer fb.deinit(a);
    const good = try fb.minimal(a, 0x200000);
    fb.poke(u64, ph1_filesz, 0);
    fb.poke(u64, ph1_memsz, 0);
    fb.poke(u64, ph0_filesz, 0x40);
    fb.poke(u64, ph0_memsz, MAX_KERNEL_SPAN);
    fb.poke(u64, 24, 0x200000 + MAX_KERNEL_SPAN); // entry beyond file-backed text
    try std.testing.expectError(error.EntryNotFileBacked, plan(good, 0x200000));
}
