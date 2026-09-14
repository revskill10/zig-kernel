//! Independent AP0/AP1 contract fixtures. Expected values are the files under
//! fixtures/, not a snapshot of the serializer.
const std = @import("std");
const contract = @import("sandbox_contract");
const bootstrap = @import("sandbox_bootstrap");
const engine = @import("sandbox_engine");
const openapi_spec = @import("openapi_spec");

fn eachDataLine(bytes: []const u8, handler: anytype) !void {
    var start: usize = 0;
    while (start <= bytes.len) {
        const nl = indexOfPos(bytes, start, '\n') orelse bytes.len;
        var line = bytes[start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len != 0 and line[0] != '#') try handler(line);
        if (nl == bytes.len) break;
        start = nl + 1;
    }
}

fn indexOfPos(hay: []const u8, start: usize, c: u8) ?usize {
    var i = start;
    while (i < hay.len) : (i += 1) if (hay[i] == c) return i;
    return null;
}

fn splitN(line: []const u8, sep: u8, out: [][]const u8) !usize {
    var n: usize = 0;
    var start: usize = 0;
    while (n < out.len) {
        const idx = indexOfPos(line, start, sep);
        if (idx) |i| {
            out[n] = line[start..i];
            n += 1;
            start = i + 1;
        } else {
            out[n] = line[start..];
            return n + 1;
        }
    }
    return error.TooManyFields;
}

test "fixture decimal accepts match the contract parser" {
    const bytes = @embedFile("fixtures/decimal_u64.accept.txt");
    const Handler = struct {
        fn go(line: []const u8) anyerror!void {
            _ = try contract.parseDecimalU64(line);
        }
    };
    try eachDataLine(bytes, Handler.go);
}

test "decimal parser inclusive u64 bound rejects max plus one and twenty nines" {
    try std.testing.expect(contract.isCanonicalDecimalU64("18446744073709551615"));
    try std.testing.expect(contract.isCanonicalDecimalU64("9999999999999999999"));
    try std.testing.expect(contract.isCanonicalDecimalU64("10000000000000000000"));
    try std.testing.expectError(error.InvalidDecimalU64, contract.parseDecimalU64("18446744073709551616"));
    try std.testing.expectError(error.InvalidDecimalU64, contract.parseDecimalU64("18999999999999999999"));
    try std.testing.expectError(error.InvalidDecimalU64, contract.parseDecimalU64("99999999999999999999"));
}

test "fixture decimal rejects match the contract parser" {
    const bytes = @embedFile("fixtures/decimal_u64.reject.txt");
    const Handler = struct {
        fn go(line: []const u8) anyerror!void {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.BadFixture;
            const value = line[0..tab];
            const reason = line[tab + 1 ..];
            try std.testing.expectError(error.InvalidDecimalU64, contract.parseDecimalU64(value));
            try std.testing.expect(reason.len != 0);
        }
    };
    try eachDataLine(bytes, Handler.go);
}

test "diagnostic capabilities fixture matches the served bootstrap document" {
    const fixture = std.mem.trim(u8, @embedFile("fixtures/capabilities.diagnostic.json"), " \r\n");
    const served = std.mem.trim(u8, contract.diagnostic_empty_capabilities_json, " \r\n");
    try std.testing.expect(std.mem.eql(u8, fixture, served));
}

test "diagnostic and canonical error fixtures are different envelopes" {
    const diagnostic = std.mem.trim(u8, @embedFile("fixtures/error.diagnostic.execution_unavailable.json"), " \r\n");
    const canonical = std.mem.trim(u8, @embedFile("fixtures/error.canonical.unsupported.json"), " \r\n");
    try std.testing.expect(contract.isDiagnosticEnvelope(diagnostic));
    try std.testing.expect(!contract.isCanonicalEnvelope(diagnostic));
    try std.testing.expect(contract.isCanonicalEnvelope(canonical));
    try std.testing.expect(!contract.isDiagnosticEnvelope(canonical));
    const served = std.mem.trim(u8, contract.diagnostic_execution_unavailable_json, " \r\n");
    try std.testing.expect(std.mem.eql(u8, diagnostic, served));
    var buf: [256]u8 = undefined;
    const written = try contract.writeCanonicalError(&buf, .{
        .code = .unsupported,
        .message = "the selected Linux VM provider is not available",
        .request_id = "req_test1",
        .retryable = false,
    });
    try std.testing.expect(std.mem.eql(u8, canonical, written));
}

