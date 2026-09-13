// arch/x86_64/native/user_elf — allocation-free static-user ELF64 planner.
//
// Contract B (KWP3a.1): plan(bytes) inspects a little-endian ET_EXEC image and
// returns entry plus at most eight PT_LOAD descriptors. Descriptors keep file
// offset/filesz, vaddr/memsz, flags, the checked byte end, and 4 KiB-rounded
// mapping [start, end). No PMM, no copy, no stack constructor, no globals.
//
// This is a strict fixture profile, not a general ELF loader. Section headers
// are unused metadata and are never walked. p_paddr is ignored. Identity
// mapping is not required. No CPL3 execution claim.

const std = @import("std");

pub const PAGE: u64 = 4096;
pub const MAX_INPUT: usize = 64 * 1024 * 1024;
pub const MAX_PHDRS: u16 = 64;
pub const MAX_LOADS: u8 = 8;
pub const MAX_IMAGE_SPAN: u64 = 32 * 1024 * 1024;
pub const MAX_MAPPED_PAGES: u64 = 8192;
pub const IMAGE_LO: u64 = 0x40000000;
pub const IMAGE_HI: u64 = 0x60000000;
pub const EHDR_SIZE: u16 = 64;
pub const PHDR_SIZE: u16 = 56;

pub const ELFCLASS64: u8 = 2;
pub const ELFDATA2LSB: u8 = 1;
pub const EV_CURRENT: u8 = 1;
pub const ELFOSABI_NONE: u8 = 0;
pub const ET_EXEC: u16 = 2;
pub const EM_X86_64: u16 = 62;

pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_NOTE: u32 = 4;
pub const PT_PHDR: u32 = 6;
pub const PT_TLS: u32 = 7;
pub const PT_GNU_EH_FRAME: u32 = 0x6474e550;
pub const PT_GNU_STACK: u32 = 0x6474e551;
pub const PT_GNU_RELRO: u32 = 0x6474e552;
pub const PT_GNU_PROPERTY: u32 = 0x6474e553;

pub const PF_X: u32 = 1;
pub const PF_W: u32 = 2;
pub const PF_R: u32 = 4;
pub const PF_MASK: u32 = PF_R | PF_W | PF_X;

pub const Error = error{
    InputTooLarge,
    Truncated,
    BadMagic,
    BadClass,
    BadEndian,
    BadVersion,
    BadOsAbi,
    BadAbiVersion,
    BadType,
    BadMachine,
    BadFlags,
    BadHeaderSize,
    BadPhdrSize,
    TooManyPhdrs,
    PhdrTableOutOfBounds,
    UnsupportedPhdr,
    DuplicateGnuStack,
    ExecutableStack,
    NoLoadSegments,
    TooManyLoads,
    ZeroMemsz,
    FileszExceedsMemsz,
    SegmentFileOverflow,
    SegmentAddressOverflow,
    BadAlign,
    BadSegmentFlags,
    NoRead,
    WriteExecute,
    ImageOutOfRange,
    PageOverlap,
    ImageSpanTooLarge,
    TooManyPages,
    EntryNotFileBacked,
};

pub const Segment = struct {
    file_off: u64,
    filesz: u64,
    vaddr: u64,
    memsz: u64,
    flags: u32,
    byte_end: u64,
    map_start: u64,
    map_end: u64,
};

pub const Plan = struct {
    entry: u64,
    segments: [MAX_LOADS]Segment,
    segment_count: u8,
};

comptime {
    if (MAX_IMAGE_SPAN / PAGE != MAX_MAPPED_PAGES)
        @compileError("32 MiB span and 8192-page budget must match");
    if (IMAGE_LO % PAGE != 0 or IMAGE_HI % PAGE != 0)
        @compileError("user image interval must be page-aligned");
}

