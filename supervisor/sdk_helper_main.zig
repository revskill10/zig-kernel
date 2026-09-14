//! Portable hosted stdin/stdout loop for the TS0 local SDK helper.
//!
//! Stdout is the private length-prefixed protocol only. Parent pipe EOF exits
//! the process. There is no TCP listener, socket, daemon, credential discovery,
//! VM launch, or persistent state.
const std = @import("std");
const helper = @import("sdk_helper");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
        .concurrent_limit = .limited(4),
    });
    defer threaded.deinit();
    const io = threaded.io();

    // Zig 0.16 Args.toSlice may reference several allocations and must not be
    // freed with a general-purpose allocator. Parse with the allocator iterator
    // and release it before the stdin serve loop.
    {
        var args_it = try init.args.iterateAllocator(gpa);
        defer args_it.deinit();
        _ = args_it.next();
        if (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help")) {
                try writeStderr(io, "usage: zig-sandbox-helper\nstdio length-prefixed utf-8 json protocol sdk-helper/1\n");
                return;
            }
            if (std.mem.eql(u8, arg, "--version")) {
                try writeStderr(io, helper.HELPER_NAME ++ " " ++ helper.HELPER_VERSION ++ "\n");
                return;
            }
            try writeStderr(io, "sdk-helper: unexpected argument\n");
            return error.InvalidArgument;
        }
    }

    serve(io) catch |err| switch (err) {
        error.CleanExit => return,
        error.Shutdown => return,
        else => {
            try writeStderr(io, "sdk-helper: fail_closed\n");
            return err;
        },
    };
}

const ServeError = error{
    CleanExit,
    Shutdown,
    Truncated,
    Oversize,
    Protocol,
} || std.Io.Cancelable || std.Io.Writer.Error || std.Io.Reader.Error;

fn serve(io: std.Io) ServeError!void {
    var in_buf: [helper.MAX_FRAME_BYTES + helper.HEADER_BYTES]u8 = undefined;
    var file_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const reader = &file_reader.interface;
    var session = helper.Session{};
    var response_buf: [helper.MAX_FRAME_BYTES]u8 = undefined;
    var frame_buf: [helper.MAX_FRAME_BYTES + helper.HEADER_BYTES]u8 = undefined;

    while (true) {
        const header = readHeader(reader) catch |err| switch (err) {
            error.CleanExit => return error.CleanExit,
            else => return err,
        };
        const len = helper.readFrameHeader(&header);
        if (len == 0 or len > helper.MAX_FRAME_BYTES) {
            try writeStderr(io, "sdk-helper: oversize_or_empty_frame\n");
            return error.Oversize;
        }
        const payload = reader.take(len) catch |err| switch (err) {
            error.EndOfStream => {
                try writeStderr(io, "sdk-helper: truncated_frame\n");
                return error.Truncated;
            },
            else => return err,
        };

        const outcome = helper.handlePayload(&session, &response_buf, payload);
        if (outcome.stderr_note.len != 0) {
            try writeStderr(io, "sdk-helper: ");
            try writeStderr(io, outcome.stderr_note);
            try writeStderr(io, "\n");
        }
        if (outcome.payload.len != 0) {
            const framed = helper.encodeFrame(&frame_buf, outcome.payload) catch {
                try writeStderr(io, "sdk-helper: response_too_large\n");
                return error.Protocol;
            };
            writeStdout(io, framed) catch return error.WriteFailed;
        }
        if (outcome.shutdown) return error.Shutdown;
        if (outcome.fail_closed) return error.Protocol;
    }
}

fn readHeader(reader: *std.Io.Reader) (error{ CleanExit, Truncated } || std.Io.Reader.Error)![helper.HEADER_BYTES]u8 {
    _ = reader.peek(helper.HEADER_BYTES) catch |err| switch (err) {
        error.EndOfStream => {
            const leftover = reader.end - reader.seek;
            if (leftover == 0) return error.CleanExit;
            return error.Truncated;
        },
        else => return err,
    };
    const taken = try reader.takeArray(helper.HEADER_BYTES);
    return taken.*;
}

fn writeStdout(io: std.Io, bytes: []const u8) std.Io.Writer.Error!void {
    if (bytes.len == 0) return;
    // Map the Zig 0.16 file-write error set onto Writer.Error so ServeError
    // stays fail-closed instead of leaking host-specific write codes.
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch return error.WriteFailed;
}

fn writeStderr(io: std.Io, bytes: []const u8) std.Io.Writer.Error!void {
    if (bytes.len == 0) return;
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch return error.WriteFailed;
}
