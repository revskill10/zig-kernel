// tests/native-user/elf_check.zig — hosted Contract B gate for the static-user
// ELF planner. Imports the named `user_elf` module; not runnable via a bare
// `zig test tests/native-user/elf_check.zig`. Module CLI wiring:
//   zig test --dep user_elf -Mroot=tests/native-user/elf_check.zig \
//       -Muser_elf=src/arch/x86_64/native/user_elf.zig \
//       --cache-dir <scratch>/cache --global-cache-dir <scratch>/global-cache
//
// Fixtures are fixed byte arrays plus little-endian writers. No guest import,
// no runtime mapping, no CPL3 claim.

const std = @import("std");
const elf = @import("user_elf");

const EHDR: usize = elf.EHDR_SIZE;
const PHDR: usize = elf.PHDR_SIZE;
const PAGE: u64 = elf.PAGE;
const IMAGE_LO: u64 = elf.IMAGE_LO;
const IMAGE_HI: u64 = elf.IMAGE_HI;

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

fn phAt(index: usize) usize {
    return EHDR + index * PHDR;
}

const EhdrSpec = struct {
    entry: u64,
    phoff: u64 = EHDR,
    phnum: u16,
    e_type: u16 = elf.ET_EXEC,
    machine: u16 = elf.EM_X86_64,
    version: u32 = 1,
    flags: u32 = 0,
    ehsize: u16 = elf.EHDR_SIZE,
    phentsize: u16 = elf.PHDR_SIZE,
    shoff: u64 = 0,
    magic: [4]u8 = .{ 0x7f, 'E', 'L', 'F' },
    class: u8 = elf.ELFCLASS64,
    data: u8 = elf.ELFDATA2LSB,
    ident_version: u8 = elf.EV_CURRENT,
    osabi: u8 = elf.ELFOSABI_NONE,
    abiver: u8 = 0,
};

fn writeEhdr(buf: []u8, s: EhdrSpec) void {
    @memcpy(buf[0..4], &s.magic);
    w8(buf, 4, s.class);
    w8(buf, 5, s.data);
    w8(buf, 6, s.ident_version);
    w8(buf, 7, s.osabi);
    w8(buf, 8, s.abiver);
    w16(buf, 16, s.e_type);
    w16(buf, 18, s.machine);
    w32(buf, 20, s.version);
    w64(buf, 24, s.entry);
    w64(buf, 32, s.phoff);
    w64(buf, 40, s.shoff);
    w32(buf, 48, s.flags);
    w16(buf, 52, s.ehsize);
    w16(buf, 54, s.phentsize);
    w16(buf, 56, s.phnum);
    w16(buf, 58, 0);
    w16(buf, 60, 0);
    w16(buf, 62, 0);
}

const PhdrSpec = struct {
    p_type: u32,
    p_flags: u32 = 0,
    p_offset: u64 = 0,
    p_vaddr: u64 = 0,
    p_paddr: u64 = 0,
    p_filesz: u64 = 0,
    p_memsz: u64 = 0,
    p_align: u64 = 0,
};

fn writePhdr(buf: []u8, index: usize, s: PhdrSpec) void {
    const at = phAt(index);
    w32(buf, at + 0, s.p_type);
    w32(buf, at + 4, s.p_flags);
    w64(buf, at + 8, s.p_offset);
    w64(buf, at + 16, s.p_vaddr);
    w64(buf, at + 24, s.p_paddr);
    w64(buf, at + 32, s.p_filesz);
    w64(buf, at + 40, s.p_memsz);
    w64(buf, at + 48, s.p_align);
}

fn rx(vaddr: u64, offset: u64, filesz: u64, memsz: u64, p_align: u64, paddr: u64) PhdrSpec {
    return .{
        .p_type = elf.PT_LOAD,
        .p_flags = elf.PF_R | elf.PF_X,
        .p_offset = offset,
        .p_vaddr = vaddr,
        .p_paddr = paddr,
        .p_filesz = filesz,
        .p_memsz = memsz,
        .p_align = p_align,
    };
}

fn ro(vaddr: u64, offset: u64, filesz: u64, memsz: u64, p_align: u64) PhdrSpec {
    return .{
        .p_type = elf.PT_LOAD,
        .p_flags = elf.PF_R,
        .p_offset = offset,
        .p_vaddr = vaddr,
        .p_filesz = filesz,
        .p_memsz = memsz,
        .p_align = p_align,
    };
}

