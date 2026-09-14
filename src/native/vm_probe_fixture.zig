// src/native/vm_probe_fixture — deterministic in-kernel static ELF64
// fixtures for the CPL0 private-VM probe. Test data, not a second loader.
// Two variants share layout and differ only in designated file bytes.

const std = @import("std");
const user_elf = @import("user_elf");

pub const PAGE: u64 = user_elf.PAGE;
pub const HUGE: u64 = 2 * 1024 * 1024;
pub const FIXTURE_LEN: usize = 0x1400;

pub const ENTRY: u64 = 0x401FF100;
pub const RX_VADDR: u64 = ENTRY;
pub const RX_FILE_OFF: u64 = 0x200;
pub const RX_FILESZ: u64 = 0xF20;
pub const RX_MEMSZ: u64 = RX_FILESZ;

pub const RO_VADDR: u64 = 0x40202180;
pub const RO_FILE_OFF: u64 = 0x1200;
pub const RO_FILESZ: u64 = 0x40;
pub const RO_MEMSZ: u64 = RO_FILESZ;

pub const RW_VADDR: u64 = 0x40204030;
pub const RW_FILE_OFF: u64 = 0x1280;
pub const RW_FILESZ: u64 = 0x80;
pub const RW_MEMSZ: u64 = 0x200;
pub const NX_VADDR: u64 = RW_VADDR;

pub const CYCLE1_RO: u8 = 0xA1;
pub const CYCLE2_RO: u8 = 0xB2;
pub const CYCLE1_MARK: u8 = 0x11;
pub const CYCLE2_MARK: u8 = 0x22;
pub const RET: u8 = 0xC3;

pub const EXPECT_IMAGE_PAGES: u32 = 4;
pub const EXPECT_IMAGE_PTS: u32 = 2;
pub const EXPECT_STACK_PAGES: u32 = 16;
pub const EXPECT_STACK_PTS: u32 = 1;
pub const EXPECT_TABLE_PAGES: u32 = 6; // PML4+PDPT+PD+2 image PT+stack PT
pub const EXPECT_OWNED: u32 = EXPECT_IMAGE_PAGES + EXPECT_STACK_PAGES + EXPECT_TABLE_PAGES;

// Reviewed hosted-builder pins for native-vm-probe-v1. Stale bytes fail
// compile/tests until new pins are reviewed; do not invent replacements.
pub const CYCLE1_SHA256_HEX = "b9b1c7085cc32a99ff7127d83f845525115f4d0c57d67566c2521fa9681486b9";
pub const CYCLE2_SHA256_HEX = "f2bb6508933e81ba28e67fe968508db2c6888681a508019c8935f1b663d6c447";

pub const RX_PAGE0: u64 = RX_VADDR & ~(PAGE - 1);
pub const RX_PAGE1: u64 = (RX_VADDR + RX_FILESZ - 1) & ~(PAGE - 1);
pub const RO_PAGE: u64 = RO_VADDR & ~(PAGE - 1);
pub const RW_PAGE: u64 = RW_VADDR & ~(PAGE - 1);

pub fn rxPage0() u64 {
    return RX_PAGE0;
}
pub fn rxPage1() u64 {
    return RX_PAGE1;
}
pub fn roPage() u64 {
    return RO_PAGE;
}
pub fn rwPage() u64 {
    return RW_PAGE;
}

comptime {
    if (RX_VADDR < user_elf.IMAGE_LO or RW_VADDR + RW_MEMSZ > user_elf.IMAGE_HI)
        @compileError("fixture image window is outside the accepted user interval");
    if ((RX_VADDR / HUGE) == ((RX_VADDR + RX_MEMSZ - 1) / HUGE))
        @compileError("RX segment must span an image PT (2 MiB) boundary");
    if (EXPECT_OWNED != 26) @compileError("fixture owned-frame count must stay 26");
    if (FIXTURE_LEN != 5120) @compileError("fixture length must stay 5120");
    if (RX_PAGE0 == RX_PAGE1) @compileError("RX pages must be distinct across the PT boundary");
    if (CYCLE1_SHA256_HEX.len != 64 or CYCLE2_SHA256_HEX.len != 64)
        @compileError("fixture SHA256 pins must be 64 lowercase hex digits");
}

const EHDR: usize = user_elf.EHDR_SIZE;
const PHDR: usize = user_elf.PHDR_SIZE;

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

