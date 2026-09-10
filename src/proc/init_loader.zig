// proc/init_loader — ELF init loader wired to /sbin/init path.
// Analog: kernel/init/main.c run_init_process() + fs/binfmt_elf.c load_elf()
// Loads ELF64 from VFS path, prints entry point. Falls back if file missing.
const std = @import("std");
const vfs = @import("../vfs/vfs.zig");
const printk = @import("../lib/printk.zig");
const elf = @import("elf.zig");

const INIT_PATH = "/sbin/init";

pub const LoadResult = struct {
    entry: u64,
    loaded: bool = false,
};

/// Attempt to load ELF from given path via VFS.
/// Returns LoadResult with loaded=true + entry on success,
/// loaded=false if file not found or invalid ELF.
pub fn load_init(path: []const u8) LoadResult {
    const file = vfs.open(path) orelse {
        printk.printk(.warn, "init: '{s}' not found (no ELF loaded)", .{path});
        return .{ .entry = 0, .loaded = false };
    };
    defer vfs.close(file);

    const entry = elf.loadELF(file, path) catch |err| {
        printk.printk(.err, "init: ELF load failed for '{s}': {any}", .{ path, err });
        return .{ .entry = 0, .loaded = false };
    };
    printk.printk(.info, "init: ELF loaded '{s}' -> entry=0x{x}", .{ path, entry });
    return .{ .entry = entry, .loaded = true };
}

test "init_loader: missing file returns not loaded" {
    const result = load_init("/no/such/file");
    try std.testing.expect(!result.loaded);
    try std.testing.expectEqual(@as(u64, 0), result.entry);
}

test "init_loader: hello.txt is not ELF" {
    vfs.init();
    const result = load_init("/hello.txt");
    // hello.txt is 33 bytes of text, not a valid ELF header.
    // loadELF will return InvalidElf -> loaded=false.
    try std.testing.expect(!result.loaded);
}
