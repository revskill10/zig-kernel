//! Portable sandbox API contract: wire types, bounded validation, envelopes,
//! route identity, and capability/inventory rules.
//!
//! This module has no OS handles, process launch, authentication decisions,
//! or storage authority. HTTP bootstrap consumes diagnostic documents from
//! here; it does not serve the canonical production envelope.
const std = @import("std");

pub const MAX_JSON_BYTES: usize = 64 * 1024;
pub const MAX_JSON_DEPTH: u8 = 8;
pub const MAX_OBJECT_FIELDS: usize = 32;
pub const MAX_ARGV: usize = 64;
pub const MAX_ENV: usize = 64;
pub const MAX_STRING_BYTES: usize = 4096;
pub const MAX_ID_BYTES: usize = 128;
pub const MAX_IDEMPOTENCY_BYTES: usize = 128;
pub const MIN_IDEMPOTENCY_BYTES: usize = 8;
pub const MAX_PATH_BYTES: usize = 4096;
pub const API_VERSION = "v1";
pub const CONTRACT_VERSION = "1";

/// Exact diagnostic capabilities document served by the fail-closed bootstrap.
/// Independent fixture `tests/contract/fixtures/capabilities.diagnostic.json`
/// must match these bytes, including the trailing newline.
pub const diagnostic_empty_capabilities_json =
    "{\"backends\":[],\"guest_abis\":[],\"images\":[],\"features\":{\"execution\":false,\"network_modes\":[],\"snapshots\":false,\"forks\":false,\"sse\":false},\"ceilings\":{}}\n";

pub const diagnostic_health_json = "{\"status\":\"ok\"}\n";
pub const diagnostic_not_ready_json = "{\"status\":\"not_ready\",\"reason\":\"execution_unavailable\"}\n";
pub const diagnostic_execution_unavailable_json =
    "{\"error\":{\"code\":\"execution_unavailable\",\"message\":\"sandbox execution is not implemented in this bootstrap\"}}\n";
pub const diagnostic_payload_too_large_json =
    "{\"error\":{\"code\":\"payload_too_large\",\"message\":\"request body exceeds bootstrap limit\"}}\n";
pub const diagnostic_not_found_json =
    "{\"error\":{\"code\":\"not_found\",\"message\":\"route not found\"}}\n";
pub const diagnostic_method_not_allowed_json =
    "{\"error\":{\"code\":\"method_not_allowed\",\"message\":\"method not allowed\"}}\n";
pub const diagnostic_bad_request_json =
    "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid or oversized request headers\"}}\n";

pub const EnvelopeKind = enum {
    /// Nested `{"error":{"code","message"}}` used by the diagnostic listener.
    diagnostic_nested,
    /// Flat `{code,message,request_id,retryable,detail?}` planned production envelope.
    canonical,
};

pub const DiagnosticCode = enum {
    execution_unavailable,
    payload_too_large,
    not_found,
    method_not_allowed,
    bad_request,

    pub fn text(self: DiagnosticCode) []const u8 {
        return @tagName(self);
    }
};

pub const CanonicalCode = enum {
    invalid_request,
    unauthenticated,
    forbidden,
    not_found,
    conflict,
    stale_generation,
    idempotency_conflict,
    limit,
    payload_too_large,
    cursor_expired,
    unsupported_host,
    unsupported_image,
    unsupported,
    capacity,
    guest_failure,
    resource_limit,
    deadline,
    unavailable,
    internal,

    pub fn text(self: CanonicalCode) []const u8 {
        return @tagName(self);
    }

    pub fn httpStatus(self: CanonicalCode) u16 {
        return switch (self) {
            .invalid_request => 400,
            .unauthenticated => 401,
            .forbidden => 403,
            .not_found => 404,
            .conflict, .stale_generation, .idempotency_conflict => 409,
            .cursor_expired => 410,
            .payload_too_large => 413,
            .unsupported_host, .unsupported_image => 422,
            .limit => 429,
            .unsupported => 501,
            .capacity, .unavailable => 503,
            .deadline => 504,
            .guest_failure, .resource_limit, .internal => 500,
        };
    }

    pub fn retryable(self: CanonicalCode) bool {
        return switch (self) {
            .capacity, .unavailable, .deadline, .internal => true,
            else => false,
        };
    }
};

pub fn diagnosticToCanonical(code: DiagnosticCode) CanonicalCode {
    return switch (code) {
        .execution_unavailable => .unsupported,
        .payload_too_large => .payload_too_large,
        .not_found => .not_found,
        .method_not_allowed => .invalid_request,
        .bad_request => .invalid_request,
    };
}

pub const MAX_DETAIL_ENTRIES: usize = 8;
pub const MAX_DETAIL_KEY_BYTES: usize = 32;

/// Scalar JSON values allowed inside canonical error `detail`. Raw JSON is never
/// interpolated; values are serialized after key/value validation.
pub const CanonicalDetailValue = union(enum) {
    string: []const u8,
    boolean: bool,
    decimal: []const u8,
    null: void,
};

pub const CanonicalDetailEntry = struct {
    name: []const u8,
    value: CanonicalDetailValue,
};

pub const CanonicalDetail = struct {
    entries: []const CanonicalDetailEntry = &.{},
};

pub const CanonicalError = struct {
    code: CanonicalCode,
    message: []const u8,
    request_id: []const u8,
    retryable: bool,
    detail: CanonicalDetail = .{},
};

pub fn writeCanonicalError(buf: []u8, err: CanonicalError) ![]const u8 {
    if (!isJsonSafeAscii(err.message) or !isOpaqueId(err.request_id)) return error.InvalidCanonicalError;
    try validateCanonicalDetail(err.detail);
    const retry = if (err.retryable) "true" else "false";
    var n: usize = 0;
    try appendSlice(buf, &n, "{\"code\":\"");
    try appendSlice(buf, &n, err.code.text());
    try appendSlice(buf, &n, "\",\"message\":\"");
    try appendSlice(buf, &n, err.message);
    try appendSlice(buf, &n, "\",\"request_id\":\"");
    try appendSlice(buf, &n, err.request_id);
    try appendSlice(buf, &n, "\",\"retryable\":");
    try appendSlice(buf, &n, retry);
    if (err.detail.entries.len != 0) {
        try appendSlice(buf, &n, ",\"detail\":{");
        for (err.detail.entries, 0..) |entry, i| {
            if (i != 0) try appendSlice(buf, &n, ",");
            try appendJsonString(buf, &n, entry.name);
            try appendSlice(buf, &n, ":");
            switch (entry.value) {
                .string => |s| try appendJsonString(buf, &n, s),
                .boolean => |b| try appendSlice(buf, &n, if (b) "true" else "false"),
                .decimal => |d| try appendJsonString(buf, &n, d),
                .null => try appendSlice(buf, &n, "null"),
            }
        }
        try appendSlice(buf, &n, "}");
    }
    try appendSlice(buf, &n, "}");
    return buf[0..n];
}

fn validateCanonicalDetail(detail: CanonicalDetail) error{InvalidCanonicalError}!void {
    if (detail.entries.len > MAX_DETAIL_ENTRIES) return error.InvalidCanonicalError;
    for (detail.entries, 0..) |entry, i| {
        if (!isDetailKey(entry.name)) return error.InvalidCanonicalError;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (std.mem.eql(u8, detail.entries[j].name, entry.name)) return error.InvalidCanonicalError;
        }
        switch (entry.value) {
            .string => |s| if (!isJsonUtf8Scalar(s)) return error.InvalidCanonicalError,
            .decimal => |d| if (!isCanonicalDecimalU64(d)) return error.InvalidCanonicalError,
            .boolean, .null => {},
        }
    }
}