test "valid sandbox create fixture is accepted; owner field is rejected" {
    var storage = contract.SandboxCreateStorage{};
    const ok = try contract.validateSandboxCreate(@embedFile("fixtures/sandbox_create.valid.json"), &storage);
    try std.testing.expect(ok.profile == .linux_vm_x64);
    try std.testing.expectError(error.UnknownField, contract.validateSandboxCreate(
        @embedFile("fixtures/sandbox_create.unknown_owner.json"),
        &storage,
    ));
    try std.testing.expectError(error.UnknownField, contract.validateSandboxCreate(
        @embedFile("fixtures/sandbox_create.image_abi.json"),
        &storage,
    ));
}

test "numeric generation fixture is rejected" {
    var storage = contract.ExecutionCreateStorage{};
    try std.testing.expectError(error.UnexpectedType, contract.validateExecutionCreate(
        @embedFile("fixtures/execution_create.numeric_generation.json"),
        &storage,
    ));
}

test "independent json reject fixtures match bounded std.json validation" {
    const bytes = @embedFile("fixtures/json_reject.vectors.txt");
    const Handler = struct {
        fn go(line: []const u8) anyerror!void {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.BadFixture;
            const body = line[0..tab];
            const expected_name = line[tab + 1 ..];
            var storage = contract.ExecutionCreateStorage{};
            const result = contract.validateExecutionCreate(body, &storage);
            if (result) |_| return error.DidNotReject else |err| {
                try std.testing.expect(std.mem.eql(u8, @errorName(err), expected_name));
            }
        }
    };
    try eachDataLine(bytes, Handler.go);
}

test "stdin_base64 and unicode fixtures accept and reject independently" {
    var storage = contract.ExecutionCreateStorage{};
    const ok = try contract.validateExecutionCreate(@embedFile("fixtures/execution_create.stdin_base64.ok.json"), &storage);
    try std.testing.expect(ok.has_stdin);
    try std.testing.expectEqual(@as(usize, 1), ok.stdin_bytes);
    try std.testing.expectError(error.UnexpectedType, contract.validateExecutionCreate(
        @embedFile("fixtures/execution_create.stdin_base64.number.json"),
        &storage,
    ));
    try std.testing.expectError(error.InvalidJson, contract.validateExecutionCreate(
        @embedFile("fixtures/execution_create.stdin_base64.malformed.json"),
        &storage,
    ));
    try std.testing.expectError(error.InvalidField, contract.validateExecutionCreate(
        @embedFile("fixtures/execution_create.stdin_base64.invalid.json"),
        &storage,
    ));
    const unicode = try contract.validateExecutionCreate(@embedFile("fixtures/execution_create.unicode_argv.json"), &storage);
    try std.testing.expectEqual(@as(usize, 1), unicode.argv_count);
    try std.testing.expect(std.mem.eql(u8, storage.argv[0][0..storage.argv_len[0]], "/bin/sh"));
    try std.testing.expect(unicode.has_stdin);
    try std.testing.expectError(error.InvalidJson, contract.validateExecutionCreate(
        @embedFile("fixtures/execution_create.lone_surrogate.json"),
        &storage,
    ));
    try std.testing.expectError(error.DuplicateField, contract.validateExecutionCreate(
        @embedFile("fixtures/execution_create.duplicate_generation.json"),
        &storage,
    ));
    try std.testing.expectError(error.UnexpectedType, contract.validateExecutionCreate(
        @embedFile("fixtures/execution_create.cwd_null.json"),
        &storage,
    ));
    try std.testing.expectError(error.UnexpectedType, contract.validateExecutionCreate(
        @embedFile("fixtures/execution_create.stdin_null.json"),
        &storage,
    ));
    try std.testing.expectError(error.UnexpectedType, contract.validateExecutionCreate(
        @embedFile("fixtures/execution_create.timeout_null.json"),
        &storage,
    ));
}