fn writeEhdr(buf: []u8) void {
    @memcpy(buf[0..4], "\x7fELF");
    w8(buf, 4, user_elf.ELFCLASS64);
    w8(buf, 5, user_elf.ELFDATA2LSB);
    w8(buf, 6, user_elf.EV_CURRENT);
    w8(buf, 7, user_elf.ELFOSABI_NONE);
    w8(buf, 8, 0);
    w16(buf, 16, user_elf.ET_EXEC);
    w16(buf, 18, user_elf.EM_X86_64);
    w32(buf, 20, 1);
    w64(buf, 24, ENTRY);
    w64(buf, 32, EHDR);
    w32(buf, 48, 0);
    w16(buf, 52, user_elf.EHDR_SIZE);
    w16(buf, 54, user_elf.PHDR_SIZE);
    w16(buf, 56, 4);
}

fn writePhdr(
    buf: []u8,
    index: usize,
    p_type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    filesz: u64,
    memsz: u64,
    palign: u64,
) void {
    const at = EHDR + index * PHDR;
    w32(buf, at + 0, p_type);
    w32(buf, at + 4, flags);
    w64(buf, at + 8, offset);
    w64(buf, at + 16, vaddr);
    w64(buf, at + 24, 0x11110000 + index);
    w64(buf, at + 32, filesz);
    w64(buf, at + 40, memsz);
    w64(buf, at + 48, palign);
}

fn make(comptime cycle: u8) [FIXTURE_LEN]u8 {
    @setEvalBranchQuota(20_000);
    var buf: [FIXTURE_LEN]u8 = [_]u8{0} ** FIXTURE_LEN;
    writeEhdr(&buf);
    writePhdr(&buf, 0, user_elf.PT_LOAD, user_elf.PF_R | user_elf.PF_X, RX_FILE_OFF, RX_VADDR, RX_FILESZ, RX_MEMSZ, 1);
    writePhdr(&buf, 1, user_elf.PT_LOAD, user_elf.PF_R, RO_FILE_OFF, RO_VADDR, RO_FILESZ, RO_MEMSZ, 1);
    writePhdr(&buf, 2, user_elf.PT_LOAD, user_elf.PF_R | user_elf.PF_W, RW_FILE_OFF, RW_VADDR, RW_FILESZ, RW_MEMSZ, 1);
    writePhdr(&buf, 3, user_elf.PT_GNU_STACK, user_elf.PF_R | user_elf.PF_W, 0, 0, 0, 0, 16);

    buf[RX_FILE_OFF] = RET;
    buf[RX_FILE_OFF + 1] = if (cycle == 1) CYCLE1_MARK else CYCLE2_MARK;
    var i: usize = 2;
    while (i < RX_FILESZ) : (i += 1) {
        buf[RX_FILE_OFF + i] = @truncate(0x90 + (i & 3));
    }

    const ro_byte: u8 = if (cycle == 1) CYCLE1_RO else CYCLE2_RO;
    buf[RO_FILE_OFF] = ro_byte;
    i = 1;
    while (i < RO_FILESZ) : (i += 1) {
        buf[RO_FILE_OFF + i] = @truncate(0x40 + i);
    }

    buf[RW_FILE_OFF] = RET;
    i = 1;
    while (i < RW_FILESZ) : (i += 1) {
        buf[RW_FILE_OFF + i] = @truncate(0x70 + i);
    }
    return buf;
}

pub const cycle1: [FIXTURE_LEN]u8 = make(1);
pub const cycle2: [FIXTURE_LEN]u8 = make(2);

pub fn bytes(cycle: u8) []const u8 {
    return switch (cycle) {
        1 => cycle1[0..],
        2 => cycle2[0..],
        else => cycle1[0..],
    };
}

pub fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    return std.fmt.bytesToHex(sha256(data), .lower);
}

pub fn cycleMarker(cycle: u8) u8 {
    return if (cycle == 1) CYCLE1_MARK else CYCLE2_MARK;
}

pub fn cycleRo(cycle: u8) u8 {
    return if (cycle == 1) CYCLE1_RO else CYCLE2_RO;
}

pub fn cyclePattern(cycle: u8) u8 {
    return if (cycle == 1) 0xC1 else 0xC2;
}

pub fn fileByte(data: []const u8, vaddr: u64, seg_vaddr: u64, file_off: u64, filesz: u64) ?u8 {
    if (vaddr < seg_vaddr) return null;
    const delta = vaddr - seg_vaddr;
    if (delta >= filesz) return null;
    const off: usize = @intCast(file_off + delta);
    if (off >= data.len) return null;
    return data[off];
}
