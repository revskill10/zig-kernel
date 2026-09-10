// proc/elf64 — validated ELF64 loader for zk-abi-v1 static executables.
// Replaces dead elf.zig (never compiled: wrong pread arity, unmapped copies).
// Slice-based: caller provides image bytes (ramfs pread, workspace upload).
// Load registers mm VMAs with prot from p_flags; entry gated to RX segment.
// Freestanding-safe: no std at runtime (tests only).
const mm = @import("../mm/mm.zig");
const gdt = @import("../arch/x86_64/gdt.zig");

pub const ELF_MAGIC: [4]u8 = .{ 0x7f, 'E', 'L', 'F' };
pub const ELFCLASS64: u8 = 2;
pub const ELFDATA2LSB: u8 = 1;
pub const ET_EXEC: u16 = 2;
pub const EM_X86_64: u16 = 62;
pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PF_X: u32 = 1;
pub const PF_W: u32 = 2;
pub const PF_R: u32 = 4;

pub const MAX_IMAGE: usize = 16 << 20;
pub const MAX_PHNUM: u16 = 16;
pub const MAX_SEG_MEMSZ: u64 = 64 << 20;

pub const Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

pub const Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub const Segment = struct { vaddr: u64, memsz: u64, prot: u32, flags: u32 };
pub const MAX_SEGS: usize = 16;

pub const Validated = struct {
    entry: u64,
    segs: [MAX_SEGS]Segment,
    nsegs: usize,
};

fn protOf(flags: u32) u32 {
    var p: u32 = 0;
    if (flags & PF_R != 0) p |= mm.PROT_READ;
    if (flags & PF_W != 0) p |= mm.PROT_WRITE;
    if (flags & PF_X != 0) p |= mm.PROT_EXEC;
    return p;
}

fn readEhdr(image: []const u8) ?Ehdr {
    if (image.len < @sizeOf(Ehdr)) return null;
    var h: Ehdr = undefined;
    @memcpy(std.mem.asBytes(&h), image[0..@sizeOf(Ehdr)]);
    return h;
}

fn readPhdr(image: []const u8, off: u64) ?Phdr {
    if (off +% @sizeOf(Phdr) < off) return null;
    if (off + @sizeOf(Phdr) > image.len) return null;
    var p: Phdr = undefined;
    @memcpy(std.mem.asBytes(&p), image[@intCast(off)..][0..@sizeOf(Phdr)]);
    return p;
}

