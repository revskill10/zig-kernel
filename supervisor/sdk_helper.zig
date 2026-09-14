//! Versioned private-pipe protocol dispatcher for the TS0 local SDK helper.
//!
//! Payload/status/error documents come from the public bootstrap route
//! function and sandbox_contract constants. This module does not launch a VM,
//! host tool, or workload, and it does not open sockets.
const std = @import("std");
const contract = @import("sandbox_contract");
const bootstrap = @import("sandbox_bootstrap");

pub const PROTOCOL_VERSION = "sdk-helper/1";
pub const HELPER_NAME = "zig-sandbox-helper";
pub const HELPER_VERSION = "0.1.0-ts0";
pub const MAX_FRAME_BYTES: usize = contract.MAX_JSON_BYTES;
pub const MAX_SEEN_IDS: usize = 32;
pub const HEADER_BYTES: usize = 4;

pub const Method = enum {
    hello,
    diagnostics,
    create_unavailable,
    shutdown,

    pub fn text(self: Method) []const u8 {
        return switch (self) {
            .hello => "hello",
            .diagnostics => "diagnostics",
            .create_unavailable => "create-unavailable",
            .shutdown => "shutdown",
        };
    }

    pub fn parse(s: []const u8) ?Method {
        if (std.mem.eql(u8, s, "hello")) return .hello;
        if (std.mem.eql(u8, s, "diagnostics")) return .diagnostics;
        if (std.mem.eql(u8, s, "create-unavailable")) return .create_unavailable;
        if (std.mem.eql(u8, s, "shutdown")) return .shutdown;
        return null;
    }
};

pub const Session = struct {
    seen: [MAX_SEEN_IDS]IdSlot = [_]IdSlot{.{}} ** MAX_SEEN_IDS,
    seen_len: usize = 0,
    shutting_down: bool = false,
    hello_done: bool = false,
};

const IdSlot = struct {
    bytes: [contract.MAX_ID_BYTES]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const IdSlot) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Outcome = struct {
    payload: []const u8 = &.{},
    shutdown: bool = false,
    fail_closed: bool = false,
    stderr_note: []const u8 = &.{},
};

const Request = struct {
    v: []const u8,
    id: []const u8,
    method: []const u8,
    params: ?struct {
        definition: ?std.json.Value = null,
    } = null,
};

fn jsonParseOptions() std.json.ParseOptions {
    return .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = contract.MAX_JSON_BYTES,
    };
}

fn jsonErrorCode(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "UnknownField")) return "unknown_field";
    if (std.mem.eql(u8, name, "DuplicateField")) return "duplicate_field";
    if (std.mem.eql(u8, name, "MissingField")) return "missing_field";
    if (std.mem.eql(u8, name, "TrailingData")) return "trailing_data";
    if (std.mem.eql(u8, name, "ValueTooLong") or std.mem.eql(u8, name, "Overflow") or std.mem.eql(u8, name, "OutOfMemory")) {
        return "payload_too_large";
    }
    return "malformed";
}

pub fn stripTrailingNewline(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return s[0 .. s.len - 1];
    return s;
}

pub fn writeFrameHeader(dest: *[HEADER_BYTES]u8, payload_len: u32) void {
    std.mem.writeInt(u32, dest, payload_len, .big);
}

pub fn readFrameHeader(src: *const [HEADER_BYTES]u8) u32 {
    return std.mem.readInt(u32, src, .big);
}

pub fn encodeFrame(dest: []u8, payload: []const u8) error{ FrameTooLarge, BufferTooSmall }![]const u8 {
    if (payload.len > MAX_FRAME_BYTES) return error.FrameTooLarge;
    if (dest.len < HEADER_BYTES + payload.len) return error.BufferTooSmall;
    writeFrameHeader(dest[0..HEADER_BYTES], @intCast(payload.len));
    @memcpy(dest[HEADER_BYTES..][0..payload.len], payload);
    return dest[0 .. HEADER_BYTES + payload.len];
}

fn rememberId(session: *Session, id: []const u8) error{ DuplicateId, TooManyIds }!void {
    var i: usize = 0;
    while (i < session.seen_len) : (i += 1) {
        if (std.mem.eql(u8, session.seen[i].slice(), id)) return error.DuplicateId;
    }
    if (session.seen_len == MAX_SEEN_IDS) {
        var j: usize = 1;
        while (j < MAX_SEEN_IDS) : (j += 1) session.seen[j - 1] = session.seen[j];
        session.seen_len = MAX_SEEN_IDS - 1;
    }
    var slot = &session.seen[session.seen_len];
    slot.len = id.len;
    @memcpy(slot.bytes[0..id.len], id);
    session.seen_len += 1;
}

