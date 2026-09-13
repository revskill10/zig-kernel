// tests/native-elf/check.zig — independent N4 acceptance gate for the
// identity/bounded ELF64 load contract. It imports the named `elf64` module, so
// it is NOT runnable via a bare `zig test tests/native-elf/check.zig`; run it
// with the module wired on the CLI (or once root wires it into build.zig per
// N5):
//   zig test --dep elf64 -Mroot=tests/native-elf/check.zig \
//       -Melf64=boot/uefi/elf64.zig \
//       --cache-dir <task>/hy3-cache --global-cache-dir <task>/hy3-global-cache

const std = @import("std");
const elf = @import("elf64");

// Phdr field offsets within the first (text) program header.
const ph0_vaddr: u64 = @sizeOf(elf.Ehdr) + 16;
const ph0_paddr: u64 = @sizeOf(elf.Ehdr) + 24;
const ph0_filesz: u64 = @sizeOf(elf.Ehdr) + 32;
const ph0_memsz: u64 = @sizeOf(elf.Ehdr) + 40;
// Second (data) program header.
const ph1_vaddr: u64 = @sizeOf(elf.Ehdr) + @sizeOf(elf.Phdr) + 16;
const ph1_paddr: u64 = @sizeOf(elf.Ehdr) + @sizeOf(elf.Phdr) + 24;
const ph1_filesz: u64 = @sizeOf(elf.Ehdr) + @sizeOf(elf.Phdr) + 32;
const ph1_memsz: u64 = @sizeOf(elf.Ehdr) + @sizeOf(elf.Phdr) + 40;

test "n4: identity, span and entry contract" {
    const a = std.testing.allocator;

    // Non-identity load rejected.
    {
        var fb = elf.FixtureBuilder.init();
        defer fb.deinit(a);
        const b = try fb.minimal(a, 0x200000);
        fb.poke(u64, ph0_vaddr, 0x200000 + 0x1000);
        try std.testing.expectError(error.IdentityMismatch, elf.plan(b, 0x200000));
    }

    // Exact 2 MiB span accepted; one past rejected.
    {
        var fb = elf.FixtureBuilder.init();
        defer fb.deinit(a);
        const b = try fb.minimal(a, 0x200000);
        fb.poke(u64, ph1_filesz, 0);
        fb.poke(u64, ph1_memsz, 0);
        fb.poke(u64, ph0_filesz, 0x40);
        fb.poke(u64, ph0_memsz, elf.MAX_KERNEL_SPAN);
        const p = try elf.plan(b, 0x200000);
        try std.testing.expectEqual(@as(u64, elf.MAX_KERNEL_SPAN), p.span);
        try std.testing.expect(p.end <= 0x200000 + elf.MAX_KERNEL_SPAN);
    }
    {
        var fb = elf.FixtureBuilder.init();
        defer fb.deinit(a);
        const b = try fb.minimal(a, 0x200000);
        fb.poke(u64, ph1_filesz, 0);
        fb.poke(u64, ph1_memsz, 0);
        fb.poke(u64, ph0_filesz, 0x40);
        fb.poke(u64, ph0_memsz, elf.MAX_KERNEL_SPAN + 1);
        try std.testing.expectError(error.SpanTooLarge, elf.plan(b, 0x200000));
    }

    // Entry at the window edge is not in the file-backed executable range.
    {
        var fb = elf.FixtureBuilder.init();
        defer fb.deinit(a);
        const b = try fb.minimal(a, 0x200000);
        fb.poke(u64, ph1_filesz, 0);
        fb.poke(u64, ph1_memsz, 0);
        fb.poke(u64, ph0_filesz, 0x40);
        fb.poke(u64, ph0_memsz, elf.MAX_KERNEL_SPAN);
        fb.poke(u64, 24, 0x200000 + elf.MAX_KERNEL_SPAN);
        try std.testing.expectError(error.EntryNotFileBacked, elf.plan(b, 0x200000));
    }

    // Entry in the BSS tail of an executable segment is rejected.
    {
        var fb = elf.FixtureBuilder.init();
        defer fb.deinit(a);
        const b = try fb.minimal(a, 0x200000);
        fb.poke(u64, ph1_filesz, 0);
        fb.poke(u64, ph1_memsz, 0);
        fb.poke(u64, ph0_filesz, 0); // text has no file bytes
        fb.poke(u64, ph0_memsz, 0x1000);
        try std.testing.expectError(error.EntryNotFileBacked, elf.plan(b, 0x200000));
    }

    // Zero-file large-BSS: entry stays in file-backed text; data segment is pure
    // BSS (filesz 0, memsz 0x1000) and must be zeroed by execute().
    {
        var fb = elf.FixtureBuilder.init();
        defer fb.deinit(a);
        const b = try fb.minimal(a, 0x200000);
        fb.poke(u64, ph0_filesz, 0x40);
        fb.poke(u64, ph0_memsz, 0x40);
        fb.poke(u64, ph1_filesz, 0);
        fb.poke(u64, ph1_memsz, 0x1000);
        const p = try elf.plan(b, 0x200000);
        var dest: [0x2000]u8 = undefined;
        @memset(&dest, 0xAA);
        elf.execute(&p, b, &dest);
        try std.testing.expectEqual(@as(u8, 0x90), dest[0]); // text copied
        try std.testing.expectEqual(@as(u8, 0), dest[0x1000]); // BSS zeroed
    }
}