fn rw(vaddr: u64, offset: u64, filesz: u64, memsz: u64, p_align: u64) PhdrSpec {
    return .{
        .p_type = elf.PT_LOAD,
        .p_flags = elf.PF_R | elf.PF_W,
        .p_offset = offset,
        .p_vaddr = vaddr,
        .p_filesz = filesz,
        .p_memsz = memsz,
        .p_align = p_align,
    };
}

fn gnuStack() PhdrSpec {
    return .{
        .p_type = elf.PT_GNU_STACK,
        .p_flags = elf.PF_R | elf.PF_W,
        .p_align = 16,
    };
}

/// Canonical four-load image: RX / RO / RW / BSS plus non-exec GNU_STACK.
/// File length 0x4000. Entry in the first file-backed executable byte after
/// a 0x10 bias. p_paddr values are deliberately unrelated to vaddr.
fn canonical(buf: *[0x4000]u8) []u8 {
    @memset(buf, 0);
    writeEhdr(buf, .{ .entry = IMAGE_LO + 0x10, .phnum = 5 });
    writePhdr(buf, 0, rx(IMAGE_LO, 0x1000, 0x200, 0x200, 0x1000, 0x11110000));
    writePhdr(buf, 1, ro(IMAGE_LO + PAGE, 0x2000, 0x100, 0x100, 0x1000));
    writePhdr(buf, 2, rw(IMAGE_LO + 2 * PAGE, 0x3000, 0x80, 0x80, 0x1000));
    writePhdr(buf, 3, rw(IMAGE_LO + 3 * PAGE, 0, 0, 0x1000, 0x1000));
    writePhdr(buf, 4, gnuStack());
    buf[0x1000] = 0x90;
    buf[0x1000 + 0x1FF] = 0xC3;
    buf[0x2000] = 0x42;
    buf[0x3000] = 0x55;
    return buf[0..0x4000];
}

fn expectSeg(
    s: elf.Segment,
    file_off: u64,
    filesz: u64,
    vaddr: u64,
    memsz: u64,
    flags: u32,
) !void {
    try std.testing.expectEqual(file_off, s.file_off);
    try std.testing.expectEqual(filesz, s.filesz);
    try std.testing.expectEqual(vaddr, s.vaddr);
    try std.testing.expectEqual(memsz, s.memsz);
    try std.testing.expectEqual(flags, s.flags);
    try std.testing.expectEqual(vaddr + memsz, s.byte_end);
    try std.testing.expectEqual(vaddr & ~(PAGE - 1), s.map_start);
    const mask: u64 = PAGE - 1;
    try std.testing.expectEqual((vaddr + memsz + mask) & ~mask, s.map_end);
}

test "canonical RX/RO/RW/BSS descriptors and GNU_STACK" {
    var buf: [0x4000]u8 = undefined;
    const img = canonical(&buf);
    const p = try elf.plan(img);
    try std.testing.expectEqual(IMAGE_LO + 0x10, p.entry);
    try std.testing.expectEqual(@as(u8, 4), p.segment_count);
    try expectSeg(p.segments[0], 0x1000, 0x200, IMAGE_LO, 0x200, elf.PF_R | elf.PF_X);
    try expectSeg(p.segments[1], 0x2000, 0x100, IMAGE_LO + PAGE, 0x100, elf.PF_R);
    try expectSeg(p.segments[2], 0x3000, 0x80, IMAGE_LO + 2 * PAGE, 0x80, elf.PF_R | elf.PF_W);
    try expectSeg(p.segments[3], 0, 0, IMAGE_LO + 3 * PAGE, 0x1000, elf.PF_R | elf.PF_W);
    try std.testing.expectEqual(IMAGE_LO, p.segments[0].map_start);
    try std.testing.expectEqual(IMAGE_LO + 4 * PAGE, p.segments[3].map_end);
}

test "unaligned input slice is accepted" {
    var storage: [0x4001]u8 = undefined;
    @memset(&storage, 0xA5);
    const img = storage[1..];
    @memset(img, 0);
    writeEhdr(img, .{ .entry = IMAGE_LO + 0x10, .phnum = 5 });
    writePhdr(img, 0, rx(IMAGE_LO, 0x1000, 0x200, 0x200, 0x1000, 0x1));
    writePhdr(img, 1, ro(IMAGE_LO + PAGE, 0x2000, 0x100, 0x100, 0x1000));
    writePhdr(img, 2, rw(IMAGE_LO + 2 * PAGE, 0x3000, 0x80, 0x80, 0x1000));
    writePhdr(img, 3, rw(IMAGE_LO + 3 * PAGE, 0, 0, 0x1000, 0x1000));
    writePhdr(img, 4, gnuStack());
    const p = try elf.plan(img[0..0x4000]);
    try std.testing.expectEqual(@as(u8, 4), p.segment_count);
    try std.testing.expectEqual(IMAGE_LO + 0x10, p.entry);
}

