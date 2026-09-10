// proc/capture — separate stdout/stderr capture buffers (M3).
// fd 1 → stdout, fd 2 → stderr. Bounded; overflow drops + counts.
// Hosted sim: buffers in memory. Baremetal/guest: same API over serial frames.
// ponytail: fixed caps; ceiling: host-streamed ring with backpressure.
pub const CAP: usize = 64 << 10; // 64 KiB per stream
pub const MAX_PROCS: usize = 64;

var out_buf: [MAX_PROCS][CAP]u8 = undefined;
var err_buf: [MAX_PROCS][CAP]u8 = undefined;
var out_len: [MAX_PROCS]usize = [_]usize{0} ** MAX_PROCS;
var err_len: [MAX_PROCS]usize = [_]usize{0} ** MAX_PROCS;
var out_dropped: [MAX_PROCS]usize = [_]usize{0} ** MAX_PROCS;
var err_dropped: [MAX_PROCS]usize = [_]usize{0} ** MAX_PROCS;

fn slot(pid: u32) usize {
    return @as(usize, @intCast(pid % MAX_PROCS));
}

pub fn writeStdout(pid: u32, data: []const u8) usize {
    const s = slot(pid);
    const room = if (out_len[s] < CAP) CAP - out_len[s] else 0;
    const n = @min(room, data.len);
    @memcpy(out_buf[s][out_len[s] .. out_len[s] + n], data[0..n]);
    out_len[s] += n;
    out_dropped[s] += data.len - n;
    return n;
}

pub fn writeStderr(pid: u32, data: []const u8) usize {
    const s = slot(pid);
    const room = if (err_len[s] < CAP) CAP - err_len[s] else 0;
    const n = @min(room, data.len);
    @memcpy(err_buf[s][err_len[s] .. err_len[s] + n], data[0..n]);
    err_len[s] += n;
    err_dropped[s] += data.len - n;
    return n;
}

pub fn stdoutOf(pid: u32) []const u8 {
    const s = slot(pid);
    return out_buf[s][0..out_len[s]];
}

pub fn stderrOf(pid: u32) []const u8 {
    const s = slot(pid);
    return err_buf[s][0..err_len[s]];
}

pub fn droppedOut(pid: u32) usize {
    return out_dropped[slot(pid)];
}

pub fn droppedErr(pid: u32) usize {
    return err_dropped[slot(pid)];
}

/// Reset capture for pid (exec/reset path).
pub fn reset(pid: u32) void {
    const s = slot(pid);
    out_len[s] = 0;
    err_len[s] = 0;
    out_dropped[s] = 0;
    err_dropped[s] = 0;
}

const std = @import("std");

test "capture: stdout/stderr stay separate" {
    reset(7);
    _ = writeStdout(7, "out-line\n");
    _ = writeStderr(7, "err-line\n");
    try std.testing.expectEqualStrings("out-line\n", stdoutOf(7));
    try std.testing.expectEqualStrings("err-line\n", stderrOf(7));
    try std.testing.expectEqual(@as(usize, 0), droppedOut(7));
    reset(7);
    try std.testing.expectEqual(@as(usize, 0), stdoutOf(7).len);
}

test "capture: overflow drops + counts" {
    reset(9);
    var i: usize = 0;
    while (i < CAP + 100) : (i += 1) {
        _ = writeStdout(9, "x");
    }
    try std.testing.expectEqual(CAP, stdoutOf(9).len);
    try std.testing.expectEqual(@as(usize, 100), droppedOut(9));
    try std.testing.expectEqual(@as(usize, 0), stderrOf(9).len);
    reset(9);
}
