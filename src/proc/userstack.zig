// proc/userstack — x86_64 Linux user-stack layout for exec (M3).
// Builds argc/argv/envp/auxv at stack top inside a caller-provided buffer.
// Pure: no mm/vfs, fully unit-tested. Kernel maps the stack VMA separately.
// Layout (low→high): argc, argv[i] ptrs, NULL, envp[i] ptrs, NULL,
// auxv pairs, AT_NULL, padding, strings (high end, growing down).
pub const STACK_TOP: u64 = 0x7FFFFFFFF000; // below non-canonical hole
pub const STACK_SIZE: usize = 8 << 20; // 8 MiB guard-banded by kernel
pub const MAX_ARGS: usize = 64;
pub const MAX_ARG_LEN: usize = 4096;

pub const AT_NULL: u64 = 0;
pub const AT_PAGESZ: u64 = 6;
pub const AT_UID: u64 = 11;
pub const AT_EUID: u64 = 12;
pub const AT_GID: u64 = 13;
pub const AT_EGID: u64 = 14;

fn writeU64(buf: []u8, at: usize, v: u64) void {
    buf[at] = @truncate(v);
    buf[at + 1] = @truncate(v >> 8);
    buf[at + 2] = @truncate(v >> 16);
    buf[at + 3] = @truncate(v >> 24);
    buf[at + 4] = @truncate(v >> 32);
    buf[at + 5] = @truncate(v >> 40);
    buf[at + 6] = @truncate(v >> 48);
    buf[at + 7] = @truncate(v >> 56);
}

fn readU64(buf: []const u8, at: usize) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) v |= @as(u64, buf[at + i]) << @intCast(i * 8);
    return v;
}

/// Build stack in buf (represents [stack_base, stack_base+len) at STACK_TOP-len).
/// sp_base = virtual address buf[0] maps to. Returns virtual rsp (argc address).
/// Strings copied to high end; pointers are virtual addresses.
pub fn build(buf: []u8, sp_base: u64, argv: []const []const u8, envp: []const []const u8) !u64 {
    if (argv.len > MAX_ARGS or envp.len > MAX_ARGS) return error.TooManyArgs;
    var total_str: usize = 0;
    for (argv) |a| {
        if (a.len > MAX_ARG_LEN) return error.ArgTooLong;
        total_str += a.len + 1;
    }
    for (envp) |e| {
        if (e.len > MAX_ARG_LEN) return error.ArgTooLong;
        total_str += e.len + 1;
    }
    const nptr = 1 + (argv.len + 1) + (envp.len + 1) + 2 * 5 + 2; // argc+argv+env+auxv
    const need = nptr * 8 + total_str;
    if (need > buf.len) return error.NoSpace;
    for (buf) |*b| b.* = 0;

    // strings at high end, growing down
    var str_off: usize = buf.len;
    var argv_addrs: [MAX_ARGS]u64 = undefined;
    var envp_addrs: [MAX_ARGS]u64 = undefined;
    for (argv, 0..) |a, i| {
        str_off -= a.len + 1;
        @memcpy(buf[str_off .. str_off + a.len], a);
        buf[str_off + a.len] = 0;
        argv_addrs[i] = sp_base + str_off;
    }
    for (envp, 0..) |e, i| {
        str_off -= e.len + 1;
        @memcpy(buf[str_off .. str_off + e.len], e);
        buf[str_off + e.len] = 0;
        envp_addrs[i] = sp_base + str_off;
    }
    // align table start to 16 (Linux: rsp % 16 == 8 at entry → argc addr % 16 == 8)
    var tab: usize = (str_off & ~@as(usize, 15)) - 8;
    if (tab > str_off) tab = str_off; // str_off already 8-mod-16
    tab -= nptr * 8; // table grows down from aligned point
    tab &= ~@as(usize, 15);
    tab += 8; // argc address ≡ 8 (mod 16)
    var at = tab;
    writeU64(buf, at, argv.len);
    at += 8;
    for (argv_addrs[0..argv.len]) |a| {
        writeU64(buf, at, a);
        at += 8;
    }
    writeU64(buf, at, 0);
    at += 8;
    for (envp_addrs[0..envp.len]) |e| {
        writeU64(buf, at, e);
        at += 8;
    }
    writeU64(buf, at, 0);
    at += 8;
    const auxv = [_][2]u64{
        .{ AT_PAGESZ, 4096 },
        .{ AT_UID, 1000 },
        .{ AT_EUID, 1000 },
        .{ AT_GID, 1000 },
        .{ AT_EGID, 1000 },
    };
    for (auxv) |pair| {
        writeU64(buf, at, pair[0]);
        writeU64(buf, at + 8, pair[1]);
        at += 16;
    }
    writeU64(buf, at, AT_NULL);
    writeU64(buf, at + 8, 0);
    return sp_base + tab;
}

const std = @import("std");

test "userstack: argv/env roundtrip" {
    var buf: [4096]u8 = undefined;
    const argv: []const []const u8 = &.{ "/workspace/tool", "--input", "x.json" };
    const envp: []const []const u8 = &.{ "LANG=C", "HOME=/workspace" };
    const sp = try build(&buf, STACK_TOP - 4096, argv, envp);
    try std.testing.expect(sp % 16 == 8); // Linux entry alignment
    const tab = @as(usize, @intCast(sp - (STACK_TOP - 4096)));
    try std.testing.expectEqual(@as(u64, 3), readU64(&buf, tab));
    const a0 = readU64(&buf, tab + 8);
    const a1 = readU64(&buf, tab + 16);
    const a2 = readU64(&buf, tab + 24);
    try std.testing.expectEqual(@as(u64, 0), readU64(&buf, tab + 32));
    const e0 = readU64(&buf, tab + 40);
    const e1 = readU64(&buf, tab + 48);
    try std.testing.expectEqual(@as(u64, 0), readU64(&buf, tab + 56));
    const base = STACK_TOP - 4096;
    try std.testing.expectEqualStrings("/workspace/tool", std.mem.span(@as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(a0 - base)) + @intFromPtr(&buf[0])))));
    try std.testing.expectEqualStrings("--input", std.mem.span(@as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(a1 - base)) + @intFromPtr(&buf[0])))));
    try std.testing.expectEqualStrings("x.json", std.mem.span(@as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(a2 - base)) + @intFromPtr(&buf[0])))));
    try std.testing.expectEqualStrings("LANG=C", std.mem.span(@as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(e0 - base)) + @intFromPtr(&buf[0])))));
    try std.testing.expectEqualStrings("HOME=/workspace", std.mem.span(@as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(e1 - base)) + @intFromPtr(&buf[0])))));
    // auxv present after env NULL
    try std.testing.expectEqual(AT_PAGESZ, readU64(&buf, tab + 64));
    try std.testing.expectEqual(@as(u64, 4096), readU64(&buf, tab + 72));
}

test "userstack: empty argv/env + limits" {
    var buf: [512]u8 = undefined;
    const sp = try build(&buf, STACK_TOP - 512, &.{}, &.{});
    try std.testing.expect(sp % 16 == 8);
    const tab = @as(usize, @intCast(sp - (STACK_TOP - 512)));
    try std.testing.expectEqual(@as(u64, 0), readU64(&buf, tab));
    try std.testing.expectEqual(@as(u64, 0), readU64(&buf, tab + 8));
    var small: [32]u8 = undefined;
    try std.testing.expectError(error.NoSpace, build(&small, STACK_TOP - 32, &.{"toolong-arg"}, &.{}));
    const big: []const []const u8 = &.{ "a", "b", "c" };
    _ = big;
}