test "canonical error detail fixture is structured not verbatim json" {
    const fixture = std.mem.trim(u8, @embedFile("fixtures/error.canonical.with_detail.json"), " \r\n");
    var buf: [512]u8 = undefined;
    const written = try contract.writeCanonicalError(&buf, .{
        .code = .invalid_request,
        .message = "invalid field",
        .request_id = "req_detail1",
        .retryable = false,
        .detail = .{ .entries = &.{.{ .name = "field", .value = .{ .string = "stdin_base64" } }} },
    });
    try std.testing.expect(std.mem.eql(u8, fixture, written));
    try std.testing.expect(contract.isCanonicalEnvelope(written));
    const injected = try contract.writeCanonicalError(&buf, .{
        .code = .invalid_request,
        .message = "invalid field",
        .request_id = "req_detail1",
        .retryable = false,
        .detail = .{ .entries = &.{.{ .name = "field", .value = .{ .string = "\"},\"code\":\"forged" } }} },
    });
    try std.testing.expect(std.mem.indexOf(u8, injected, "\"code\":\"forged\"") == null);
}

fn parseMethod(name: []const u8) !std.http.Method {
    if (std.mem.eql(u8, name, "GET")) return .GET;
    if (std.mem.eql(u8, name, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, name, "POST")) return .POST;
    if (std.mem.eql(u8, name, "PUT")) return .PUT;
    if (std.mem.eql(u8, name, "DELETE")) return .DELETE;
    return error.BadFixture;
}

test "bootstrap HTTP vectors stay fail-closed with the diagnostic envelope" {
    const bytes = @embedFile("fixtures/http_bootstrap.vectors.txt");
    const Handler = struct {
        fn go(line: []const u8) anyerror!void {
            var fields: [6][]const u8 = undefined;
            const n = try splitN(line, '|', &fields);
            try std.testing.expectEqual(@as(usize, 6), n);
            const method = try parseMethod(fields[0]);
            const path = fields[1];
            const len: ?u64 = if (std.mem.eql(u8, fields[2], "-")) null else try std.fmt.parseInt(u64, fields[2], 10);
            const status = try std.fmt.parseInt(u16, fields[3], 10);
            const needle = fields[4];
            const envelope = fields[5];
            const response = bootstrap.route(.{}, method, path, len);
            try std.testing.expectEqual(status, response.status);
            try std.testing.expect(std.mem.indexOf(u8, response.body, needle) != null);
            if (std.mem.eql(u8, envelope, "diagnostic_nested")) {
                if (std.mem.indexOf(u8, response.body, "\"error\"") != null) {
                    try std.testing.expect(contract.isDiagnosticEnvelope(response.body));
                    try std.testing.expect(!contract.isCanonicalEnvelope(response.body));
                }
            }
        }
    };
    try eachDataLine(bytes, Handler.go);
}

test "canonical status fixtures match contract mappings" {
    const bytes = @embedFile("fixtures/canonical_status.vectors.txt");
    const Handler = struct {
        fn go(line: []const u8) anyerror!void {
            var fields: [3][]const u8 = undefined;
            const n = try splitN(line, '|', &fields);
            try std.testing.expectEqual(@as(usize, 3), n);
            const code = std.meta.stringToEnum(contract.CanonicalCode, fields[0]) orelse return error.BadFixture;
            const status = try std.fmt.parseInt(u16, fields[1], 10);
            const retryable = std.mem.eql(u8, fields[2], "true");
            try std.testing.expectEqual(status, code.httpStatus());
            try std.testing.expectEqual(retryable, code.retryable());
        }
    };
    try eachDataLine(bytes, Handler.go);
}

test "engine seams remain unavailable in AP0/AP1" {
    try std.testing.expect(!engine.unavailable_seams.advertisesExecution());
    try std.testing.expectError(error.Unsupported, engine.unavailable_seams.vm.boot(.{}));
    try std.testing.expectError(error.Unsupported, engine.unavailable_seams.vm.pause(.{}));
    try std.testing.expectError(error.Unsupported, engine.unavailable_seams.vm.resumeGuest(.{}));
    try std.testing.expectError(error.Unsupported, engine.unavailable_seams.vm.stop(.{}));
    try std.testing.expectError(error.Unsupported, engine.unavailable_seams.pty.open());
    try std.testing.expectError(error.Unsupported, engine.unavailable_seams.channels.open());
}

