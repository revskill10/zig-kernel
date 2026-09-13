//! Linux TCP listener for the deliberately unavailable sandbox API bootstrap.
const std = @import("std");
const bootstrap = @import("bootstrap.zig");

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
        .concurrent_limit = .limited(64),
    });
    defer threaded.deinit();
    const io = threaded.io();
    const args = try init.args.toSlice(gpa);
    defer gpa.free(args);
    const config = parseArgs(args) catch |err| switch (err) {
        error.HelpRequested => {
            try std.Io.File.stdout().writeStreamingAll(io, "usage: zig-sandbox serve [--host=127.0.0.1] [--port=8080]\n");
            return;
        },
        error.VersionRequested => {
            try std.Io.File.stdout().writeStreamingAll(io, "zig-sandbox 0.1.0\n");
            return;
        },
        else => return err,
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = try std.Io.net.Ip4Address.parse(config.host, config.port) };
    var server = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 64 });
    defer server.deinit(io);
    std.debug.print("zig-sandbox listening on http://{f}\n", .{server.socket.address});

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("accept failed: {t}\n", .{err});
            continue;
        };
        group.concurrent(io, serveConnection, .{ io, stream }) catch {
            stream.close(io);
        };
    }
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var first: usize = 1;
    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) first = 2;
    for (args[first..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--host=")) {
            config.host = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            config.port = std.fmt.parseInt(u16, arg[7..], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return error.VersionRequested;
        } else return error.InvalidArgument;
    }
    if (config.host.len == 0) return error.InvalidHost;
    return config;
}

fn serveConnection(io: std.Io, stream: std.Io.net.Stream) std.Io.Cancelable!void {
    defer {
        var owned = stream;
        owned.close(io);
    }
    var receive_buffer: [bootstrap.MAX_HEADER_BYTES]u8 = undefined;
    const headers = readHeaders(io, stream.socket.handle, &receive_buffer) catch |err| {
        writeMalformed(io, stream.socket.handle, if (err == error.HeaderTooLarge) 431 else 400) catch {};
        return;
    };
    const request = std.http.Server.Request.Head.parse(headers) catch {
        writeMalformed(io, stream.socket.handle, 400) catch {};
        return;
    };
    const response = bootstrap.route(.{}, request.method, request.target, request.content_length);
    writeResponse(io, stream.socket.handle, response, request.method) catch {};
}

const REQUEST_TIMEOUT_MS: i32 = 5_000;

fn readHeaders(io: std.Io, fd: std.posix.socket_t, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .{ .nanoseconds = @as(i96, REQUEST_TIMEOUT_MS) * std.time.ns_per_ms },
        .clock = .awake,
    });
    while (used < buffer.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const remaining_ms: i96 = @divFloor(deadline.durationFromNow(io).raw.nanoseconds, std.time.ns_per_ms);
        if (remaining_ms <= 0) return error.Timeout;
        const ready = try std.posix.poll(&fds, @intCast(remaining_ms));
        if (ready == 0) return error.Timeout;
        const n = try std.posix.read(fd, buffer[used..]);
        if (n == 0) return error.EndOfStream;
        used += n;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |end| return buffer[0 .. end + 4];
    }
    return error.HeaderTooLarge;
}

fn writeAll(io: std.Io, fd: std.posix.socket_t, bytes: []const u8) !void {
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .{ .nanoseconds = @as(i96, REQUEST_TIMEOUT_MS) * std.time.ns_per_ms },
        .clock = .awake,
    });
    var sent: usize = 0;
    while (sent < bytes.len) {
        const remaining_ms: i96 = @divFloor(deadline.durationFromNow(io).raw.nanoseconds, std.time.ns_per_ms);
        if (remaining_ms <= 0) return error.Timeout;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
        if (try std.posix.poll(&fds, @intCast(remaining_ms)) == 0) return error.Timeout;
        const rc = std.os.linux.sendto(fd, bytes[sent..].ptr, bytes.len - sent, std.posix.MSG.NOSIGNAL | std.posix.MSG.DONTWAIT, null, 0);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteFailed;
                sent += n;
            },
            .INTR, .AGAIN => continue,
            else => return error.WriteFailed,
        }
    }
}

fn writeResponse(io: std.Io, fd: std.posix.socket_t, response: bootstrap.Response, method: std.http.Method) !void {
    var header: [512]u8 = undefined;
    const allow = response.allow orelse "";
    const allow_header = if (response.allow == null) "" else try std.fmt.bufPrint(&header, "allow: {s}\r\n", .{allow});
    var prefix: [512]u8 = undefined;
    const head = try std.fmt.bufPrint(&prefix, "HTTP/1.1 {d} {s}\r\ncontent-type: application/json\r\ncache-control: no-store\r\nconnection: close\r\ncontent-length: {d}\r\n{s}\r\n", .{ response.status, reason(response.status), response.body.len, allow_header });
    try writeAll(io, fd, head);
    if (method != .HEAD) try writeAll(io, fd, response.body);
}

fn reason(status: u16) []const u8 {
    return switch (status) { 200 => "OK", 400 => "Bad Request", 404 => "Not Found", 405 => "Method Not Allowed", 413 => "Payload Too Large", 431 => "Request Header Fields Too Large", 501 => "Not Implemented", 503 => "Service Unavailable", else => "Internal Server Error" };
}

fn writeMalformed(io: std.Io, fd: std.posix.socket_t, status: u16) !void {
    const body = "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid or oversized request headers\"}}\n";
    try writeResponse(io, fd, .{ .status = status, .body = body }, .GET);
}