/// Validate image; on success return entry + load segments. All rejects → error.
pub fn validate(image: []const u8) !Validated {
    if (image.len == 0 or image.len > MAX_IMAGE) return error.InvalidElf;
    const h = readEhdr(image) orelse return error.InvalidElf;
    if (!std.mem.eql(u8, h.e_ident[0..4], &ELF_MAGIC)) return error.InvalidElf;
    if (h.e_ident[4] != ELFCLASS64 or h.e_ident[5] != ELFDATA2LSB) return error.InvalidElf;
    if (h.e_ident[6] != 1) return error.InvalidElf; // EV_CURRENT
    if (h.e_type != ET_EXEC) return error.NotStatic; // no DYN/PIE in v1
    if (h.e_machine != EM_X86_64) return error.WrongArch;
    if (h.e_ehsize != @sizeOf(Ehdr)) return error.InvalidElf;
    if (h.e_phentsize != @sizeOf(Phdr)) return error.InvalidElf;
    if (h.e_phnum == 0 or h.e_phnum > MAX_PHNUM) return error.InvalidElf;
    if (h.e_phoff == 0 or h.e_phoff + @as(u64, h.e_phnum) * @sizeOf(Phdr) > image.len) return error.InvalidElf;

    var v = Validated{ .entry = h.e_entry, .segs = undefined, .nsegs = 0 };
    var i: usize = 0;
    while (i < h.e_phnum) : (i += 1) {
        const p = readPhdr(image, h.e_phoff + i * @sizeOf(Phdr)) orelse return error.InvalidElf;
        if (p.p_type == PT_DYNAMIC or p.p_type == PT_INTERP) return error.NeedsInterp;
        if (p.p_type != PT_LOAD) continue;
        if (p.p_memsz == 0) return error.InvalidElf;
        if (p.p_memsz > MAX_SEG_MEMSZ) return error.TooBig;
        if (p.p_filesz > p.p_memsz) return error.InvalidElf;
        if (p.p_offset +% p.p_filesz < p.p_offset) return error.InvalidElf;
        if (p.p_offset + p.p_filesz > image.len) return error.InvalidElf;
        const seg_start = p.p_vaddr & ~@as(u64, mm.PAGE_SIZE - 1);
        const seg_end = (p.p_vaddr +% p.p_memsz + mm.PAGE_SIZE - 1) & ~@as(u64, mm.PAGE_SIZE - 1);
        if (seg_end < seg_start) return error.InvalidElf; // wrapped
        if (!gdt.isUserRange(seg_start, seg_end - seg_start)) return error.KernelAddr;
        // overlap with earlier segments
        for (v.segs[0..v.nsegs]) |s| {
            const a = s.vaddr & ~@as(u64, mm.PAGE_SIZE - 1);
            const b = (s.vaddr +% s.memsz + mm.PAGE_SIZE - 1) & ~@as(u64, mm.PAGE_SIZE - 1);
            if (seg_start < b and seg_end > a) return error.Overlap;
        }
        if (v.nsegs >= MAX_SEGS) return error.TooManySegs;
        v.segs[v.nsegs] = .{ .vaddr = p.p_vaddr, .memsz = p.p_memsz, .prot = protOf(p.p_flags), .flags = p.p_flags };
        v.nsegs += 1;
    }
    if (v.nsegs == 0) return error.NoLoad;
    // entry: user half + inside an executable segment
    if (!gdt.isUserAddr(v.entry)) return error.BadEntry;
    var in_rx = false;
    for (v.segs[0..v.nsegs]) |s| {
        if (s.flags & PF_X != 0 and v.entry >= s.vaddr and v.entry < s.vaddr +% s.memsz) {
            in_rx = true;
            break;
        }
    }
    if (!in_rx) return error.BadEntry;
    return v;
}

/// Register VMAs for validated segments. Caller copies file bytes after.
/// Returns entry point. No VMA → no exec (fail closed).
pub fn load(v: *const Validated) !u64 {
    for (v.segs[0..v.nsegs]) |s| {
        const start = s.vaddr & ~@as(u64, mm.PAGE_SIZE - 1);
        const end = (s.vaddr +% s.memsz + mm.PAGE_SIZE - 1) & ~@as(u64, mm.PAGE_SIZE - 1);
        const got = mm.mmap(start, end - start, s.prot, mm.MAP_PRIVATE | mm.MAP_ANONYMOUS | mm.MAP_FIXED) orelse return error.NoMem;
        if (got != start) return error.MapMismatch;
    }
    return v.entry;
}

const std = @import("std");

fn mkImage(phnum: u16, phoff: u64, etype: u16, machine: u16, entry: u64, extra: usize) [512]u8 {
    var img: [512]u8 = [_]u8{0} ** 512;
    img[0] = 0x7f;
    img[1] = 'E';
    img[2] = 'L';
    img[3] = 'F';
    img[4] = ELFCLASS64;
    img[5] = ELFDATA2LSB;
    img[6] = 1;
    std.mem.writeInt(u16, img[16..18], etype, .little);
    std.mem.writeInt(u16, img[18..20], machine, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u64, img[24..32], entry, .little);
    std.mem.writeInt(u64, img[32..40], phoff, .little);
    std.mem.writeInt(u16, img[52..54], @sizeOf(Ehdr), .little);
    std.mem.writeInt(u16, img[54..56], @sizeOf(Phdr), .little);
    std.mem.writeInt(u16, img[56..58], phnum, .little);
    _ = extra;
    return img;
}