test "inventory and available flags cannot advertise execution without composition" {
    const rec = contract.ProviderRecord{
        .kind = .qemu_kvm,
        .profile = .linux_vm_x64,
        .image_digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .pause_resume = true,
        .qualified = true,
    };
    try std.testing.expect(contract.inventoryAdvertisesExecution(.{ .providers = &.{rec} }));
    const caps = contract.capabilitiesFromInventory(.{ .providers = &.{rec} });
    try std.testing.expect(!caps.execution);
    try std.testing.expect(!caps.pty);
    try std.testing.expect(!caps.sse);
    var seams = engine.unavailable_seams;
    seams.vm.meta.available = true;
    seams.auth.meta.available = true;
    seams.store.meta.available = true;
    seams.lifecycle.meta.available = true;
    seams.inventory = .{ .providers = &.{rec} };
    try std.testing.expect(!seams.advertisesExecution());
    const backend = bootstrap.Backend{ .inventory = .{ .providers = &.{rec} } };
    const response = bootstrap.route(backend, .GET, "/v1/capabilities", null);
    try std.testing.expect(std.mem.eql(u8, response.body, contract.diagnostic_empty_capabilities_json));
}

test "bootstrap and engine consume the named sandbox_contract module identity" {
    // Zig 0.16 rejects `Type{}.field` as two statements. Bind the value first.
    const backend = bootstrap.Backend{};
    const inventory: contract.ProviderInventory = backend.inventory;
    try std.testing.expect(!contract.inventoryAdvertisesExecution(inventory));
    const kind: contract.ProviderKind = engine.unavailable_seams.vm.kind;
    try std.testing.expectEqual(contract.ProviderKind.none, kind);
    try std.testing.expect(std.mem.eql(u8, engine.unavailable_seams.vm.meta.version, contract.CONTRACT_VERSION));
}

fn containsYamlLine(haystack: []const u8, line: []const u8) bool {
    var i: usize = 0;
    while (i + line.len <= haystack.len) : (i += 1) {
        if (!std.mem.eql(u8, haystack[i .. i + line.len], line)) continue;
        const start_ok = i == 0 or haystack[i - 1] == '\n';
        const after = i + line.len;
        const end_ok = after == haystack.len or haystack[after] == '\n' or haystack[after] == '\r';
        if (start_ok and end_ok) return true;
    }
    return false;
}

fn rejectsIdentityHeaderSchemes(spec: []const u8) bool {
    return std.mem.indexOf(u8, spec, "LocalOsIdentity") == null and
        std.mem.indexOf(u8, spec, "X-Sandbox-Local-Identity") == null and
        std.mem.indexOf(u8, spec, "type: apiKey") == null;
}

test "openapi yaml line match is lf/crlf robust and rejects identity schemes" {
    try std.testing.expect(containsYamlLine("security:\n  - MutualTLS: []\n", "  - MutualTLS: []"));
    try std.testing.expect(containsYamlLine("security:\r\n  - MutualTLS: []\r\n", "  - MutualTLS: []"));
    try std.testing.expect(!containsYamlLine("security:\n  - LocalOsIdentity: []\n", "  - MutualTLS: []"));
    try std.testing.expect(!containsYamlLine("  - MutualTLS: [] extra\n", "  - MutualTLS: []"));
    try std.testing.expect(rejectsIdentityHeaderSchemes("security:\n  - MutualTLS: []\n"));
    try std.testing.expect(!rejectsIdentityHeaderSchemes("security:\n  - LocalOsIdentity: []\n"));
    try std.testing.expect(!rejectsIdentityHeaderSchemes("X-Sandbox-Local-Identity: yes\n"));
    try std.testing.expect(!rejectsIdentityHeaderSchemes("type: apiKey\n"));
}

test "remote OpenAPI requires MutualTLS only and rejects identity header schemes" {
    const spec = openapi_spec.spec;
    try std.testing.expect(containsYamlLine(spec, "  - MutualTLS: []"));
    try std.testing.expect(rejectsIdentityHeaderSchemes(spec));
    try std.testing.expect(std.mem.indexOf(u8, spec, "LocalOsIdentity") == null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "X-Sandbox-Local-Identity") == null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "type: apiKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "x-local-ipc-peer-pid:") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "x-local-ipc-peer-uid:") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "x-local-ipc-peer-gid:") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "x-local-ipc-peer-sid:") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "x-local-ipc-audit-token:") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "1844674407370955161[0-5]") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "1[0-8][0-9]{18}") == null);
}

test "empty SHA-256 digest matches the independent published empty-string hash" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &digest, .{});
    var hex: [64]u8 = undefined;
    const got = contract.hexLower(&hex, &digest);
    try std.testing.expect(std.mem.eql(u8, got, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
}