test "p_align 0, 1, and congruent power-of-two accepted" {
    var buf: [0x4000]u8 = undefined;

    {
        const img = canonical(&buf);
        w64(img, phAt(0) + 48, 0);
        w64(img, phAt(0) + 8, 0x123); // incongruent for page align, allowed for 0
        const p = try elf.plan(img);
        try std.testing.expectEqual(@as(u64, 0x123), p.segments[0].file_off);
    }
    {
        const img = canonical(&buf);
        w64(img, phAt(0) + 48, 1);
        w64(img, phAt(0) + 8, 0x111);
        const p = try elf.plan(img);
        try std.testing.expectEqual(@as(u64, 0x111), p.segments[0].file_off);
    }
    {
        const img = canonical(&buf);
        w64(img, phAt(0) + 48, 8);
        w64(img, phAt(0) + 16, IMAGE_LO + 8);
        w64(img, phAt(0) + 8, 0x1008);
        w64(img, 24, IMAGE_LO + 8);
        w64(img, phAt(0) + 32, 0x40);
        w64(img, phAt(0) + 40, 0x40);
        const p = try elf.plan(img);
        try std.testing.expectEqual(IMAGE_LO + 8, p.segments[0].vaddr);
        try std.testing.expectEqual(IMAGE_LO, p.segments[0].map_start);
        try std.testing.expectEqual(IMAGE_LO + PAGE, p.segments[0].map_end);
    }
}

test "independent arbitrary p_paddr is ignored" {
    var buf: [0x4000]u8 = undefined;
    const img = canonical(&buf);
    w64(img, phAt(0) + 24, 0xFFFF_FFFF_FFFF_FFFF);
    w64(img, phAt(1) + 24, 0);
    w64(img, phAt(2) + 24, IMAGE_LO);
    const p = try elf.plan(img);
    try std.testing.expectEqual(IMAGE_LO, p.segments[0].vaddr);
    try std.testing.expectEqual(@as(u8, 4), p.segment_count);
}

test "NULL and NOTE with in-bounds file ranges accepted" {
    var buf: [0x4000]u8 = undefined;
    @memset(&buf, 0);
    writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 4 });
    writePhdr(&buf, 0, rx(IMAGE_LO, 0x1000, 0x20, 0x20, 0x1000, 0));
    writePhdr(&buf, 1, .{ .p_type = elf.PT_NULL, .p_offset = 0, .p_filesz = 0 });
    writePhdr(&buf, 2, .{
        .p_type = elf.PT_NOTE,
        .p_flags = elf.PF_R,
        .p_offset = 0x200,
        .p_filesz = 16,
        .p_memsz = 16,
        .p_align = 4,
    });
    writePhdr(&buf, 3, gnuStack());
    const p = try elf.plan(buf[0..0x2000]);
    try std.testing.expectEqual(@as(u8, 1), p.segment_count);
    try std.testing.expectEqual(IMAGE_LO, p.entry);
}

test "NULL and NOTE out-of-bounds file ranges rejected" {
    var buf: [0x4000]u8 = undefined;
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x100, 0x20, 0x20, 1, 0));
        writePhdr(&buf, 1, .{ .p_type = elf.PT_NOTE, .p_offset = 0x1FF0, .p_filesz = 0x20 });
        try std.testing.expectError(error.SegmentFileOverflow, elf.plan(buf[0..0x2000]));
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x100, 0x20, 0x20, 1, 0));
        writePhdr(&buf, 1, .{ .p_type = elf.PT_NULL, .p_offset = 0xFFFF_FFFF_FFFF_FFF0, .p_filesz = 0x20 });
        try std.testing.expectError(error.SegmentFileOverflow, elf.plan(buf[0..0x2000]));
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x100, 0x20, 0x20, 1, 0));
        writePhdr(&buf, 1, .{
            .p_type = elf.PT_GNU_STACK,
            .p_flags = elf.PF_R | elf.PF_W,
            .p_offset = 0x1FF8,
            .p_filesz = 16,
        });
        try std.testing.expectError(error.SegmentFileOverflow, elf.plan(buf[0..0x2000]));
    }
}