pub fn isDetailKey(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_DETAIL_KEY_BYTES) return false;
    const c0 = s[0];
    if (!((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z') or c0 == '_')) return false;
    for (s[1..]) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn isJsonUtf8Scalar(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return false;
    _ = std.unicode.Utf8View.init(s) catch return false;
    return true;
}

fn appendSlice(buf: []u8, n: *usize, s: []const u8) error{NoSpaceLeft}!void {
    if (n.* + s.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[n.* .. n.* + s.len], s);
    n.* += s.len;
}

fn appendByte(buf: []u8, n: *usize, c: u8) error{NoSpaceLeft}!void {
    if (n.* >= buf.len) return error.NoSpaceLeft;
    buf[n.*] = c;
    n.* += 1;
}

fn appendJsonString(buf: []u8, n: *usize, s: []const u8) error{NoSpaceLeft}!void {
    try appendByte(buf, n, '"');
    for (s) |c| {
        switch (c) {
            '"' => try appendSlice(buf, n, "\\\""),
            '\\' => try appendSlice(buf, n, "\\\\"),
            '\n' => try appendSlice(buf, n, "\\n"),
            '\r' => try appendSlice(buf, n, "\\r"),
            '\t' => try appendSlice(buf, n, "\\t"),
            0x08 => try appendSlice(buf, n, "\\b"),
            0x0c => try appendSlice(buf, n, "\\f"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    var esc = [_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                    try appendSlice(buf, n, &esc);
                } else {
                    try appendByte(buf, n, c);
                }
            },
        }
    }
    try appendByte(buf, n, '"');
}

pub fn isDiagnosticEnvelope(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, "{\"error\":{\"code\":") != null;
}

pub fn isCanonicalEnvelope(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, "\"request_id\"") != null and
        std.mem.indexOf(u8, bytes, "\"retryable\"") != null and
        !isDiagnosticEnvelope(bytes);
}

fn isJsonSafeAscii(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 or c > 0x7e or c == '"' or c == '\\') return false;
    }
    return true;
}

pub const DecimalError = error{InvalidDecimalU64};

/// Canonical non-negative decimal string: "0" or [1-9][0-9]* with no sign,
/// fraction, exponent, whitespace, or leading zeros. Accepts the full u64 range.
pub fn parseDecimalU64(s: []const u8) DecimalError!u64 {
    if (s.len == 0 or s.len > 20) return error.InvalidDecimalU64;
    if (s[0] == '0') {
        if (s.len != 1) return error.InvalidDecimalU64;
        return 0;
    }
    var value: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidDecimalU64;
        const d: u64 = c - '0';
        value = std.math.mul(u64, value, 10) catch return error.InvalidDecimalU64;
        value = std.math.add(u64, value, d) catch return error.InvalidDecimalU64;
    }
    return value;
}

pub fn formatDecimalU64(buf: *[20]u8, value: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable;
}

pub fn isCanonicalDecimalU64(s: []const u8) bool {
    _ = parseDecimalU64(s) catch return false;
    return true;
}

pub fn isOpaqueId(s: []const u8) bool {
    if (s.len < 1 or s.len > MAX_ID_BYTES) return false;
    var all_digits = true;
    for (s) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-' or c == ':';
        if (!ok) return false;
        if (c < '0' or c > '9') all_digits = false;
    }
    return !all_digits;
}

pub fn isIdempotencyKey(s: []const u8) bool {
    if (s.len < MIN_IDEMPOTENCY_BYTES or s.len > MAX_IDEMPOTENCY_BYTES) return false;
    for (s) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-' or c == ':';
        if (!ok) return false;
    }
    return true;
}

pub fn isEventCursor(s: []const u8) bool {
    return isOpaqueId(s);
}

pub fn isGeneration(s: []const u8) bool {
    const n = parseDecimalU64(s) catch return false;
    return n >= 1;
}

pub const ProfileId = enum {
    linux_vm_x64,
    linux_vm_arm64,
    wasm_core_p1,
    native_linux_x64,
    native_macos_arm64,
    native_windows_x64,
    zk_abi_v1,

    pub fn text(self: ProfileId) []const u8 {
        return switch (self) {
            .linux_vm_x64 => "linux-vm/x64",
            .linux_vm_arm64 => "linux-vm/arm64",
            .wasm_core_p1 => "wasm-core-p1",
            .native_linux_x64 => "native/linux-x64",
            .native_macos_arm64 => "native/macos-arm64",
            .native_windows_x64 => "native/windows-x64",
            .zk_abi_v1 => "zk-abi-v1",
        };
    }

    pub fn isLinuxVm(self: ProfileId) bool {
        return self == .linux_vm_x64 or self == .linux_vm_arm64;
    }
};

pub fn parseProfileId(s: []const u8) ?ProfileId {
    if (std.mem.eql(u8, s, "linux-vm/x64")) return .linux_vm_x64;
    if (std.mem.eql(u8, s, "linux-vm/arm64")) return .linux_vm_arm64;
    if (std.mem.eql(u8, s, "wasm-core-p1")) return .wasm_core_p1;
    if (std.mem.eql(u8, s, "native/linux-x64")) return .native_linux_x64;
    if (std.mem.eql(u8, s, "native/macos-arm64")) return .native_macos_arm64;
    if (std.mem.eql(u8, s, "native/windows-x64")) return .native_windows_x64;
    if (std.mem.eql(u8, s, "zk-abi-v1")) return .zk_abi_v1;
    return null;
}

pub const ProviderKind = enum {
    none,
    qemu_kvm,
    qemu_hvf,
    qemu_whpx,

    pub fn text(self: ProviderKind) []const u8 {
        return switch (self) {
            .none => "none",
            .qemu_kvm => "qemu-kvm",
            .qemu_hvf => "qemu-hvf",
            .qemu_whpx => "qemu-whpx",
        };
    }
};

pub const ProviderRecord = struct {
    kind: ProviderKind = .none,
    profile: ?ProfileId = null,
    image_digest: []const u8 = "",
    pause_resume: bool = false,
    qualified: bool = false,
};

pub const ProviderInventory = struct {
    providers: []const ProviderRecord = &.{},
};

pub fn isImageDigest(s: []const u8) bool {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, s, prefix)) return false;
    const hex = s[prefix.len..];
    if (hex.len != 64) return false;
    for (hex) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

/// True when inventory contains at least one record that *could* qualify a
/// Linux VM. This never sets client-visible execution by itself. Composition
/// must match the bound backend via `inventoryMatchesBoundVm`.
pub fn inventoryAdvertisesExecution(inventory: ProviderInventory) bool {
    for (inventory.providers) |p| {
        if (!p.qualified) continue;
        if (!p.pause_resume) continue;
        if (p.kind == .none) continue;
        const profile = p.profile orelse continue;
        if (!profile.isLinuxVm()) continue;
        if (!isImageDigest(p.image_digest)) continue;
        return true;
    }
    return false;
}

/// Qualification is per bound provider/profile/image. An unrelated inventory
/// record must not authorize a different backend.
pub fn inventoryMatchesBoundVm(
    inventory: ProviderInventory,
    kind: ProviderKind,
    profile: ProfileId,
    image_digest: []const u8,
) bool {
    if (kind == .none) return false;
    if (!profile.isLinuxVm()) return false;
    if (!isImageDigest(image_digest)) return false;
    for (inventory.providers) |p| {
        if (!p.qualified) continue;
        if (!p.pause_resume) continue;
        if (p.kind != kind) continue;
        const rec_profile = p.profile orelse continue;
        if (rec_profile != profile) continue;
        if (!std.mem.eql(u8, p.image_digest, image_digest)) continue;
        return true;
    }
    return false;
}

pub const CanonicalCapabilities = struct {
    execution: bool = false,
    auth: bool = false,
    durable_store: bool = false,
    snapshots: bool = false,
    forks: bool = false,
    sse: bool = false,
    pause_resume: bool = false,
    pty: bool = false,
    channels: bool = false,
    exports: bool = false,
    callbacks: bool = false,
    wasm_core: bool = false,
    guest_wasi: bool = false,
};

