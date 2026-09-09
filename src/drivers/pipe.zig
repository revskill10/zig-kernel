// drivers/pipe — Pipe subsystem (analog: fs/pipe.c)
// Circular buffer pipe implementation with poll support
const std = @import("std");
const printk = @import("../lib/printk.zig");
const vfs = @import("../vfs/vfs.zig");

pub const PIPE_BUF: usize = 4096;
pub const POLLIN: i16 = 0x01;
pub const POLLOUT: i16 = 0x04;
pub const POLLERR: i16 = 0x08;
pub const POLLHUP: i16 = 0x10;

pub const Pipe = struct {
    data: [PIPE_BUF]u8 = [_]u8{0} ** PIPE_BUF,
    read_pos: usize = 0,
    write_pos: usize = 0,
    used: usize = 0,
    read_closed: bool = false,
    write_closed: bool = false,
    // Simple polling support
    wait_readers: bool = false,
    wait_writers: bool = false,
};

const MAX_PIPES: usize = 16;
var pipes: [MAX_PIPES]?Pipe = [_]?Pipe{null} ** MAX_PIPES;

pub fn init() void {
    for (&pipes) |*slot| slot.* = null;
    printk.printk(.info, "pipe: subsystem ready (PIPE_BUF={d}, max_pipes={d})", .{ PIPE_BUF, MAX_PIPES });
}

fn allocPipe() ?*Pipe {
    for (0..pipes.len) |i| {
        if (pipes[i] == null) {
            pipes[i] = Pipe{};
            return &pipes[i].?;
        }
    }
    return null;
}

pub fn pipe(fds: *[2]i32, flags: u32) i32 {
    _ = flags;
    const p = allocPipe() orelse return -24; // -EMFILE
    // Create two file descriptors pointing to the same pipe
    const read_file = vfs.openFileFromPipe(p, true) orelse return -24;
    const write_file = vfs.openFileFromPipe(p, false) orelse return -24;
    const read_fd = vfs.allocFd(read_file) orelse return -24;
    const write_fd = vfs.allocFd(write_file) orelse return -24;
    fds[0] = @intCast(read_fd);
    fds[1] = @intCast(write_fd);
    println("[INFO] pipe: created read_fd={d} write_fd={d}\n", .{ read_fd, write_fd });
    return 0;
}

pub fn read(p: *Pipe, buf: []u8) isize {
    if (p.used == 0) {
        if (p.write_closed) return 0; // EOF
        return -11; // -EAGAIN
    }
    const n = @min(buf.len, p.used);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = p.data[p.read_pos];
        p.read_pos = (p.read_pos + 1) % PIPE_BUF;
        p.used -= 1;
    }
    p.wait_writers = false;
    return @intCast(n);
}

pub fn write(p: *Pipe, data: []const u8) isize {
    if (p.read_closed) return -32; // -EPIPE
    const avail = PIPE_BUF - p.used;
    const n = @min(data.len, avail);
    if (n == 0) return -11; // -EAGAIN (pipe full)
    var i: usize = 0;
    while (i < n) : (i += 1) {
        p.data[p.write_pos] = data[i];
        p.write_pos = (p.write_pos + 1) % PIPE_BUF;
        p.used += 1;
    }
    p.wait_readers = true;
    return @intCast(n);
}

pub fn close(p: *Pipe, is_read_end: bool) void {
    if (is_read_end) {
        p.read_closed = true;
    } else {
        p.write_closed = true;
    }
}

pub fn poll(p: *Pipe, events: i16, is_read_end: bool) i16 {
    var revents: i16 = 0;
    if (is_read_end) {
        if (p.used > 0) revents |= POLLIN;
        if (p.write_closed) revents |= POLLHUP;
    } else {
        if (p.used < PIPE_BUF) revents |= POLLOUT;
        if (p.read_closed) revents |= POLLERR;
    }
    _ = events;
    return revents;
}

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