test "unsupported PHDR types rejected" {
    const kinds = [_]u32{
        elf.PT_INTERP,
        elf.PT_DYNAMIC,
        elf.PT_TLS,
        elf.PT_PHDR,
        elf.PT_GNU_RELRO,
        elf.PT_GNU_PROPERTY,
        elf.PT_GNU_EH_FRAME,
        0x12345678,
    };
    var buf: [0x4000]u8 = undefined;
    for (kinds) |kind| {
        const img = canonical(&buf);
        w32(img, phAt(4) + 0, kind);
        try std.testing.expectError(error.UnsupportedPhdr, elf.plan(img));
    }
}

test "executable and duplicate GNU_STACK rejected" {
    var buf: [0x4000]u8 = undefined;
    {
        const img = canonical(&buf);
        w32(img, phAt(4) + 4, elf.PF_R | elf.PF_W | elf.PF_X);
        try std.testing.expectError(error.ExecutableStack, elf.plan(img));
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 3 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x400, 0x20, 0x20, 1, 0));
        writePhdr(&buf, 1, gnuStack());
        writePhdr(&buf, 2, gnuStack());
        try std.testing.expectError(error.DuplicateGnuStack, elf.plan(buf[0..0x800]));
    }
}

test "bad identity and header fields" {
    var buf: [0x4000]u8 = undefined;
    {
        const img = canonical(&buf);
        img[0] = 0;
        try std.testing.expectError(error.BadMagic, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        img[4] = 1;
        try std.testing.expectError(error.BadClass, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        img[5] = 2;
        try std.testing.expectError(error.BadEndian, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        img[6] = 0;
        try std.testing.expectError(error.BadVersion, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        img[7] = 3; // ELFOSABI_LINUX
        try std.testing.expectError(error.BadOsAbi, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        img[8] = 1;
        try std.testing.expectError(error.BadAbiVersion, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w32(img, 20, 0);
        try std.testing.expectError(error.BadVersion, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w16(img, 16, 3); // ET_DYN
        try std.testing.expectError(error.BadType, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w16(img, 16, 1); // ET_REL
        try std.testing.expectError(error.BadType, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w16(img, 18, 3); // EM_386
        try std.testing.expectError(error.BadMachine, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w32(img, 48, 1);
        try std.testing.expectError(error.BadFlags, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w16(img, 52, 63);
        try std.testing.expectError(error.BadHeaderSize, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w16(img, 52, 65);
        try std.testing.expectError(error.BadHeaderSize, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w16(img, 54, 55);
        try std.testing.expectError(error.BadPhdrSize, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w16(img, 54, 64);
        try std.testing.expectError(error.BadPhdrSize, elf.plan(img));
    }
}

test "table bounds and phnum cap" {
    var buf: [0x4000]u8 = undefined;
    {
        const img = canonical(&buf);
        w16(img, 56, 65);
        try std.testing.expectError(error.TooManyPhdrs, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w16(img, 56, 0xFFFF);
        try std.testing.expectError(error.TooManyPhdrs, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w64(img, 32, 0x3FF0); // phoff near EOF
        w16(img, 56, 1);
        try std.testing.expectError(error.PhdrTableOutOfBounds, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w64(img, 32, 0xFFFF_FFFF_FFFF_FFC0);
        w16(img, 56, 2);
        try std.testing.expectError(error.PhdrTableOutOfBounds, elf.plan(img));
    }
}

test "exactly 64 PHDRs accepted; zero and more than eight loads rejected" {
    var buf: [0x2000]u8 = undefined;
    @memset(&buf, 0);
    writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 64 });
    writePhdr(&buf, 0, rx(IMAGE_LO, 0x1000, 0x20, 0x20, 0x1000, 0));
    var n: usize = 1;
    while (n < 64) : (n += 1) {
        writePhdr(&buf, n, .{ .p_type = elf.PT_NULL });
    }
    const p64 = try elf.plan(buf[0..0x2000]);
    try std.testing.expectEqual(@as(u8, 1), p64.segment_count);

    {
        var small: [0x4000]u8 = undefined;
        const img = canonical(&small);
        w16(img, 56, 0);
        try std.testing.expectError(error.NoLoadSegments, elf.plan(img));
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, .{ .p_type = elf.PT_NULL });
        writePhdr(&buf, 1, gnuStack());
        try std.testing.expectError(error.NoLoadSegments, elf.plan(buf[0..0x200]));
    }

    var loads: [0x2000]u8 = undefined;
    @memset(&loads, 0);
    writeEhdr(&loads, .{ .entry = IMAGE_LO, .phnum = 8 });
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const va = IMAGE_LO + i * PAGE;
        writePhdr(&loads, i, rx(va, 0x1000 + i * 0x10, 0x10, 0x10, 0, 0));
    }
    w64(&loads, 24, IMAGE_LO);
    const p8 = try elf.plan(loads[0..0x2000]);
    try std.testing.expectEqual(@as(u8, 8), p8.segment_count);

    @memset(&loads, 0);
    writeEhdr(&loads, .{ .entry = IMAGE_LO, .phnum = 9 });
    i = 0;
    while (i < 9) : (i += 1) {
        const va = IMAGE_LO + i * PAGE;
        writePhdr(&loads, i, rx(va, 0x1000 + i * 0x10, 0x10, 0x10, 0, 0));
    }
    try std.testing.expectError(error.TooManyLoads, elf.plan(loads[0..0x2000]));
}

test "truncated header and truncated PHDR table" {
    var buf: [0x4000]u8 = undefined;
    const img = canonical(&buf);
    try std.testing.expectError(error.Truncated, elf.plan(img[0..0]));
    try std.testing.expectError(error.Truncated, elf.plan(img[0..32]));
    try std.testing.expectError(error.Truncated, elf.plan(img[0..63]));

    var tiny: [64 + 20]u8 = undefined;
    @memset(&tiny, 0);
    writeEhdr(&tiny, .{ .entry = IMAGE_LO, .phnum = 1 });
    try std.testing.expectError(error.PhdrTableOutOfBounds, elf.plan(&tiny));
}

test "offset and address overflow" {
    var buf: [0x4000]u8 = undefined;
    {
        const img = canonical(&buf);
        w64(img, phAt(0) + 8, 0xFFFF_FFFF_FFFF_FFF0);
        w64(img, phAt(0) + 32, 0x20);
        w64(img, phAt(0) + 40, 0x20);
        w64(img, phAt(0) + 48, 0);
        try std.testing.expectError(error.SegmentFileOverflow, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w64(img, phAt(0) + 16, 0xFFFF_FFFF_FFFF_F000);
        w64(img, phAt(0) + 40, 0x2000);
        w64(img, phAt(0) + 32, 0x20);
        w64(img, phAt(0) + 48, 0);
        try std.testing.expectError(error.SegmentAddressOverflow, elf.plan(img));
    }
    {
        // zero filesz still checks offset against the file
        const img = canonical(&buf);
        w64(img, phAt(3) + 8, 0x5000);
        w64(img, phAt(3) + 32, 0);
        try std.testing.expectError(error.SegmentFileOverflow, elf.plan(img));
    }
}

test "filesz > memsz, zero memsz rejected, zero-filesz BSS accepted" {
    var buf: [0x4000]u8 = undefined;
    {
        const img = canonical(&buf);
        w64(img, phAt(0) + 32, 0x300);
        w64(img, phAt(0) + 40, 0x200);
        try std.testing.expectError(error.FileszExceedsMemsz, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w64(img, phAt(1) + 32, 0);
        w64(img, phAt(1) + 40, 0);
        try std.testing.expectError(error.ZeroMemsz, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        const p = try elf.plan(img);
        try std.testing.expectEqual(@as(u64, 0), p.segments[3].filesz);
        try std.testing.expectEqual(@as(u64, 0x1000), p.segments[3].memsz);
        try std.testing.expectEqual(IMAGE_LO + 3 * PAGE, p.segments[3].vaddr);
    }
}

test "invalid, no-read, unknown, and W+X flags rejected" {
    var buf: [0x4000]u8 = undefined;
    {
        const img = canonical(&buf);
        w32(img, phAt(0) + 4, 0);
        try std.testing.expectError(error.NoRead, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w32(img, phAt(0) + 4, elf.PF_X);
        try std.testing.expectError(error.NoRead, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w32(img, phAt(2) + 4, elf.PF_W);
        try std.testing.expectError(error.NoRead, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w32(img, phAt(1) + 4, elf.PF_R | 0x8);
        try std.testing.expectError(error.BadSegmentFlags, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w32(img, phAt(1) + 4, elf.PF_R | 0x0FF00000);
        try std.testing.expectError(error.BadSegmentFlags, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w32(img, phAt(0) + 4, elf.PF_R | elf.PF_W | elf.PF_X);
        try std.testing.expectError(error.WriteExecute, elf.plan(img));
    }
}

test "bad alignment and congruence rejected" {
    var buf: [0x4000]u8 = undefined;
    {
        const img = canonical(&buf);
        w64(img, phAt(0) + 48, 3);
        try std.testing.expectError(error.BadAlign, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w64(img, phAt(0) + 48, 12);
        try std.testing.expectError(error.BadAlign, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w64(img, phAt(0) + 48, 0x1000);
        w64(img, phAt(0) + 8, 0x100);
        try std.testing.expectError(error.BadAlign, elf.plan(img));
    }
}

test "byte overlap, same-page disjoint bytes, and page-adjacent" {
    var buf: [0x1000]u8 = undefined;

    // Byte overlap: second segment starts inside the first memsz.
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x200, 0x20, 0x1800, 0, 0));
        writePhdr(&buf, 1, rw(IMAGE_LO + PAGE, 0x300, 0x10, 0x1000, 0));
        try std.testing.expectError(error.PageOverlap, elf.plan(buf[0..0x400]));
    }

    // Disjoint bytes that share a page.
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x200, 0x10, 0x10, 0, 0));
        writePhdr(&buf, 1, rw(IMAGE_LO + 0x20, 0x300, 0x10, 0x10, 0));
        try std.testing.expectError(error.PageOverlap, elf.plan(buf[0..0x400]));
    }

    // Reverse PHDR order still detects the shared page.
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO + PAGE + 0x8, .phnum = 2 });
        writePhdr(&buf, 0, rw(IMAGE_LO + PAGE + 0x20, 0x300, 0x10, 0x10, 0));
        writePhdr(&buf, 1, rx(IMAGE_LO + PAGE, 0x200, 0x10, 0x10, 0, 0));
        try std.testing.expectError(error.PageOverlap, elf.plan(buf[0..0x400]));
    }

    // Exact page-boundary adjacency is permitted.
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x200, 0x20, PAGE, 0, 0));
        writePhdr(&buf, 1, rw(IMAGE_LO + PAGE, 0x300, 0x10, PAGE, 0));
        const p = try elf.plan(buf[0..0x400]);
        try std.testing.expectEqual(@as(u8, 2), p.segment_count);
        try std.testing.expectEqual(IMAGE_LO + PAGE, p.segments[0].byte_end);
        try std.testing.expectEqual(IMAGE_LO + PAGE, p.segments[0].map_end);
        try std.testing.expectEqual(IMAGE_LO + PAGE, p.segments[1].map_start);
        try std.testing.expectEqual(IMAGE_LO + PAGE, p.segments[1].vaddr);
    }
}

test "image lower and upper boundaries" {
    var buf: [0x800]u8 = undefined;

    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 1 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x80, 0x20, 0x20, 0, 0));
        const p = try elf.plan(buf[0..0x200]);
        try std.testing.expectEqual(IMAGE_LO, p.segments[0].vaddr);
        try std.testing.expectEqual(IMAGE_LO, p.segments[0].map_start);
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO - 1, .phnum = 1 });
        writePhdr(&buf, 0, rx(IMAGE_LO - 1, 0x80, 0x20, 0x20, 0, 0));
        try std.testing.expectError(error.ImageOutOfRange, elf.plan(buf[0..0x200]));
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO - PAGE, .phnum = 1 });
        writePhdr(&buf, 0, rx(IMAGE_LO - PAGE, 0x80, 0x20, 0x20, 0, 0));
        try std.testing.expectError(error.ImageOutOfRange, elf.plan(buf[0..0x200]));
    }

    const hi_last_page = IMAGE_HI - PAGE;
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = hi_last_page, .phnum = 1 });
        writePhdr(&buf, 0, rx(hi_last_page, 0x80, 0x20, PAGE, 0, 0));
        const p = try elf.plan(buf[0..0x200]);
        try std.testing.expectEqual(IMAGE_HI, p.segments[0].byte_end);
        try std.testing.expectEqual(IMAGE_HI, p.segments[0].map_end);
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = hi_last_page, .phnum = 1 });
        writePhdr(&buf, 0, rx(hi_last_page, 0x80, 0x20, PAGE + 1, 0, 0));
        try std.testing.expectError(error.ImageOutOfRange, elf.plan(buf[0..0x200]));
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_HI, .phnum = 1 });
        writePhdr(&buf, 0, rx(IMAGE_HI, 0x80, 0x20, 0x20, 0, 0));
        try std.testing.expectError(error.ImageOutOfRange, elf.plan(buf[0..0x200]));
    }
}

