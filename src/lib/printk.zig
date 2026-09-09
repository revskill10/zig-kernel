// lib/printk — kernel printk → dmesg → serial analog. Hosted: stdout.
const std = @import("std");

pub const Level = enum { emerg, alert, crit, err, warn, notice, info, debug };

pub fn printk(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    const prefix = switch (level) {
        .emerg => "[EMERG]", .alert => "[ALERT]", .crit => "[CRIT]", .err => "[ERR]",
        .warn => "[WARN]", .notice => "[NOTE]", .info => "[INFO]", .debug => "[DEBUG]",
    };
    std.debug.print(prefix ++ " " ++ fmt ++ "\n", args);
}

pub fn hexdump(tag: []const u8, data: []const u8) void {
    std.debug.print("{s} ({d} bytes): ", .{ tag, data.len });
    for (data) |b| std.debug.print("{x:0>2} ", .{b});
    std.debug.print("\n", .{});
}
