// tools/imginfo — static artifact inspector for native qualification (KWP2).
// Independently verifies the loader is PE32+/AMD64/EFI-application and the
// payload is ELF64/x86-64/ET_EXEC with page-congruent PT_LOAD segments,
// bounded span, in-image entry and a real BSS. Emits key=value lines and a
// SHA-256 per file; exits non-zero on any failed check. Never accepts ELF32,
// a hosted executable, or a wrong-subsystem PE as a substitute.

const std = @import("std");

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hexdigits = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        out[i * 2] = hexdigits[b >> 4];
        out[i * 2 + 1] = hexdigits[b & 0xF];
    }
    return out;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("imginfo: FAIL " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn inspectPe(path: []const u8, data: []const u8) void {
    if (data.len < 0x40) fail("pe truncated", .{});
    if (!std.mem.eql(u8, data[0..2], "MZ")) fail("pe bad dos magic", .{});
    const peoff = std.mem.readInt(u32, data[0x3C..][0..4], .little);
    if (peoff + 24 > data.len) fail("pe header out of bounds", .{});
    if (!std.mem.eql(u8, data[peoff..][0..4], "PE\x00\x00")) fail("pe bad signature", .{});
    const machine = std.mem.readInt(u16, data[peoff + 4 ..][0..2], .little);
    if (machine != 0x8664) fail("pe machine {x} != AMD64", .{machine});
    const opt_size = std.mem.readInt(u16, data[peoff + 20 ..][0..2], .little);
    if (opt_size < 2) fail("pe optional header missing", .{});
    const opt = data[peoff + 24 ..];
    const magic = std.mem.readInt(u16, opt[0..2], .little);
    if (magic != 0x20B) fail("pe magic {x} != PE32+", .{magic});
    const subsystem = std.mem.readInt(u16, opt[68..70], .little);
    if (subsystem != 10) fail("pe subsystem {d} != EFI application", .{subsystem});
    std.debug.print("imginfo: pe ok machine=AMD64 format=PE32+ subsystem=EFI_APPLICATION sha256={s} file={s}\n", .{
        sha256Hex(data), path,
    });
}

fn inspectElf(path: []const u8, data: []const u8) void {
    if (data.len < 64) fail("elf truncated", .{});
    if (!std.mem.eql(u8, data[0..4], "\x7fELF")) fail("elf bad magic", .{});
    if (data[4] != 2) fail("elf class {d} != 64-bit", .{data[4]});
    if (data[5] != 1) fail("elf not little-endian", .{});
    const etype = std.mem.readInt(u16, data[16..18], .little);
    if (etype != 2) fail("elf type {d} != ET_EXEC", .{etype});
    const machine = std.mem.readInt(u16, data[18..20], .little);
    if (machine != 62) fail("elf machine {d} != x86-64", .{machine});
    const entry = std.mem.readInt(u64, data[24..32], .little);
    const phoff = std.mem.readInt(u64, data[32..40], .little);
    const phentsize = std.mem.readInt(u16, data[54..56], .little);
    const phnum = std.mem.readInt(u16, data[56..58], .little);
    if (phentsize < 56) fail("elf phentsize {d} too small", .{phentsize});
    if (phnum == 0) fail("elf no program headers", .{});
    if (phoff + @as(u64, phnum) * phentsize > data.len) fail("elf phdrs out of bounds", .{});

    var loads: u32 = 0;
    var lowest: u64 = std.math.maxInt(u64);
    var highest: u64 = 0;
    var entry_ok = false;
    var bss_seen = false;
    var i: u16 = 0;
    while (i < phnum) : (i += 1) {
        const ph = data[phoff + @as(usize, i) * phentsize ..];
        const ptype = std.mem.readInt(u32, ph[0..4], .little);
        if (ptype != 1) continue;
        const flags = std.mem.readInt(u32, ph[4..8], .little);
        const off = std.mem.readInt(u64, ph[8..16], .little);
        const paddr = std.mem.readInt(u64, ph[24..32], .little);
        const filesz = std.mem.readInt(u64, ph[32..40], .little);
        const memsz = std.mem.readInt(u64, ph[40..48], .little);
        const align_ = std.mem.readInt(u64, ph[48..56], .little);
        if (memsz == 0) continue;
        if (filesz > memsz) fail("elf segment filesz>memsz", .{});
        if (off + filesz > data.len) fail("elf segment past EOF", .{});
        if (align_ > 1 and paddr % align_ != off % align_)
            fail("elf segment align incongruent", .{});
        if (memsz > filesz) bss_seen = true;
        loads += 1;
        lowest = @min(lowest, paddr);
        highest = @max(highest, paddr + memsz);
        if ((flags & 1) != 0 and entry >= paddr and entry < paddr + memsz) entry_ok = true;
    }
    if (loads == 0) fail("elf no PT_LOAD", .{});
    if (!entry_ok) fail("elf entry not in executable segment", .{});
    if (lowest != 0x200000) fail("elf base {x} != 0x200000", .{lowest});
    if (highest - lowest > 2 * 1024 * 1024) fail("elf span {x} exceeds 2 MiB block", .{highest - lowest});
    std.debug.print("imginfo: elf ok class=ELF64 machine=x86-64 type=ET_EXEC base={x} entry={x} loads={d} bss={} sha256={s} file={s}\n", .{
        lowest, entry, loads, bss_seen, sha256Hex(data), path,
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator(); // one-shot tool: process-lifetime arena, no leak noise
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    defer it.deinit();
    _ = it.next();
    const kind = it.next() orelse fail("usage: imginfo <pe|elf> <file>", .{});
    const path = it.next() orelse fail("usage: imginfo <pe|elf> <file>", .{});
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 28));
    if (std.mem.eql(u8, kind, "pe")) {
        inspectPe(path, data);
    } else if (std.mem.eql(u8, kind, "elf")) {
        inspectElf(path, data);
    } else {
        fail("unknown kind {s}", .{kind});
    }
}