test "exact 32 MiB span accepted; next page and sparse far pair rejected" {
    var buf: [0x800]u8 = undefined;

    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x200, 0x20, 0x20, 0, 0));
        writePhdr(&buf, 1, rw(IMAGE_LO + elf.MAX_IMAGE_SPAN - PAGE, 0x300, 0, PAGE, 0));
        const p = try elf.plan(buf[0..0x400]);
        try std.testing.expectEqual(@as(u8, 2), p.segment_count);
        try std.testing.expectEqual(IMAGE_LO, p.segments[0].map_start);
        try std.testing.expectEqual(IMAGE_LO + elf.MAX_IMAGE_SPAN, p.segments[1].map_end);
        try std.testing.expectEqual(elf.MAX_IMAGE_SPAN, p.segments[1].map_end - p.segments[0].map_start);
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x200, 0x20, 0x20, 0, 0));
        writePhdr(&buf, 1, rw(IMAGE_LO + elf.MAX_IMAGE_SPAN, 0x300, 0, PAGE, 0));
        try std.testing.expectError(error.ImageSpanTooLarge, elf.plan(buf[0..0x400]));
    }
    {
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x200, 0x20, 0x20, 0, 0));
        writePhdr(&buf, 1, rw(IMAGE_LO + 40 * 1024 * 1024, 0x300, 0, PAGE, 0));
        try std.testing.expectError(error.ImageSpanTooLarge, elf.plan(buf[0..0x400]));
    }
}