/// Real composition evidence. Adapter flags are only meaningful when the
/// named adapter is bound, version-matched, and not the unavailable default.
/// `vm_kind`/`vm_profile`/`vm_image_digest` must come from a ready bound VM,
/// never from an unbound metadata poke or an unrelated inventory row.
pub const CompositionEvidence = struct {
    inventory: ProviderInventory = .{},
    auth: bool = false,
    store: bool = false,
    launcher: bool = false,
    guest: bool = false,
    policy: bool = false,
    clock: bool = false,
    entropy: bool = false,
    image_registry: bool = false,
    lifecycle: bool = false,
    vm_ready: bool = false,
    vm_kind: ProviderKind = .none,
    vm_version: []const u8 = "",
    vm_pause_resume: bool = false,
    vm_profile: ?ProfileId = null,
    vm_image_digest: []const u8 = "",
    pty: bool = false,
    channels: bool = false,
    sse: bool = false,
    exports: bool = false,
    callbacks: bool = false,
    snapshots: bool = false,
    forks: bool = false,
    wasm_core: bool = false,
    guest_wasi: bool = false,
    network_allowlist: bool = false,
};

/// Inventory never grants client-visible features. Use
/// `capabilitiesFromComposition` when auth/store/launcher/guest/VM are bound.
pub fn capabilitiesFromInventory(inventory: ProviderInventory) CanonicalCapabilities {
    _ = inventory;
    return .{};
}

pub fn linuxVmRequiredControls(ev: CompositionEvidence) bool {
    return ev.auth and ev.store and ev.launcher and ev.guest and
        ev.lifecycle and ev.policy and ev.clock and ev.entropy and ev.image_registry;
}

pub fn capabilitiesFromComposition(ev: CompositionEvidence) CanonicalCapabilities {
    const version_ok = std.mem.eql(u8, ev.vm_version, CONTRACT_VERSION);
    const matched = if (ev.vm_profile) |profile|
        ev.vm_ready and version_ok and ev.vm_pause_resume and
            inventoryMatchesBoundVm(ev.inventory, ev.vm_kind, profile, ev.vm_image_digest)
    else
        false;
    const exec = matched and linuxVmRequiredControls(ev);
    return .{
        .execution = exec,
        .auth = ev.auth,
        .durable_store = ev.store,
        .snapshots = exec and ev.snapshots,
        .forks = exec and ev.forks,
        .sse = exec and ev.sse,
        .pause_resume = exec and ev.vm_pause_resume,
        .pty = exec and ev.pty,
        .channels = exec and ev.channels,
        .exports = exec and ev.exports,
        .callbacks = exec and ev.callbacks,
        .wasm_core = ev.wasm_core and ev.auth and ev.store,
        .guest_wasi = exec and ev.guest_wasi,
    };
}

pub const CapabilitySnapshot = struct {
    features: CanonicalCapabilities = .{},
    inventory: ProviderInventory = .{},
    bound_kind: ProviderKind = .none,
    bound_profile: ?ProfileId = null,
    bound_image_digest: []const u8 = "",
};

fn jsonBool(v: bool) []const u8 {
    return if (v) "true" else "false";
}