fn echoId(id: []const u8) []const u8 {
    return if (contract.isOpaqueId(id)) id else "invalid";
}

fn writeError(buf: []u8, id: []const u8, code: []const u8, message: []const u8) []const u8 {
    const doc = struct {
        v: []const u8,
        id: []const u8,
        ok: bool,
        @"error": struct { code: []const u8, message: []const u8 },
    }{
        .v = PROTOCOL_VERSION,
        .id = echoId(id),
        .ok = false,
        .@"error" = .{ .code = code, .message = message },
    };
    var w = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(doc, .{}, &w) catch return buf[0..0];
    return w.buffered();
}

fn fail(buf: []u8, id: []const u8, code: []const u8, message: []const u8, note: []const u8) Outcome {
    return .{
        .payload = writeError(buf, id, code, message),
        .fail_closed = true,
        .stderr_note = note,
    };
}

pub fn handlePayload(session: *Session, buf: []u8, payload: []const u8) Outcome {
    if (payload.len == 0 or payload.len > MAX_FRAME_BYTES) {
        return fail(buf, "invalid", "payload_too_large", "frame exceeds helper limit", "oversize_or_empty");
    }
    if (!std.unicode.utf8ValidateSlice(payload)) {
        return fail(buf, "invalid", "malformed", "payload is not valid utf-8", "malformed_utf8");
    }

    var arena_buf: [contract.MAX_JSON_BYTES + 8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const parsed = std.json.parseFromSlice(Request, fba.allocator(), payload, jsonParseOptions()) catch |err| {
        const name = @errorName(err);
        const code: []const u8 = jsonErrorCode(name);
        return fail(buf, "invalid", code, "request json rejected", code);
    };
    defer parsed.deinit();
    const req = parsed.value;

    // Validate/replace the untrusted id before any error interpolation. The
    // rolling 32-id history is a diagnostic-only replay window, not session-wide
    // uniqueness; ids that fail this check are never remembered.
    if (!contract.isOpaqueId(req.id)) {
        return fail(buf, "invalid", "invalid_id", "request id is not a bounded opaque id", "invalid_id");
    }
    if (!std.mem.eql(u8, req.v, PROTOCOL_VERSION)) {
        return fail(buf, req.id, "version_mismatch", "helper protocol version mismatch", "version_mismatch");
    }
    rememberId(session, req.id) catch |err| switch (err) {
        error.DuplicateId => return fail(buf, req.id, "duplicate_id", "request id was already used", "duplicate_id"),
        error.TooManyIds => return fail(buf, req.id, "limit", "too many helper request ids", "too_many_ids"),
    };

    const method = Method.parse(req.method) orelse {
        return fail(buf, req.id, "unknown_method", "method is not in the helper allowlist", "unknown_method");
    };
    if (session.shutting_down) {
        return fail(buf, req.id, "shutdown", "session already shutting down", "already_shutdown");
    }
    if (method == .hello) {
        if (session.hello_done) {
            return fail(buf, req.id, "unexpected_hello", "hello already completed", "repeated_hello");
        }
    } else if (!session.hello_done) {
        return fail(buf, req.id, "hello_required", "first request must be hello", "hello_required");
    }
    if (method != .create_unavailable and req.params != null) {
        return fail(buf, req.id, "unknown_field", "params are not allowed for this method", "unexpected_params");
    }
    if (method == .hello) session.hello_done = true;

    return switch (method) {
        .hello => hello(buf, req.id),
        .diagnostics => diagnostics(buf, req.id),
        .create_unavailable => createUnavailable(buf, req.id),
        .shutdown => shutdown(session, buf, req.id),
    };
}

fn hello(buf: []u8, id: []const u8) Outcome {
    const payload = std.fmt.bufPrint(
        buf,
        "{{\"v\":\"{s}\",\"id\":\"{s}\",\"ok\":true,\"result\":{{\"protocol\":\"{s}\",\"contract_version\":\"{s}\",\"api_version\":\"{s}\",\"helper\":\"{s}\",\"helper_version\":\"{s}\"}}}}",
        .{
            PROTOCOL_VERSION,
            id,
            PROTOCOL_VERSION,
            contract.CONTRACT_VERSION,
            contract.API_VERSION,
            HELPER_NAME,
            HELPER_VERSION,
        },
    ) catch return fail(buf, id, "internal", "hello response exceeded buffer", "hello_overflow");
    return .{ .payload = payload };
}

fn diagnostics(buf: []u8, id: []const u8) Outcome {
    const health = bootstrap.route(.{}, .GET, "/healthz", null);
    const ready = bootstrap.route(.{}, .GET, "/readyz", null);
    const caps = bootstrap.route(.{}, .GET, "/v1/capabilities", null);
    const payload = std.fmt.bufPrint(
        buf,
        "{{\"v\":\"{s}\",\"id\":\"{s}\",\"ok\":true,\"result\":{{\"health\":{s},\"ready\":{s},\"capabilities\":{s},\"http\":{{\"health\":{d},\"ready\":{d},\"capabilities\":{d}}}}}}}",
        .{
            PROTOCOL_VERSION,
            id,
            stripTrailingNewline(health.body),
            stripTrailingNewline(ready.body),
            stripTrailingNewline(caps.body),
            health.status,
            ready.status,
            caps.status,
        },
    ) catch return fail(buf, id, "internal", "diagnostics response exceeded buffer", "diagnostics_overflow");
    return .{ .payload = payload };
}

fn createUnavailable(buf: []u8, id: []const u8) Outcome {
    const created = bootstrap.route(.{}, .POST, "/v1/sandboxes", null);
    const payload = std.fmt.bufPrint(
        buf,
        "{{\"v\":\"{s}\",\"id\":\"{s}\",\"ok\":true,\"result\":{{\"status\":{d},\"body\":{s}}}}}",
        .{
            PROTOCOL_VERSION,
            id,
            created.status,
            stripTrailingNewline(created.body),
        },
    ) catch return fail(buf, id, "internal", "create-unavailable response exceeded buffer", "create_overflow");
    return .{ .payload = payload };
}

fn shutdown(session: *Session, buf: []u8, id: []const u8) Outcome {
    session.shutting_down = true;
    const payload = std.fmt.bufPrint(
        buf,
        "{{\"v\":\"{s}\",\"id\":\"{s}\",\"ok\":true,\"result\":{{\"shutdown\":true}}}}",
        .{ PROTOCOL_VERSION, id },
    ) catch return fail(buf, id, "internal", "shutdown response exceeded buffer", "shutdown_overflow");
    return .{ .payload = payload, .shutdown = true };
}

pub fn capabilitiesDocument() []const u8 {
    return stripTrailingNewline(bootstrap.route(.{}, .GET, "/v1/capabilities", null).body);
}

pub fn executionUnavailableDocument() []const u8 {
    return stripTrailingNewline(bootstrap.route(.{}, .POST, "/v1/sandboxes", null).body);
}

test "hello and diagnostics use public route payload truth" {
    var session = Session{};
    var buf: [contract.MAX_JSON_BYTES]u8 = undefined;
    const hello_out = handlePayload(&session, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_hello\",\"method\":\"hello\"}");
    try std.testing.expect(!hello_out.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, hello_out.payload, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello_out.payload, contract.CONTRACT_VERSION) != null);

    const diag = handlePayload(&session, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_diag\",\"method\":\"diagnostics\"}");
    try std.testing.expect(!diag.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, diag.payload, "\"execution\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.payload, "\"ready\":503") != null);
    try std.testing.expect(std.mem.eql(u8, capabilitiesDocument(), stripTrailingNewline(contract.diagnostic_empty_capabilities_json)));
}