fn mkPhdr(img: *[512]u8, idx: usize, ptype: u32, flags: u32, off: u64, vaddr: u64, filesz: u64, memsz: u64) void {
    const at: usize = 64 + idx * @sizeOf(Phdr);
    std.mem.writeInt(u32, img[at..][0..4], ptype, .little);
    std.mem.writeInt(u32, img[at..][4..8], flags, .little);
    std.mem.writeInt(u64, img[at..][8..16], off, .little);
    std.mem.writeInt(u64, img[at..][16..24], vaddr, .little);
    std.mem.writeInt(u64, img[at..][24..32], vaddr, .little);
    std.mem.writeInt(u64, img[at..][32..40], filesz, .little);
    std.mem.writeInt(u64, img[at..][40..48], memsz, .little);
    std.mem.writeInt(u64, img[at..][48..56], 0x1000, .little);
}

test "elf64: minimal valid static exec passes" {
    var img = mkImage(1, 64, ET_EXEC, EM_X86_64, 0x400000, 0);
    mkPhdr(&img, 0, PT_LOAD, PF_R | PF_X, 0, 0x400000, 128, 128);
    const v = try validate(&img);
    try std.testing.expectEqual(@as(u64, 0x400000), v.entry);
    try std.testing.expectEqual(@as(usize, 1), v.nsegs);
}

test "elf64: rejects bad magic/class/arch/type" {
    var img = mkImage(1, 64, ET_EXEC, EM_X86_64, 0x400000, 0);
    mkPhdr(&img, 0, PT_LOAD, PF_R | PF_X, 0, 0x400000, 128, 128);
    var bad = img;
    bad[0] = 0;
    try std.testing.expectError(error.InvalidElf, validate(&bad));
    bad = img;
    bad[4] = 1; // ELFCLASS32
    try std.testing.expectError(error.InvalidElf, validate(&bad));
    bad = img;
    std.mem.writeInt(u16, bad[18..20], 3, .little); // EM_386
    try std.testing.expectError(error.WrongArch, validate(&bad));
    bad = img;
    std.mem.writeInt(u16, bad[16..18], 3, .little); // ET_DYN
    try std.testing.expectError(error.NotStatic, validate(&bad));
}

test "elf64: rejects dynamic/interp segments" {
    var img = mkImage(2, 64, ET_EXEC, EM_X86_64, 0x400000, 0);
    mkPhdr(&img, 0, PT_LOAD, PF_R | PF_X, 0, 0x400000, 128, 128);
    mkPhdr(&img, 1, PT_INTERP, PF_R, 0, 0x401000, 16, 16);
    try std.testing.expectError(error.NeedsInterp, validate(&img));
    mkPhdr(&img, 1, PT_DYNAMIC, PF_R | PF_W, 0, 0x401000, 16, 16);
    try std.testing.expectError(error.NeedsInterp, validate(&img));
}

test "elf64: rejects kernel-half vaddr, overlap, filesz>memsz, bad entry" {
    var img = mkImage(1, 64, ET_EXEC, EM_X86_64, 0x400000, 0);
    mkPhdr(&img, 0, PT_LOAD, PF_R | PF_X, 0, 0xFFFF800000000000, 128, 128);
    try std.testing.expectError(error.KernelAddr, validate(&img));
    img = mkImage(2, 64, ET_EXEC, EM_X86_64, 0x400000, 0);
    mkPhdr(&img, 0, PT_LOAD, PF_R | PF_X, 0, 0x400000, 128, 0x2000);
    mkPhdr(&img, 1, PT_LOAD, PF_R | PF_W, 0, 0x401000, 64, 0x1000);
    try std.testing.expectError(error.Overlap, validate(&img));
    img = mkImage(1, 64, ET_EXEC, EM_X86_64, 0x400000, 0);
    mkPhdr(&img, 0, PT_LOAD, PF_R | PF_X, 0, 0x400000, 256, 128);
    try std.testing.expectError(error.InvalidElf, validate(&img));
    img = mkImage(1, 64, ET_EXEC, EM_X86_64, 0x402000, 0); // entry outside RX seg
    mkPhdr(&img, 0, PT_LOAD, PF_R | PF_X, 0, 0x400000, 128, 128);
    try std.testing.expectError(error.BadEntry, validate(&img));
}