pub fn writeCanonicalCapabilities(buf: []u8, snapshot: CapabilitySnapshot) ![]const u8 {
    try assertTruthfulCapabilities(snapshot);
    var n: usize = 0;
    try appendSlice(buf, &n, "{\"api_version\":\"");
    try appendSlice(buf, &n, API_VERSION);
    try appendSlice(buf, &n, "\",\"contract_version\":\"");
    try appendSlice(buf, &n, CONTRACT_VERSION);
    try appendSlice(buf, &n, "\",\"error_envelope\":\"canonical\",\"backends\":[");
    try writeBackendList(buf, &n, snapshot.inventory);
    try appendSlice(buf, &n, "],\"guest_abis\":[");
    if (snapshot.features.wasm_core) try appendSlice(buf, &n, "\"wasm-core-p1\"");
    try appendSlice(buf, &n, "],\"images\":[");
    try writeImageList(buf, &n, snapshot.inventory);
    try appendSlice(buf, &n, "],\"profiles\":[");
    try writeProfileList(buf, &n, snapshot.inventory);
    try appendSlice(buf, &n, "],\"providers\":[");
    try writeProviderList(buf, &n, snapshot.inventory);
    try appendSlice(buf, &n, "],\"features\":{\"execution\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.execution));
    try appendSlice(buf, &n, ",\"auth\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.auth));
    try appendSlice(buf, &n, ",\"durable_store\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.durable_store));
    try appendSlice(buf, &n, ",\"network_modes\":[");
    if (snapshot.features.execution) try appendSlice(buf, &n, "\"offline\"");
    try appendSlice(buf, &n, "],\"snapshots\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.snapshots));
    try appendSlice(buf, &n, ",\"forks\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.forks));
    try appendSlice(buf, &n, ",\"sse\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.sse));
    try appendSlice(buf, &n, ",\"pause_resume\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.pause_resume));
    try appendSlice(buf, &n, ",\"pty\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.pty));
    try appendSlice(buf, &n, ",\"channels\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.channels));
    try appendSlice(buf, &n, ",\"exports\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.exports));
    try appendSlice(buf, &n, ",\"callbacks\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.callbacks));
    try appendSlice(buf, &n, ",\"wasm_core\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.wasm_core));
    try appendSlice(buf, &n, ",\"guest_wasi\":");
    try appendSlice(buf, &n, jsonBool(snapshot.features.guest_wasi));
    try appendSlice(buf, &n, "},\"ceilings\":{}}");
    return buf[0..n];
}

fn assertTruthfulCapabilities(snapshot: CapabilitySnapshot) error{UntruthfulCapabilities}!void {
    const caps = snapshot.features;
    if (caps.execution) {
        if (!caps.auth or !caps.durable_store or !caps.pause_resume) return error.UntruthfulCapabilities;
        const profile = snapshot.bound_profile orelse return error.UntruthfulCapabilities;
        if (!inventoryMatchesBoundVm(snapshot.inventory, snapshot.bound_kind, profile, snapshot.bound_image_digest))
            return error.UntruthfulCapabilities;
    }
    if ((caps.pty or caps.channels or caps.sse or caps.pause_resume or caps.exports or caps.callbacks or caps.snapshots or caps.forks or caps.guest_wasi) and !caps.execution)
        return error.UntruthfulCapabilities;
    if (caps.wasm_core and !(caps.auth and caps.durable_store)) return error.UntruthfulCapabilities;
}

fn writeBackendList(buf: []u8, n: *usize, inventory: ProviderInventory) error{NoSpaceLeft}!void {
    var first = true;
    var i: usize = 0;
    while (i < inventory.providers.len) : (i += 1) {
        const p = inventory.providers[i];
        if (p.kind == .none) continue;
        var seen = false;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (inventory.providers[j].kind == p.kind) seen = true;
        }
        if (seen) continue;
        if (!first) try appendSlice(buf, n, ",");
        first = false;
        try appendJsonString(buf, n, p.kind.text());
    }
}

fn writeImageList(buf: []u8, n: *usize, inventory: ProviderInventory) error{NoSpaceLeft}!void {
    var first = true;
    var i: usize = 0;
    while (i < inventory.providers.len) : (i += 1) {
        const p = inventory.providers[i];
        if (!isImageDigest(p.image_digest)) continue;
        var seen = false;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (std.mem.eql(u8, inventory.providers[j].image_digest, p.image_digest)) seen = true;
        }
        if (seen) continue;
        if (!first) try appendSlice(buf, n, ",");
        first = false;
        try appendSlice(buf, n, "{\"id\":");
        const id = if (p.profile) |prof| prof.text() else "image";
        try appendJsonString(buf, n, id);
        try appendSlice(buf, n, ",\"digest\":");
        try appendJsonString(buf, n, p.image_digest);
        try appendSlice(buf, n, "}");
    }
}

fn writeProfileList(buf: []u8, n: *usize, inventory: ProviderInventory) error{NoSpaceLeft}!void {
    var first = true;
    var i: usize = 0;
    while (i < inventory.providers.len) : (i += 1) {
        const profile = inventory.providers[i].profile orelse continue;
        var seen = false;
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (inventory.providers[j].profile) |prev| {
                if (prev == profile) seen = true;
            }
        }
        if (seen) continue;
        if (!first) try appendSlice(buf, n, ",");
        first = false;
        try appendJsonString(buf, n, profile.text());
    }
}

fn writeProviderList(buf: []u8, n: *usize, inventory: ProviderInventory) error{NoSpaceLeft}!void {
    var first = true;
    for (inventory.providers) |p| {
        if (p.kind == .none) continue;
        if (!first) try appendSlice(buf, n, ",");
        first = false;
        try appendSlice(buf, n, "{\"kind\":");
        try appendJsonString(buf, n, p.kind.text());
        try appendSlice(buf, n, ",\"qualified\":");
        try appendSlice(buf, n, jsonBool(p.qualified));
        try appendSlice(buf, n, ",\"pause_resume\":");
        try appendSlice(buf, n, jsonBool(p.pause_resume));
        if (p.profile) |profile| {
            try appendSlice(buf, n, ",\"profile\":");
            try appendJsonString(buf, n, profile.text());
        }
        if (isImageDigest(p.image_digest)) {
            try appendSlice(buf, n, ",\"image_digest\":");
            try appendJsonString(buf, n, p.image_digest);
        }
        try appendSlice(buf, n, "}");
    }
}

pub const PathClass = enum {
    health,
    ready,
    capabilities,
    sandbox,
    exports,
    operations,
    images,
    callbacks,
    metrics,
    unknown,
};

pub fn classifyPath(target: []const u8) PathClass {
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (std.mem.eql(u8, path, "/healthz")) return .health;
    if (std.mem.eql(u8, path, "/readyz")) return .ready;
    if (std.mem.eql(u8, path, "/metrics")) return .metrics;
    if (std.mem.eql(u8, path, "/v1/capabilities")) return .capabilities;
    if (prefixMatch(path, "/v1/sandboxes")) return .sandbox;
    if (prefixMatch(path, "/v1/exports")) return .exports;
    if (prefixMatch(path, "/v1/operations")) return .operations;
    if (prefixMatch(path, "/v1/images")) return .images;
    if (prefixMatch(path, "/v1/callbacks")) return .callbacks;
    return .unknown;
}

fn prefixMatch(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or
        (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/');
}

/// Bootstrap HTTP status for a classified path. Sandbox routes are 501;
/// planned but unhosted catalog routes are 404; diagnostics are 200/503.
pub fn bootstrapStatus(class: PathClass, method: std.http.Method, content_length: ?u64, max_body: u64) u16 {
    if (content_length) |n| if (n > max_body) return 413;
    return switch (class) {
        .health, .capabilities => if (method == .GET or method == .HEAD) 200 else 405,
        .ready => if (method == .GET or method == .HEAD) 503 else 405,
        .sandbox => 501,
        .exports, .operations, .images, .callbacks, .metrics, .unknown => 404,
    };
}

pub const MutationKind = enum {
    create_sandbox,
    destroy_sandbox,
    start_execution,
    cancel_execution,
    upload_file,
    reset,
    stop,
    start,
    pause,
    /// HTTP POST /v1/sandboxes/{id}/resume. Quoted because `resume` is a Zig keyword.
    @"resume",
    snapshot,
    restore,
    attach_mount,
    detach_mount,
    create_export,
    create_process,
    create_terminal,
    create_channel,
    guest_fetch,
    materialize_image,
    register_callback,
};

pub const PlannedRoute = struct {
    method: []const u8,
    path: []const u8,
    mutation: bool,
    requires_generation: bool,
    bootstrap_class: PathClass,
};

/// Assigned AP1 routes, including previously unassigned facade extensions.
pub const planned_routes = [_]PlannedRoute{
    .{ .method = "GET", .path = "/v1/capabilities", .mutation = false, .requires_generation = false, .bootstrap_class = .capabilities },
    .{ .method = "POST", .path = "/v1/sandboxes", .mutation = true, .requires_generation = false, .bootstrap_class = .sandbox },
    .{ .method = "GET", .path = "/v1/sandboxes", .mutation = false, .requires_generation = false, .bootstrap_class = .sandbox },
    .{ .method = "GET", .path = "/v1/sandboxes/{id}", .mutation = false, .requires_generation = false, .bootstrap_class = .sandbox },
    .{ .method = "DELETE", .path = "/v1/sandboxes/{id}", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/executions", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "GET", .path = "/v1/sandboxes/{id}/executions/{exec}", .mutation = false, .requires_generation = false, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/executions/{exec}/cancel", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "PUT", .path = "/v1/sandboxes/{id}/files", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "GET", .path = "/v1/sandboxes/{id}/files", .mutation = false, .requires_generation = false, .bootstrap_class = .sandbox },
    .{ .method = "GET", .path = "/v1/sandboxes/{id}/events", .mutation = false, .requires_generation = false, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/reset", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/stop", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/start", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/pause", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/resume", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/snapshots", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/restore", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/mounts", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "DELETE", .path = "/v1/sandboxes/{id}/mounts/{mount}", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/processes", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/terminals", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/channels", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "POST", .path = "/v1/sandboxes/{id}/fetch", .mutation = true, .requires_generation = true, .bootstrap_class = .sandbox },
    .{ .method = "GET", .path = "/v1/exports", .mutation = false, .requires_generation = false, .bootstrap_class = .exports },
    .{ .method = "POST", .path = "/v1/exports", .mutation = true, .requires_generation = false, .bootstrap_class = .exports },
    .{ .method = "GET", .path = "/v1/operations/{id}", .mutation = false, .requires_generation = false, .bootstrap_class = .operations },
    .{ .method = "POST", .path = "/v1/images/{id}/materialize", .mutation = true, .requires_generation = false, .bootstrap_class = .images },
    .{ .method = "POST", .path = "/v1/callbacks", .mutation = true, .requires_generation = false, .bootstrap_class = .callbacks },
    .{ .method = "DELETE", .path = "/v1/callbacks/{id}", .mutation = true, .requires_generation = false, .bootstrap_class = .callbacks },
};

pub const JsonError = error{
    InvalidJson,
    TooDeep,
    TooLarge,
    DuplicateField,
    UnknownField,
    UnexpectedType,
    MissingField,
    InvalidField,
    TrailingData,
};

fn jsonParseOptions() std.json.ParseOptions {
    return .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        // Whole-document bound is MAX_JSON_BYTES. Per-field UTF-8 and decoded
        // stdin limits are enforced after parse so encoded base64 can be larger
        // than the decoded payload.
        .max_value_len = MAX_JSON_BYTES,
    };
}

fn mapJsonErr(err: anyerror) JsonError {
    if (err == error.UnknownField) return error.UnknownField;
    if (err == error.DuplicateField) return error.DuplicateField;
    if (err == error.MissingField) return error.MissingField;
    if (err == error.UnexpectedToken) return error.UnexpectedType;
    if (err == error.ValueTooLong or err == error.Overflow or err == error.OutOfMemory) return error.TooLarge;
    if (err == error.LengthMismatch) return error.InvalidField;
    if (err == error.TooDeep) return error.TooDeep;
    if (err == error.TrailingData) return error.TrailingData;
    if (err == error.InvalidJson) return error.InvalidJson;
    if (err == error.TooLarge) return error.TooLarge;
    if (err == error.UnexpectedType) return error.UnexpectedType;
    if (err == error.InvalidField) return error.InvalidField;
    return error.InvalidJson;
}

fn scanBounded(src: []const u8) JsonError!void {
    if (src.len > MAX_JSON_BYTES) return error.TooLarge;
    var stack_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    var scanner = std.json.Scanner.initCompleteInput(fba.allocator(), src);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch |err| return mapJsonErr(err);
        if (scanner.stackHeight() > MAX_JSON_DEPTH) return error.TooDeep;
        switch (token) {
            .end_of_document => return,
            .null => return error.UnexpectedType,
            else => {},
        }
    }
}

fn parseContractJson(comptime T: type, allocator: std.mem.Allocator, src: []const u8) JsonError!std.json.Parsed(T) {
    try scanBounded(src);
    return std.json.parseFromSlice(T, allocator, src, jsonParseOptions()) catch |err| return mapJsonErr(err);
}

fn copyBounded(dst: []u8, src: []const u8) JsonError![]u8 {
    if (src.len > dst.len) return error.TooLarge;
    @memcpy(dst[0..src.len], src);
    return dst[0..src.len];
}

pub const ValidatedSandboxCreate = struct {
    profile: ProfileId,
    image_id: []const u8,
    image_digest: []const u8,
};

const SandboxCreateJson = struct {
    profile: []const u8,
    image: struct {
        id: []const u8,
        digest: []const u8,
    },
    limits: ?struct {
        vcpus: ?[]const u8 = null,
        memory_bytes: ?[]const u8 = null,
        workspace_bytes: ?[]const u8 = null,
        processes: ?[]const u8 = null,
        execution_timeout_ms: ?[]const u8 = null,
        session_ttl_seconds: ?[]const u8 = null,
        output_bytes: ?[]const u8 = null,
    } = null,
    network: ?struct {
        mode: []const u8,
    } = null,
    rootfs: ?struct {
        mode: []const u8,
        volume: ?[]const u8 = null,
    } = null,
};

pub fn validateSandboxCreate(json: []const u8, storage: *SandboxCreateStorage) JsonError!ValidatedSandboxCreate {
    var arena_buf: [MAX_JSON_BYTES + 8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const parsed = try parseContractJson(SandboxCreateJson, fba.allocator(), json);
    defer parsed.deinit();
    const body = parsed.value;
    const profile_raw = try copyBounded(&storage.profile, body.profile);
    const profile = parseProfileId(profile_raw) orelse return error.InvalidField;
    const image_id = try copyBounded(&storage.image_id, body.image.id);
    const digest = try copyBounded(&storage.digest, body.image.digest);
    if (!isOpaqueId(image_id) or !isImageDigest(digest)) return error.InvalidField;
    if (body.limits) |limits| {
        inline for (.{
            limits.vcpus,
            limits.memory_bytes,
            limits.workspace_bytes,
            limits.processes,
            limits.execution_timeout_ms,
            limits.session_ttl_seconds,
            limits.output_bytes,
        }) |field| {
            if (field) |s| {
                if (!isCanonicalDecimalU64(s)) return error.InvalidField;
            }
        }
    }
    if (body.network) |net| {
        if (!std.mem.eql(u8, net.mode, "offline")) return error.InvalidField;
    }
    if (body.rootfs) |rootfs| {
        if (!std.mem.eql(u8, rootfs.mode, "cow") and !std.mem.eql(u8, rootfs.mode, "ephemeral") and !std.mem.eql(u8, rootfs.mode, "persistent"))
            return error.InvalidField;
        if (rootfs.volume) |vol| {
            if (!isOpaqueId(vol)) return error.InvalidField;
        }
    }
    return .{ .profile = profile, .image_id = image_id, .image_digest = digest };
}

pub const SandboxCreateStorage = struct {
    profile: [MAX_STRING_BYTES]u8 = undefined,
    image_id: [MAX_ID_BYTES]u8 = undefined,
    digest: [80]u8 = undefined,
};

pub const ValidatedExecutionCreate = struct {
    generation: u64,
    argv_count: usize,
    has_stdin: bool = false,
    stdin_bytes: usize = 0,
};

pub const ExecutionCreateStorage = struct {
    generation: [20]u8 = undefined,
    argv: [MAX_ARGV][MAX_STRING_BYTES]u8 = undefined,
    argv_len: [MAX_ARGV]usize = undefined,
};

const ExecutionCreateJson = struct {
    generation: []const u8,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?std.json.Value = null,
    timeout_ms: ?[]const u8 = null,
    stdin_base64: ?[]const u8 = null,
};

pub fn validateExecutionCreate(json: []const u8, storage: *ExecutionCreateStorage) JsonError!ValidatedExecutionCreate {
    var arena_buf: [MAX_JSON_BYTES + 8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const parsed = try parseContractJson(ExecutionCreateJson, fba.allocator(), json);
    defer parsed.deinit();
    const body = parsed.value;
    const gen_s = try copyBounded(&storage.generation, body.generation);
    const generation = parseDecimalU64(gen_s) catch return error.InvalidField;
    if (generation < 1) return error.InvalidField;
    if (body.argv.len == 0) return error.InvalidField;
    if (body.argv.len > MAX_ARGV) return error.TooLarge;
    for (body.argv, 0..) |arg, i| {
        if (arg.len == 0 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidField;
        const copied = try copyBounded(&storage.argv[i], arg);
        storage.argv_len[i] = copied.len;
    }
    if (body.cwd) |cwd| {
        if (!isGuestPath(cwd)) return error.InvalidField;
    }
    if (body.timeout_ms) |ts| {
        if (!isCanonicalDecimalU64(ts)) return error.InvalidField;
    }
    if (body.env) |env_val| {
        try validateEnvValue(env_val);
    }
    var has_stdin = false;
    var stdin_bytes: usize = 0;
    if (body.stdin_base64) |b64| {
        stdin_bytes = try decodedStdinLen(b64);
        has_stdin = true;
    }
    return .{
        .generation = generation,
        .argv_count = body.argv.len,
        .has_stdin = has_stdin,
        .stdin_bytes = stdin_bytes,
    };
}

fn validateEnvValue(v: std.json.Value) JsonError!void {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.UnexpectedType,
    };
    if (obj.count() > MAX_ENV) return error.TooLarge;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!isEnvName(entry.key_ptr.*)) return error.InvalidField;
        switch (entry.value_ptr.*) {
            .string => |s| {
                if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidField;
            },
            else => return error.UnexpectedType,
        }
    }
}

fn isStandardBase64(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s.len % 4 != 0) return false;
    var pad: usize = 0;
    for (s) |c| {
        if (c == '=') {
            pad += 1;
            if (pad > 2) return false;
            continue;
        }
        if (pad != 0) return false;
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '+' or c == '/';
        if (!ok) return false;
    }
    return true;
}

fn decodedStdinLen(s: []const u8) JsonError!usize {
    if (!isStandardBase64(s)) return error.InvalidField;
    if (s.len == 0) return 0;
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(s) catch return error.InvalidField;
    if (n > MAX_STRING_BYTES) return error.TooLarge;
    var tmp: [MAX_STRING_BYTES]u8 = undefined;
    decoder.decode(tmp[0..n], s) catch return error.InvalidField;
    return n;
}

fn isEnvName(s: []const u8) bool {
    if (s.len == 0) return false;
    const c0 = s[0];
    if (!((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z') or c0 == '_')) return false;
    for (s[1..]) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

pub fn isGuestPath(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_PATH_BYTES) return false;
    if (s[0] != '/') return false;
    if (std.mem.indexOfScalar(u8, s, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, s, '\\') != null) return false;
    if (s.len >= 2 and s[1] == '/') return false;
    var start: usize = 1;
    while (start <= s.len) {
        const slash = indexOfPos(s, start, '/') orelse s.len;
        const seg = s[start..slash];
        if (seg.len == 0 and slash != s.len) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        if (slash == s.len) break;
        start = slash + 1;
    }
    return true;
}

fn indexOfPos(hay: []const u8, start: usize, c: u8) ?usize {
    var i = start;
    while (i < hay.len) : (i += 1) if (hay[i] == c) return i;
    return null;
}

pub const MutationHeaders = struct {
    idempotency_key: []const u8,
    generation: ?[]const u8 = null,
};

pub fn validateMutationHeaders(headers: MutationHeaders, requires_generation: bool) error{InvalidRequest}!void {
    if (!isIdempotencyKey(headers.idempotency_key)) return error.InvalidRequest;
    if (requires_generation) {
        const gen = headers.generation orelse return error.InvalidRequest;
        if (!isGeneration(gen)) return error.InvalidRequest;
    } else if (headers.generation) |gen| {
        if (!isGeneration(gen)) return error.InvalidRequest;
    }
}

pub const FingerprintInput = struct {
    principal: []const u8,
    method: []const u8,
    canonical_route: []const u8,
    canonical_query: []const u8,
    expected_generation: []const u8,
    content_type: []const u8,
    body: []const u8,
};

pub fn mutationFingerprint(input: FingerprintInput) [32]u8 {
    var body_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input.body, &body_hash, .{});
    var body_hex: [64]u8 = undefined;
    _ = hexLower(&body_hex, &body_hash);
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    h.update(input.principal);
    h.update("\n");
    h.update(input.method);
    h.update("\n");
    h.update(input.canonical_route);
    h.update("\n");
    h.update(input.canonical_query);
    h.update("\n");
    h.update(input.expected_generation);
    h.update("\n");
    h.update(input.content_type);
    h.update("\n");
    h.update(&body_hex);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn hexLower(out: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        out[i * 2] = digits[bytes[i] >> 4];
        out[i * 2 + 1] = digits[bytes[i] & 0x0f];
    }
    return out[0 .. bytes.len * 2];
}

pub fn sameFingerprintConflict(a: [32]u8, b: [32]u8) bool {
    return !std.mem.eql(u8, &a, &b);
}

pub const LifecycleState = enum {
    creating,
    ready,
    busy,
    pausing,
    paused,
    resuming,
    stopping,
    stopped,
    starting,
    resetting,
    recovering,
    failed,
    expired,
    destroying,
    destroyed,

    pub fn text(self: LifecycleState) []const u8 {
        return @tagName(self);
    }
};

pub fn parseLifecycleState(s: []const u8) ?LifecycleState {
    return std.meta.stringToEnum(LifecycleState, s);
}

pub const JsonStatus = struct {
    code: CanonicalCode,
    retryable: bool,
};

pub fn jsonErrorStatus(err: JsonError) JsonStatus {
    const code: CanonicalCode = switch (err) {
        error.TooLarge => .payload_too_large,
        error.UnknownField, error.DuplicateField, error.UnexpectedType, error.MissingField, error.InvalidField, error.InvalidJson, error.TrailingData, error.TooDeep => .invalid_request,
    };
    return .{ .code = code, .retryable = false };
}

test "decimal u64 accepts canonical values including above JS safe integer" {
    try std.testing.expectEqual(@as(u64, 0), try parseDecimalU64("0"));
    try std.testing.expectEqual(@as(u64, 1), try parseDecimalU64("1"));
    try std.testing.expectEqual(@as(u64, 9007199254740993), try parseDecimalU64("9007199254740993"));
    try std.testing.expectEqual(~@as(u64, 0), try parseDecimalU64("18446744073709551615"));
}

test "decimal u64 rejects noncanonical spellings" {
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64(""));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("01"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("-1"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("+1"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("1.0"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("1e2"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("1E2"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64(" 1"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("1 "));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("0x10"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("18446744073709551616"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("00"));
    try std.testing.expect(isCanonicalDecimalU64("0"));
    try std.testing.expect(isCanonicalDecimalU64("18446744073709551615"));
    try std.testing.expect(!isCanonicalDecimalU64("01"));
    try std.testing.expect(!isCanonicalDecimalU64("-1"));
    try std.testing.expect(!isCanonicalDecimalU64(""));
    try std.testing.expect(!isCanonicalDecimalU64("99999999999999999999"));
    try std.testing.expect(isCanonicalDecimalU64("9999999999999999999"));
    try std.testing.expect(isCanonicalDecimalU64("10000000000000000000"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("18446744073709551616"));
    try std.testing.expectError(error.InvalidDecimalU64, parseDecimalU64("18999999999999999999"));
}

test "opaque ids reject numeric spellings" {
    try std.testing.expect(isOpaqueId("sbx_1"));
    try std.testing.expect(isOpaqueId("evt:01HABC"));
    try std.testing.expect(!isOpaqueId("12345"));
    try std.testing.expect(!isOpaqueId(""));
    try std.testing.expect(!isOpaqueId("bad id"));
    try std.testing.expect(isIdempotencyKey("idem-key-1"));
    try std.testing.expect(!isIdempotencyKey("short"));
    try std.testing.expect(isGeneration("1"));
    try std.testing.expect(!isGeneration("0"));
    try std.testing.expect(!isEventCursor("0"));
    try std.testing.expect(isEventCursor("cur_1"));
}

test "diagnostic and canonical envelopes are distinct documents" {
    try std.testing.expect(isDiagnosticEnvelope(diagnostic_execution_unavailable_json));
    try std.testing.expect(!isCanonicalEnvelope(diagnostic_execution_unavailable_json));
    var buf: [256]u8 = undefined;
    const canonical = try writeCanonicalError(&buf, .{
        .code = .unsupported,
        .message = "the selected Linux VM provider is not available",
        .request_id = "req_test1",
        .retryable = false,
    });
    try std.testing.expect(isCanonicalEnvelope(canonical));
    try std.testing.expect(!isDiagnosticEnvelope(canonical));
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"code\":\"unsupported\"") != null);
    try std.testing.expectEqual(@as(u16, 501), CanonicalCode.unsupported.httpStatus());
    try std.testing.expect(!CanonicalCode.unsupported.retryable());
    try std.testing.expectEqual(CanonicalCode.unsupported, diagnosticToCanonical(.execution_unavailable));
}

test "empty inventory never advertises execution" {
    try std.testing.expect(!inventoryAdvertisesExecution(.{}));
    const caps = capabilitiesFromInventory(.{});
    try std.testing.expect(!caps.execution);
    try std.testing.expect(!caps.pause_resume);
    const incomplete = ProviderRecord{
        .kind = .qemu_kvm,
        .profile = .linux_vm_x64,
        .image_digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .pause_resume = false,
        .qualified = true,
    };
    try std.testing.expect(!inventoryAdvertisesExecution(.{ .providers = &.{incomplete} }));
    const native_only = ProviderRecord{
        .kind = .qemu_whpx,
        .profile = .native_windows_x64,
        .image_digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .pause_resume = true,
        .qualified = true,
    };
    try std.testing.expect(!inventoryAdvertisesExecution(.{ .providers = &.{native_only} }));
}

test "qualified linux-vm inventory is not enough to advertise execution features" {
    const rec = ProviderRecord{
        .kind = .qemu_kvm,
        .profile = .linux_vm_x64,
        .image_digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .pause_resume = true,
        .qualified = true,
    };
    const inventory = ProviderInventory{ .providers = &.{rec} };
    try std.testing.expect(inventoryAdvertisesExecution(inventory));
    const from_inventory = capabilitiesFromInventory(inventory);
    try std.testing.expect(!from_inventory.execution);
    try std.testing.expect(!from_inventory.pty);
    try std.testing.expect(!from_inventory.channels);
    try std.testing.expect(!from_inventory.sse);
    try std.testing.expect(!from_inventory.pause_resume);
    const digest = rec.image_digest;
    const full = CompositionEvidence{
        .inventory = inventory,
        .auth = true,
        .store = true,
        .launcher = true,
        .guest = true,
        .policy = true,
        .clock = true,
        .entropy = true,
        .image_registry = true,
        .lifecycle = true,
        .vm_ready = true,
        .vm_kind = .qemu_kvm,
        .vm_version = CONTRACT_VERSION,
        .vm_pause_resume = true,
        .vm_profile = .linux_vm_x64,
        .vm_image_digest = digest,
        .pty = true,
        .channels = true,
        .sse = true,
    };
    const missing_auth = capabilitiesFromComposition(blk: {
        var ev = full;
        ev.auth = false;
        break :blk ev;
    });
    try std.testing.expect(!missing_auth.execution);
    try std.testing.expect(!missing_auth.pty);
    try std.testing.expect(!missing_auth.sse);
    const missing_lifecycle = capabilitiesFromComposition(blk: {
        var ev = full;
        ev.lifecycle = false;
        break :blk ev;
    });
    try std.testing.expect(!missing_lifecycle.execution);
    const missing_pause = capabilitiesFromComposition(blk: {
        var ev = full;
        ev.vm_pause_resume = false;
        break :blk ev;
    });
    try std.testing.expect(!missing_pause.execution);
    try std.testing.expect(!missing_pause.pause_resume);
    const unbound_vm = capabilitiesFromComposition(blk: {
        var ev = full;
        ev.vm_ready = false;
        break :blk ev;
    });
    try std.testing.expect(!unbound_vm.execution);
    const wrong_kind = capabilitiesFromComposition(blk: {
        var ev = full;
        ev.vm_kind = .qemu_whpx;
        break :blk ev;
    });
    try std.testing.expect(!wrong_kind.execution);
    const wrong_profile = capabilitiesFromComposition(blk: {
        var ev = full;
        ev.vm_profile = .linux_vm_arm64;
        break :blk ev;
    });
    try std.testing.expect(!wrong_profile.execution);
    const wrong_image = capabilitiesFromComposition(blk: {
        var ev = full;
        ev.vm_image_digest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
        break :blk ev;
    });
    try std.testing.expect(!wrong_image.execution);
    const composed = capabilitiesFromComposition(full);
    try std.testing.expect(composed.execution);
    try std.testing.expect(composed.pty);
    try std.testing.expect(composed.pause_resume);
    const flags_without_exec = capabilitiesFromComposition(.{
        .pty = true,
        .channels = true,
        .sse = true,
        .snapshots = true,
    });
    try std.testing.expect(!flags_without_exec.execution);
    try std.testing.expect(!flags_without_exec.pty);
    try std.testing.expect(!flags_without_exec.channels);
    try std.testing.expect(!flags_without_exec.sse);
    const bad_version = capabilitiesFromComposition(blk: {
        var ev = full;
        ev.vm_version = "0";
        break :blk ev;
    });
    try std.testing.expect(!bad_version.execution);
    try std.testing.expect(!bad_version.pty);
    var cap_buf: [2048]u8 = undefined;
    const truthful = try writeCanonicalCapabilities(&cap_buf, .{
        .features = composed,
        .inventory = inventory,
        .bound_kind = .qemu_kvm,
        .bound_profile = .linux_vm_x64,
        .bound_image_digest = digest,
    });
    try std.testing.expect(std.mem.indexOf(u8, truthful, "\"kind\":\"qemu-kvm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, truthful, "\"execution\":true") != null);
    try std.testing.expectError(error.UntruthfulCapabilities, writeCanonicalCapabilities(&cap_buf, .{
        .features = .{ .execution = true, .pty = true },
        .inventory = .{},
    }));
    try std.testing.expectError(error.UntruthfulCapabilities, writeCanonicalCapabilities(&cap_buf, .{
        .features = .{ .execution = true },
        .inventory = inventory,
        .bound_kind = .qemu_kvm,
        .bound_profile = .linux_vm_x64,
        .bound_image_digest = digest,
    }));
    try std.testing.expectError(error.UntruthfulCapabilities, writeCanonicalCapabilities(&cap_buf, .{
        .features = .{ .execution = true, .auth = true, .durable_store = true, .pause_resume = true },
        .inventory = inventory,
        .bound_kind = .qemu_whpx,
        .bound_profile = .linux_vm_x64,
        .bound_image_digest = digest,
    }));
    const empty_written = try writeCanonicalCapabilities(&cap_buf, .{ .features = .{}, .inventory = .{} });
    try std.testing.expect(std.mem.indexOf(u8, empty_written, "\"backends\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_written, "\"providers\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_written, "\"execution\":false") != null);
}

test "sandbox create rejects unknown fields, numeric generation-like values, and bad profiles" {
    var storage = SandboxCreateStorage{};
    const ok =
        \\{"profile":"linux-vm/x64","image":{"id":"linux-dev-v1","digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}
    ;
    const got = try validateSandboxCreate(ok, &storage);
    try std.testing.expect(got.profile == .linux_vm_x64);
    try std.testing.expectError(error.UnknownField, validateSandboxCreate(
        \\{"profile":"linux-vm/x64","image":{"id":"linux-dev-v1","digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"owner":"alice"}
    , &storage));
    try std.testing.expectError(error.InvalidField, validateSandboxCreate(
        \\{"profile":"windows-pe/x64","image":{"id":"linux-dev-v1","digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}
    , &storage));
    try std.testing.expectError(error.UnexpectedType, validateSandboxCreate(
        \\{"profile":"linux-vm/x64","image":{"id":"linux-dev-v1","digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"limits":{"vcpus":1}}
    , &storage));
}

test "execution create requires decimal-string generation and argv" {
    var storage = ExecutionCreateStorage{};
    const ok =
        \\{"generation":"1","argv":["/bin/sh","-lc","true"]}
    ;
    const got = try validateExecutionCreate(ok, &storage);
    try std.testing.expectEqual(@as(u64, 1), got.generation);
    try std.testing.expectEqual(@as(usize, 3), got.argv_count);
    try std.testing.expectError(error.UnexpectedType, validateExecutionCreate(
        \\{"generation":1,"argv":["/bin/sh"]}
    , &storage));
    try std.testing.expectError(error.InvalidField, validateExecutionCreate(
        \\{"generation":"01","argv":["/bin/sh"]}
    , &storage));
    try std.testing.expectError(error.InvalidField, validateExecutionCreate(
        \\{"generation":"1","argv":[]}
    , &storage));
}

test "execution create rejects invalid json type and base64 for stdin" {
    var storage = ExecutionCreateStorage{};
    try std.testing.expectError(error.InvalidJson, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/sh"],"stdin_base64":1e+}
    , &storage));
    try std.testing.expectError(error.UnexpectedType, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/sh"],"stdin_base64":1}
    , &storage));
    try std.testing.expectError(error.InvalidField, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/sh"],"stdin_base64":"***"}
    , &storage));
    try std.testing.expectError(error.InvalidField, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/sh"],"stdin_base64":"YQ"}
    , &storage));
    const ok = try validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/sh"],"stdin_base64":"Zg=="}
    , &storage);
    try std.testing.expect(ok.has_stdin);
    try std.testing.expectEqual(@as(usize, 1), ok.stdin_bytes);
}

test "execution create accepts unicode escapes and rejects lone surrogates" {
    var storage = ExecutionCreateStorage{};
    const got = try validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/\u0073h"],"cwd":"/workspace/\u0041"}
    , &storage);
    try std.testing.expectEqual(@as(usize, 1), got.argv_count);
    try std.testing.expect(std.mem.eql(u8, storage.argv[0][0..storage.argv_len[0]], "/bin/sh"));
    const emoji = try validateExecutionCreate(
        \\{"generation":"1","argv":["/workspace/\ud83d\ude00"]}
    , &storage);
    try std.testing.expectEqual(@as(usize, 1), emoji.argv_count);
    try std.testing.expectError(error.InvalidJson, validateExecutionCreate(
        \\{"generation":"1","argv":["\ud83d"]}
    , &storage));
}

test "execution create rejects duplicate keys trailing data and incomplete json" {
    var storage = ExecutionCreateStorage{};
    try std.testing.expectError(error.DuplicateField, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/sh"],"generation":"2"}
    , &storage));
    try std.testing.expectError(error.InvalidJson, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/sh"]} trailing
    , &storage));
    try std.testing.expectError(error.InvalidJson, validateExecutionCreate("{", &storage));
    try std.testing.expectError(error.TooDeep, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/sh"],"env":{"A":{"B":{"C":{"D":{"E":{"F":{"G":{"H":{"I":{"J":"x"}}}}}}}}}}}
    , &storage));
    try std.testing.expectError(error.UnexpectedType, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/true"],"cwd":null}
    , &storage));
    try std.testing.expectError(error.UnexpectedType, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/true"],"stdin_base64":null}
    , &storage));
    try std.testing.expectError(error.UnexpectedType, validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/true"],"timeout_ms":null}
    , &storage));
    const omitted = try validateExecutionCreate(
        \\{"generation":"1","argv":["/bin/true"]}
    , &storage);
    try std.testing.expect(!omitted.has_stdin);
}

test "canonical error detail is structured and cannot break the object" {
    var buf: [512]u8 = undefined;
    const injected = "\"},\"code\":\"forged";
    try std.testing.expectError(error.InvalidCanonicalError, writeCanonicalError(&buf, .{
        .code = .invalid_request,
        .message = "invalid field",
        .request_id = "req_detail1",
        .retryable = false,
        .detail = .{ .entries = &.{.{ .name = "field\":1,\"code\":\"forged", .value = .{ .string = "x" } }} },
    }));
    const written = try writeCanonicalError(&buf, .{
        .code = .invalid_request,
        .message = "invalid field",
        .request_id = "req_detail1",
        .retryable = false,
        .detail = .{ .entries = &.{.{ .name = "field", .value = .{ .string = injected } }} },
    });
    try std.testing.expect(isCanonicalEnvelope(written));
    try std.testing.expect(!isDiagnosticEnvelope(written));
    try std.testing.expect(std.mem.indexOf(u8, written, "\"code\":\"invalid_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"code\":\"forged\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\\\"},\\\"code\\\":\\\"forged") != null);
    try std.testing.expectError(error.InvalidCanonicalError, writeCanonicalError(&buf, .{
        .code = .invalid_request,
        .message = "invalid field",
        .request_id = "req_detail1",
        .retryable = false,
        .detail = .{ .entries = &.{.{ .name = "n", .value = .{ .decimal = "01" } }} },
    }));
}

test "guest paths reject traversal and host spellings" {
    try std.testing.expect(isGuestPath("/workspace/tool"));
    try std.testing.expect(!isGuestPath("workspace/tool"));
    try std.testing.expect(!isGuestPath("/workspace/../etc/passwd"));
    try std.testing.expect(!isGuestPath("/workspace/./x"));
    try std.testing.expect(!isGuestPath("C:/Windows"));
    try std.testing.expect(!isGuestPath("//host/share"));
}

test "mutation fingerprint is principal-scoped and body-sensitive" {
    const a = mutationFingerprint(.{
        .principal = "spiffe://example/sa/a",
        .method = "POST",
        .canonical_route = "/v1/sandboxes",
        .canonical_query = "",
        .expected_generation = "",
        .content_type = "application/json",
        .body = "{}",
    });
    const b = mutationFingerprint(.{
        .principal = "spiffe://example/sa/b",
        .method = "POST",
        .canonical_route = "/v1/sandboxes",
        .canonical_query = "",
        .expected_generation = "",
        .content_type = "application/json",
        .body = "{}",
    });
    const c = mutationFingerprint(.{
        .principal = "spiffe://example/sa/a",
        .method = "POST",
        .canonical_route = "/v1/sandboxes",
        .canonical_query = "",
        .expected_generation = "",
        .content_type = "application/json",
        .body = "{\"x\":1}",
    });
    try std.testing.expect(sameFingerprintConflict(a, b));
    try std.testing.expect(sameFingerprintConflict(a, c));
    var empty_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &empty_hash, .{});
    var hex: [64]u8 = undefined;
    const got = hexLower(&hex, &empty_hash);
    try std.testing.expect(std.mem.eql(u8, got, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
}

test "planned sandbox extension routes classify as sandbox 501 in bootstrap" {
    try std.testing.expect(classifyPath("/v1/sandboxes/s1/processes") == .sandbox);
    try std.testing.expect(classifyPath("/v1/sandboxes/s1/terminals") == .sandbox);
    try std.testing.expect(classifyPath("/v1/sandboxes/s1/channels") == .sandbox);
    try std.testing.expect(classifyPath("/v1/sandboxes/s1/fetch") == .sandbox);
    try std.testing.expect(classifyPath("/v1/exports") == .exports);
    try std.testing.expect(classifyPath("/v1/operations/op_1") == .operations);
    try std.testing.expect(classifyPath("/v1/images/img/materialize") == .images);
    try std.testing.expect(classifyPath("/v1/callbacks") == .callbacks);
    try std.testing.expectEqual(@as(u16, 501), bootstrapStatus(.sandbox, .POST, null, 1024 * 1024));
    try std.testing.expectEqual(@as(u16, 404), bootstrapStatus(.exports, .GET, null, 1024 * 1024));
    try std.testing.expectEqual(@as(u16, 413), bootstrapStatus(.sandbox, .POST, 1024 * 1024 + 1, 1024 * 1024));
}

test "missing idempotency key is invalid_request in the production contract" {
    try std.testing.expectError(error.InvalidRequest, validateMutationHeaders(.{ .idempotency_key = "short" }, false));
    try validateMutationHeaders(.{ .idempotency_key = "idem-key-1" }, false);
    try std.testing.expectError(error.InvalidRequest, validateMutationHeaders(.{ .idempotency_key = "idem-key-1" }, true));
    try validateMutationHeaders(.{ .idempotency_key = "idem-key-1", .generation = "2" }, true);
}

test "canonical status mapping covers required classes" {
    try std.testing.expectEqual(@as(u16, 401), CanonicalCode.unauthenticated.httpStatus());
    try std.testing.expectEqual(@as(u16, 403), CanonicalCode.forbidden.httpStatus());
    try std.testing.expectEqual(@as(u16, 409), CanonicalCode.stale_generation.httpStatus());
    try std.testing.expectEqual(@as(u16, 409), CanonicalCode.idempotency_conflict.httpStatus());
    try std.testing.expectEqual(@as(u16, 410), CanonicalCode.cursor_expired.httpStatus());
    try std.testing.expectEqual(@as(u16, 422), CanonicalCode.unsupported_host.httpStatus());
    try std.testing.expectEqual(@as(u16, 429), CanonicalCode.limit.httpStatus());
    try std.testing.expectEqual(@as(u16, 501), CanonicalCode.unsupported.httpStatus());
    try std.testing.expectEqual(@as(u16, 503), CanonicalCode.capacity.httpStatus());
    try std.testing.expect(!CanonicalCode.unauthenticated.retryable());
    try std.testing.expect(CanonicalCode.unavailable.retryable());
}