test "create-unavailable preserves bootstrap diagnostic envelope" {
    var session = Session{};
    var buf: [contract.MAX_JSON_BYTES]u8 = undefined;
    const hello_out = handlePayload(&session, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_create_hello\",\"method\":\"hello\"}");
    try std.testing.expect(!hello_out.fail_closed);
    const out = handlePayload(&session, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_create\",\"method\":\"create-unavailable\"}");
    try std.testing.expect(!out.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, out.payload, "\"status\":501") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.payload, "execution_unavailable") != null);
    try std.testing.expect(contract.isDiagnosticEnvelope(executionUnavailableDocument()));
    try std.testing.expect(!contract.isCanonicalEnvelope(executionUnavailableDocument()));
    try std.testing.expect(std.mem.indexOf(u8, out.payload, "\"request_id\"") == null);
}

test "reject unknown method, field, version, duplicate id, and numeric id" {
    var session = Session{};
    var buf: [contract.MAX_JSON_BYTES]u8 = undefined;
    const unknown = handlePayload(&session, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_u\",\"method\":\"exec\"}");
    try std.testing.expect(unknown.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, unknown.payload, "unknown_method") != null);

    var s2 = Session{};
    const extra = handlePayload(&s2, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_x\",\"method\":\"hello\",\"extra\":true}");
    try std.testing.expect(extra.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, extra.payload, "unknown_field") != null);

    var s3 = Session{};
    const ver = handlePayload(&s3, &buf, "{\"v\":\"sdk-helper/0\",\"id\":\"req_v\",\"method\":\"hello\"}");
    try std.testing.expect(ver.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, ver.payload, "version_mismatch") != null);

    var s4 = Session{};
    _ = handlePayload(&s4, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_dup\",\"method\":\"hello\"}");
    const dup = handlePayload(&s4, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_dup\",\"method\":\"diagnostics\"}");
    try std.testing.expect(dup.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, dup.payload, "duplicate_id") != null);

    var s5 = Session{};
    const numeric = handlePayload(&s5, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"12345\",\"method\":\"hello\"}");
    try std.testing.expect(numeric.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, numeric.payload, "invalid_id") != null);
}

