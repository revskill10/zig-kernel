//! Fail-closed HTTP surface for the container bootstrap.
//!
//! This intentionally has no session store and no execution adapter.  A later
//! supervisor composes a real backend through `Backend`; until then every
//! sandbox mutation is rejected before it can imply a VM, filesystem, or
//! process side effect.
//!
//! Error documents use the **legacy nested diagnostic envelope**
//! `{"error":{"code","message"}}`. That is not the planned canonical
//! production envelope `{code,message,request_id,retryable,detail}` defined
//! in `contract.zig`.
const std = @import("std");
const contract = @import("sandbox_contract");

pub const MAX_HEADER_BYTES: usize = 8 * 1024;
pub const MAX_REQUEST_BODY_BYTES: u64 = 1024 * 1024;

pub const BackendState = enum { unavailable, ready };

/// Composition seam for a future KVM/QEMU backend.  The HTTP layer depends on
/// qualified inventory plus composed controls; a ready boolean never advertises
/// execution by itself.
pub const Backend = struct {
    context: ?*const anyopaque = null,
    state_fn: *const fn (?*const anyopaque) BackendState = unavailableState,
    inventory: contract.ProviderInventory = .{},

    pub fn state(self: Backend) BackendState {
        return self.state_fn(self.context);
    }
};

fn unavailableState(_: ?*const anyopaque) BackendState {
    return .unavailable;
}

pub const Response = struct {
    status: u16,
    allow: ?[]const u8 = null,
    body: []const u8,
};

pub fn route(backend: Backend, method: std.http.Method, target: []const u8, content_length: ?u64) Response {
    _ = backend;
    const path_class = contract.classifyPath(target);
    if (content_length) |n| if (n > MAX_REQUEST_BODY_BYTES) {
        return .{ .status = 413, .body = contract.diagnostic_payload_too_large_json };
    };

    switch (path_class) {
        .health => {
            return if (method == .GET or method == .HEAD)
                .{ .status = 200, .body = contract.diagnostic_health_json }
            else
                .{ .status = 405, .allow = "GET, HEAD", .body = contract.diagnostic_method_not_allowed_json };
        },
        .ready => {
            // This listener is diagnostic-only. A BackendState.ready flag and
            // even a contract-level inventory advertisement cannot compose
            // auth, durable store, launcher, and guest controls here.
            return if (method == .GET or method == .HEAD)
                .{ .status = 503, .body = contract.diagnostic_not_ready_json }
            else
                .{ .status = 405, .allow = "GET, HEAD", .body = contract.diagnostic_method_not_allowed_json };
        },
        .capabilities => {
            return if (method == .GET or method == .HEAD)
                .{ .status = 200, .body = contract.diagnostic_empty_capabilities_json }
            else
                .{ .status = 405, .allow = "GET, HEAD", .body = contract.diagnostic_method_not_allowed_json };
        },
        .sandbox => {
            return .{ .status = 501, .body = contract.diagnostic_execution_unavailable_json };
        },
        .exports, .operations, .images, .callbacks, .metrics, .unknown => {
            return .{ .status = 404, .body = contract.diagnostic_not_found_json };
        },
    }
}

test "bootstrap routes are truthful and fail closed" {
    const backend = Backend{};
    try std.testing.expectEqual(@as(u16, 200), route(backend, .GET, "/healthz", null).status);
    const ready = route(backend, .GET, "/readyz", null);
    try std.testing.expectEqual(@as(u16, 503), ready.status);
    try std.testing.expect(std.mem.indexOf(u8, ready.body, "execution_unavailable") != null);
    const caps = route(backend, .GET, "/v1/capabilities", null);
    try std.testing.expectEqual(@as(u16, 200), caps.status);
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "\"execution\":false") != null);
    try std.testing.expectEqual(@as(u16, 501), route(backend, .POST, "/v1/sandboxes", null).status);
    try std.testing.expectEqual(@as(u16, 501), route(backend, .POST, "/v1/sandboxes?trace=1", null).status);
    try std.testing.expectEqual(@as(u16, 404), route(backend, .GET, "/v1/sandboxes-else", null).status);
}