/// Validate `bytes` as a strict static-user ELF64 and return the load plan.
/// Never allocates, never mutates input, never follows section headers.
pub fn plan(bytes: []const u8) Error!Plan {
    if (bytes.len > MAX_INPUT) return error.InputTooLarge;
    if (bytes.len < EHDR_SIZE) return error.Truncated;

    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.BadMagic;
    if (bytes[4] != ELFCLASS64) return error.BadClass;
    if (bytes[5] != ELFDATA2LSB) return error.BadEndian;
    if (bytes[6] != EV_CURRENT) return error.BadVersion;
    if (bytes[7] != ELFOSABI_NONE) return error.BadOsAbi;
    if (bytes[8] != 0) return error.BadAbiVersion;

    const e_type = try readInt(u16, bytes, 16);
    const e_machine = try readInt(u16, bytes, 18);
    const e_version = try readInt(u32, bytes, 20);
    const e_entry = try readInt(u64, bytes, 24);
    const e_phoff = try readInt(u64, bytes, 32);
    const e_flags = try readInt(u32, bytes, 48);
    const e_ehsize = try readInt(u16, bytes, 52);
    const e_phentsize = try readInt(u16, bytes, 54);
    const e_phnum = try readInt(u16, bytes, 56);

    if (e_type != ET_EXEC) return error.BadType;
    if (e_machine != EM_X86_64) return error.BadMachine;
    if (e_version != 1) return error.BadVersion;
    if (e_flags != 0) return error.BadFlags;
    if (e_ehsize != EHDR_SIZE) return error.BadHeaderSize;
    if (e_phentsize != PHDR_SIZE) return error.BadPhdrSize;
    if (e_phnum == 0) return error.NoLoadSegments;
    if (e_phnum > MAX_PHDRS) return error.TooManyPhdrs;

    const table_bytes = std.math.mul(u64, e_phentsize, e_phnum) catch
        return error.PhdrTableOutOfBounds;
    const table_end = std.math.add(u64, e_phoff, table_bytes) catch
        return error.PhdrTableOutOfBounds;
    if (table_end > bytes.len) return error.PhdrTableOutOfBounds;

    var result: Plan = .{
        .entry = e_entry,
        .segments = undefined,
        .segment_count = 0,
    };
    var seen_gnu_stack = false;
    var i: u16 = 0;
    while (i < e_phnum) : (i += 1) {
        const ph_off = e_phoff + @as(u64, i) * PHDR_SIZE;
        const p_type = try readInt(u32, bytes, ph_off + 0);
        const p_flags = try readInt(u32, bytes, ph_off + 4);
        const p_offset = try readInt(u64, bytes, ph_off + 8);
        const p_vaddr = try readInt(u64, bytes, ph_off + 16);
        const p_paddr = try readInt(u64, bytes, ph_off + 24);
        const p_filesz = try readInt(u64, bytes, ph_off + 32);
        const p_memsz = try readInt(u64, bytes, ph_off + 40);
        const p_align = try readInt(u64, bytes, ph_off + 48);
        _ = p_paddr; // future PMM decision; not an identity or alloc instruction

        switch (p_type) {
            PT_NULL, PT_NOTE => try checkFileRange(bytes, p_offset, p_filesz),
            PT_GNU_STACK => {
                if (seen_gnu_stack) return error.DuplicateGnuStack;
                seen_gnu_stack = true;
                if ((p_flags & PF_X) != 0) return error.ExecutableStack;
                try checkFileRange(bytes, p_offset, p_filesz);
            },
            PT_LOAD => try appendLoad(&result, bytes, .{
                .offset = p_offset,
                .vaddr = p_vaddr,
                .filesz = p_filesz,
                .memsz = p_memsz,
                .flags = p_flags,
                .@"align" = p_align,
            }),
            else => return error.UnsupportedPhdr,
        }
    }

    if (result.segment_count == 0) return error.NoLoadSegments;
    try rejectPageOverlap(result.segments[0..result.segment_count]);
    try rejectImageBudget(result.segments[0..result.segment_count]);
    try requireExecutableFileEntry(result.entry, result.segments[0..result.segment_count]);
    return result;
}

const LoadFields = struct {
    offset: u64,
    vaddr: u64,
    filesz: u64,
    memsz: u64,
    flags: u32,
    @"align": u64,
};