test "entry at last executable file byte accepted; end, BSS, and non-exec rejected" {
    var buf: [0x4000]u8 = undefined;

    {
        const img = canonical(&buf);
        w64(img, 24, IMAGE_LO + 0x1FF); // last file-backed RX byte
        const p = try elf.plan(img);
        try std.testing.expectEqual(IMAGE_LO + 0x1FF, p.entry);
    }
    {
        const img = canonical(&buf);
        w64(img, 24, IMAGE_LO + 0x200); // exclusive file end
        try std.testing.expectError(error.EntryNotFileBacked, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w64(img, 24, IMAGE_LO + 3 * PAGE); // BSS of RW segment
        try std.testing.expectError(error.EntryNotFileBacked, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w64(img, 24, IMAGE_LO + PAGE); // RO segment
        try std.testing.expectError(error.EntryNotFileBacked, elf.plan(img));
    }
    {
        const img = canonical(&buf);
        w64(img, 24, IMAGE_LO + 2 * PAGE); // RW file-backed
        try std.testing.expectError(error.EntryNotFileBacked, elf.plan(img));
    }
    {
        // BSS-only executable segment cannot host entry.
        @memset(&buf, 0);
        writeEhdr(&buf, .{ .entry = IMAGE_LO, .phnum = 2 });
        writePhdr(&buf, 0, rx(IMAGE_LO, 0x200, 0, PAGE, 0, 0));
        writePhdr(&buf, 1, rw(IMAGE_LO + PAGE, 0x200, 0x10, 0x10, 0));
        try std.testing.expectError(error.EntryNotFileBacked, elf.plan(buf[0..0x400]));
    }
}

test "input larger than 64 MiB rejected before payload reads" {
    var one: [1]u8 = .{0x7F};
    const oversized: []const u8 = @as([*]const u8, &one)[0 .. elf.MAX_INPUT + 1];
    try std.testing.expectError(error.InputTooLarge, elf.plan(oversized));
}

test "section header fields are ignored" {
    var buf: [0x4000]u8 = undefined;
    const img = canonical(&buf);
    w64(img, 40, 0xFFFF_FFFF_FFFF_0000); // e_shoff
    w16(img, 58, 0xFFFF); // e_shentsize
    w16(img, 60, 0xFFFF); // e_shnum
    w16(img, 62, 0xFFFF); // e_shstrndx
    const p = try elf.plan(img);
    try std.testing.expectEqual(@as(u8, 4), p.segment_count);
}