test "bootstrap bounds and method errors are stable" {
    const backend = Backend{};
    try std.testing.expectEqual(@as(u16, 405), route(backend, .POST, "/healthz", null).status);
    try std.testing.expectEqual(@as(u16, 413), route(backend, .POST, "/v1/sandboxes", MAX_REQUEST_BODY_BYTES + 1).status);
}

fn forceReady(_: ?*const anyopaque) BackendState {
    return .ready;
}

test "backend ready flag does not advertise execution or ready 200" {
    const backend = Backend{ .state_fn = forceReady };
    try std.testing.expectEqual(BackendState.ready, backend.state());
    const ready = route(backend, .GET, "/readyz", null);
    try std.testing.expectEqual(@as(u16, 503), ready.status);
    try std.testing.expect(std.mem.eql(u8, ready.body, contract.diagnostic_not_ready_json));
    const caps = route(backend, .GET, "/v1/capabilities", null);
    try std.testing.expect(std.mem.eql(u8, caps.body, contract.diagnostic_empty_capabilities_json));
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "\"execution\":false") != null);
    try std.testing.expectEqual(@as(u16, 501), route(backend, .POST, "/v1/sandboxes", null).status);
}

test "qualified inventory on diagnostic listener stays execution false" {
    const rec = contract.ProviderRecord{
        .kind = .qemu_kvm,
        .profile = .linux_vm_x64,
        .image_digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .pause_resume = true,
        .qualified = true,
    };
    const backend = Backend{ .state_fn = forceReady, .inventory = .{ .providers = &.{rec} } };
    try std.testing.expect(contract.inventoryAdvertisesExecution(backend.inventory));
    const caps = route(backend, .GET, "/v1/capabilities", null);
    try std.testing.expect(std.mem.eql(u8, caps.body, contract.diagnostic_empty_capabilities_json));
    try std.testing.expect(std.mem.indexOf(u8, caps.body, "\"execution\":false") != null);
    try std.testing.expectEqual(@as(u16, 503), route(backend, .GET, "/readyz", null).status);
    try std.testing.expectEqual(@as(u16, 501), route(backend, .POST, "/v1/sandboxes", null).status);
}

test "bootstrap keeps nested diagnostic errors and 404 for non-sandbox planned routes" {
    const backend = Backend{};
    const unavailable = route(backend, .POST, "/v1/sandboxes", null);
    try std.testing.expect(contract.isDiagnosticEnvelope(unavailable.body));
    try std.testing.expect(!contract.isCanonicalEnvelope(unavailable.body));
    try std.testing.expectEqual(@as(u16, 404), route(backend, .GET, "/v1/exports", null).status);
    try std.testing.expectEqual(@as(u16, 404), route(backend, .POST, "/v1/exports", null).status);
    try std.testing.expectEqual(@as(u16, 404), route(backend, .GET, "/v1/operations/op_1", null).status);
    try std.testing.expectEqual(@as(u16, 404), route(backend, .POST, "/v1/callbacks", null).status);
    try std.testing.expectEqual(@as(u16, 501), route(backend, .POST, "/v1/sandboxes/s1/processes", null).status);
    try std.testing.expectEqual(@as(u16, 501), route(backend, .POST, "/v1/sandboxes/s1/fetch", null).status);
    try std.testing.expectEqual(@as(u16, 501), route(backend, .POST, "/v1/sandboxes/s1/pause", null).status);
    try std.testing.expectEqual(@as(u16, 501), route(backend, .POST, "/v1/sandboxes/s1/resume", null).status);
}

test "bootstrap does not call hosted api.zig success paths" {
    // Composition rule: this file must not import supervisor/api.zig.
    // The hosted Service create/guestReady/startExec path stays a prototype.
    const backend = Backend{};
    const create = route(backend, .POST, "/v1/sandboxes", 12);
    try std.testing.expectEqual(@as(u16, 501), create.status);
    try std.testing.expect(std.mem.indexOf(u8, create.body, "execution_unavailable") != null);
}