fn appendLoad(result: *Plan, bytes: []const u8, ph: LoadFields) Error!void {
    if (ph.memsz == 0) return error.ZeroMemsz;
    if (ph.filesz > ph.memsz) return error.FileszExceedsMemsz;
    try checkFileRange(bytes, ph.offset, ph.filesz);

    const byte_end = std.math.add(u64, ph.vaddr, ph.memsz) catch
        return error.SegmentAddressOverflow;

    if ((ph.flags & ~PF_MASK) != 0) return error.BadSegmentFlags;
    if ((ph.flags & PF_R) == 0) return error.NoRead;
    if ((ph.flags & PF_W) != 0 and (ph.flags & PF_X) != 0) return error.WriteExecute;

    if (ph.@"align" > 1) {
        if (!std.math.isPowerOfTwo(ph.@"align")) return error.BadAlign;
        if ((ph.vaddr % ph.@"align") != (ph.offset % ph.@"align")) return error.BadAlign;
    }

    const map_start = ph.vaddr & ~(PAGE - 1);
    const map_end = try alignUpPage(byte_end);
    if (ph.vaddr < IMAGE_LO or byte_end > IMAGE_HI or
        map_start < IMAGE_LO or map_end > IMAGE_HI)
        return error.ImageOutOfRange;

    if (result.segment_count >= MAX_LOADS) return error.TooManyLoads;
    result.segments[result.segment_count] = .{
        .file_off = ph.offset,
        .filesz = ph.filesz,
        .vaddr = ph.vaddr,
        .memsz = ph.memsz,
        .flags = ph.flags,
        .byte_end = byte_end,
        .map_start = map_start,
        .map_end = map_end,
    };
    result.segment_count += 1;
}

fn rejectPageOverlap(segs: []const Segment) Error!void {
    for (segs, 0..) |a, ai| {
        for (segs[ai + 1 ..]) |b| {
            if (a.map_start < b.map_end and b.map_start < a.map_end)
                return error.PageOverlap;
        }
    }
}

fn rejectImageBudget(segs: []const Segment) Error!void {
    var lowest: u64 = std.math.maxInt(u64);
    var highest: u64 = 0;
    var pages: u64 = 0;
    for (segs) |s| {
        lowest = @min(lowest, s.map_start);
        highest = @max(highest, s.map_end);
        pages += (s.map_end - s.map_start) / PAGE;
    }
    if (highest - lowest > MAX_IMAGE_SPAN) return error.ImageSpanTooLarge;
    if (pages > MAX_MAPPED_PAGES) return error.TooManyPages;
}

fn requireExecutableFileEntry(entry: u64, segs: []const Segment) Error!void {
    for (segs) |s| {
        if ((s.flags & PF_X) == 0) continue;
        const file_va_end = s.vaddr + s.filesz; // filesz <= memsz and vaddr+memsz checked
        if (entry >= s.vaddr and entry < file_va_end) return;
    }
    return error.EntryNotFileBacked;
}

fn checkFileRange(bytes: []const u8, offset: u64, filesz: u64) Error!void {
    const end = std.math.add(u64, offset, filesz) catch
        return error.SegmentFileOverflow;
    if (end > bytes.len) return error.SegmentFileOverflow;
}

fn alignUpPage(addr: u64) Error!u64 {
    const mask: u64 = PAGE - 1;
    const sum = std.math.add(u64, addr, mask) catch
        return error.SegmentAddressOverflow;
    return sum & ~mask;
}

/// Explicit little-endian integer load. Copies into an aligned temporary so
/// the input slice need not be aligned and the host endianness is irrelevant.
fn readInt(comptime T: type, bytes: []const u8, off: u64) Error!T {
    const n: u64 = @sizeOf(T);
    const end = std.math.add(u64, off, n) catch return error.Truncated;
    if (end > bytes.len) return error.Truncated;
    var tmp: [@sizeOf(T)]u8 = undefined;
    @memcpy(&tmp, bytes[@intCast(off)..][0..@sizeOf(T)]);
    return std.mem.readInt(T, &tmp, .little);
}