test "shutdown is bounded and hello rejects params" {
    var session = Session{};
    var buf: [contract.MAX_JSON_BYTES]u8 = undefined;
    const hello_out = handlePayload(&session, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_off_hello\",\"method\":\"hello\"}");
    try std.testing.expect(!hello_out.fail_closed);
    const out = handlePayload(&session, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_off\",\"method\":\"shutdown\"}");
    try std.testing.expect(out.shutdown);
    try std.testing.expect(!out.fail_closed);
    try std.testing.expect(session.shutting_down);

    var s2 = Session{};
    const params = handlePayload(&s2, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_p\",\"method\":\"hello\",\"params\":{}}");
    try std.testing.expect(params.fail_closed);
}

test "hello is required first and cannot repeat" {
    var session = Session{};
    var buf: [contract.MAX_JSON_BYTES]u8 = undefined;
    const before = handlePayload(&session, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_before\",\"method\":\"diagnostics\"}");
    try std.testing.expect(before.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, before.payload, "hello_required") != null);

    var s2 = Session{};
    const first = handlePayload(&s2, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_h1\",\"method\":\"hello\"}");
    try std.testing.expect(!first.fail_closed);
    const second = handlePayload(&s2, &buf, "{\"v\":\"sdk-helper/1\",\"id\":\"req_h2\",\"method\":\"hello\"}");
    try std.testing.expect(second.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, second.payload, "unexpected_hello") != null);
}

test "hostile id is replaced before error json and remains valid json" {
    var session = Session{};
    var buf: [contract.MAX_JSON_BYTES]u8 = undefined;
    const payload = "{\"v\":\"sdk-helper/0\",\"id\":\"x\\u0022y\\n\",\"method\":\"hello\"}";
    const out = handlePayload(&session, &buf, payload);
    try std.testing.expect(out.fail_closed);
    try std.testing.expect(std.mem.indexOf(u8, out.payload, "invalid_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.payload, "x") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.payload, "\n") == null);
    var parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.payload, .{}) catch {
        return error.InvalidErrorJson;
    };
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const id = parsed.value.object.get("id") orelse return error.MissingId;
    try std.testing.expect(id == .string);
    try std.testing.expectEqualStrings("invalid", id.string);
}

test "frame encode rejects oversize and roundtrips header" {
    var dest: [16]u8 = undefined;
    const framed = try encodeFrame(&dest, "abcd");
    try std.testing.expectEqual(@as(usize, 8), framed.len);
    try std.testing.expectEqual(@as(u32, 4), readFrameHeader(framed[0..4]));
    try std.testing.expect(std.mem.eql(u8, framed[4..], "abcd"));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encodeFrame(&tiny, "ab"));
    var huge: [MAX_FRAME_BYTES + 1]u8 = undefined;
    huge[0] = 'x';
    try std.testing.expectError(error.FrameTooLarge, encodeFrame(&dest, huge[0..]));
}
