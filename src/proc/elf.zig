// proc/elf — Minimal ELF loader (analog: fs/binfmt_elf.c)
// Loads a statically-linked ELF64 executable into memory and returns entry point.
const std = @import("std");
const mm = @import("../mm/mm.zig");
const vfs = @import("../vfs/vfs.zig");
const printk = @import("../lib/printk.zig");

const ELF_MAGIC: [4]u8 = .{ 0x7f, 'E', 'L', 'F' };

pub const Elf64Ehdr = struct {
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

pub const Elf64Phdr = struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

const PT_LOAD: u32 = 1;
const ELFCLASS64: u8 = 2;
const ELFDATA2LSB: u8 = 1;

pub fn loadELF(file: *vfs.File, path: []const u8) !u64 {
    // Read ELF header
    var hdr: Elf64Ehdr = undefined;
    const n = try vfs.pread(file, 0, @sizeOf(Elf64Ehdr), &hdr);
    if (n < @sizeOf(Elf64Ehdr)) return error.InvalidElf;
    if (hdr.e_ident[0..4] != ELF_MAGIC) return error.InvalidElf;
    if (hdr.e_ident[4] != ELFCLASS64) return error.InvalidElf;
    if (hdr.e_ident[5] != ELFDATA2LSB) return error.InvalidElf;

    printk.printk(.info, "elf: loading '{s}' e_entry=0x{x} phnum={d}", .{ path, hdr.e_entry, hdr.e_phnum });

    // Load each PT_LOAD segment
    var offset: u64 = hdr.e_phoff;
    var i: usize = 0;
    while (i < hdr.e_phnum) : (i += 1) {
        var phdr: Elf64Phdr = undefined;
        _ = try vfs.pread(file, offset, @sizeOf(Elf64Phdr), &phdr);

        if (phdr.p_type == PT_LOAD) {
            // Allocate pages for this segment
            const seg_start = alignDown(phdr.p_vaddr, mm.PAGE_SIZE);
            const seg_end = alignUp(phdr.p_vaddr + phdr.p_memsz, mm.PAGE_SIZE);
            const seg_size = seg_end - seg_start;

            printk.printk(.info, "elf: PT_LOAD vaddr=0x{x} filesz={d} memsz={d} -> 0x{x}..0x{x} ({d} bytes)",
                .{ phdr.p_vaddr, phdr.p_filesz, phdr.p_memsz, seg_start, seg_end, seg_size });

            // Allocate virtual pages (simplified: just allocate and map)
            const npages = seg_size / mm.PAGE_SIZE;
            var j: usize = 0;
            while (j < npages) : (j += 1) {
                _ = mm.allocPage();
            }

            // Copy file data into allocated memory (simplified for hosted sim)
            var buf: [1024]u8 = undefined;
            var src_offset = phdr.p_offset;
            var remaining = phdr.p_filesz;
            while (remaining > 0) {
                const to_copy = @min(remaining, buf.len);
                _ = try vfs.pread(file, src_offset, to_copy, &buf);
                src_offset += to_copy;
                remaining -= to_copy;
            }
        }

        offset += hdr.e_phentsize;
    }

    return hdr.e_entry;
}

fn alignDown(addr: u64, align_to: u64) u64 {
    return addr & ~(align_to - 1);
}

fn alignUp(addr: u64, align_to: u64) u64 {
    return alignDown(addr + align_to - 1, align_to);
}

// pread for vfs — read at offset without changing file position
fn pread(file: *vfs.File, offset: u64, len: usize, buf: []u8) !usize {
    return try vfs.pread(file, offset, len, buf);
}
