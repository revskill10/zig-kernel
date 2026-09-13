//! Swappable sandbox subsystem contracts.
//!
//! Runtime selection happens once at process start from validated config.
//! Callers import these contracts, not concrete adapters. Every adapter is
//! unavailable by default and must not advertise production execution.
//!
//! Lifetimes:
//! - Context pointers passed to `bind` are borrowed. The referent must outlive
//!   the seam value. Bind copies function pointers and does not take ownership.
//! - Request slices (paths, principal ids, digests, lease ids, headers) are
//!   borrowed for the duration of the call.
//! - Handles (`TxHandle`, `VmInstance`, `LeaseHandle`, and similar) are
//!   adapter-owned identifiers. Callers must not free them; they remain valid
//!   until commit/rollback/stop as documented by the adapter.
//! Result slices are usable after the call returns. Each result names its
//! storage and the later operation that ends that guarantee:
//! - `Principal.id` has two supported storage paths:
//!   - Request-backed: borrowed from `AuthMaterial` (`mtls_peer`, or
//!     `local_peer.token` when present). Valid until those request slices
//!     are mutated or released. Callers that need a longer lifetime must copy.
//!   - Adapter-backed: pid-only local IPC (`local_peer.pid != 0` and empty
//!     token) returns adapter identity storage. Valid after authenticate
//!     until that storage is overwritten or the adapter is rebound. The fake
//!     writes `AllowBox.local_id_buf`; named invalidation is overwriting that
//!     buffer (including a later pid-only authenticate) or rebinding.
//! - `ReplayRecord.payload` is borrowed from adapter durable store. It remains
//!   valid after `commit` until the adapter overwrites that idempotency
//!   record or the store is rebound. It is not transaction-scratch storage.
//! - `ResolvedImage.digest` is borrowed from the `resolve` request argument
//!   and remains valid until that argument is mutated or released.
//! - `EventCursor.cursor` and `CallbackId.id` are borrowed from adapter
//!   session storage and remain valid until the next subscribe/register on
//!   the same adapter or the adapter is rebound.
//! - Filesystem `read`, clock `bootId`, entropy `fill`, and secret `resolve`
//!   write into caller-provided buffers. `ReadResult.bytes` counts that prefix.
const std = @import("std");
const contract = @import("sandbox_contract");

pub const AdapterError = error{
    Unsupported,
    Unauthenticated,
    Denied,
    NotFound,
    Stale,
    Conflict,
    Capacity,
    Io,
    Unavailable,
    Invalid,
};

pub fn adapterRetryable(err: AdapterError) bool {
    return switch (err) {
        error.Capacity, error.Io, error.Unavailable => true,
        else => false,
    };
}

pub fn adapterCanonical(err: AdapterError) contract.CanonicalCode {
    return switch (err) {
        error.Unsupported => .unsupported,
        error.Unauthenticated => .unauthenticated,
        error.Denied => .forbidden,
        error.NotFound => .not_found,
        error.Stale => .stale_generation,
        error.Conflict => .conflict,
        error.Capacity => .capacity,
        error.Io, error.Unavailable => .unavailable,
        error.Invalid => .invalid_request,
    };
}

pub const CapabilityMeta = struct {
    name: []const u8,
    version: []const u8,
    available: bool = false,
};

pub fn unavailableMeta(name: []const u8) CapabilityMeta {
    return .{ .name = name, .version = contract.CONTRACT_VERSION, .available = false };
}

pub fn qualifiedMeta(name: []const u8) CapabilityMeta {
    return .{ .name = name, .version = contract.CONTRACT_VERSION, .available = true };
}

pub fn validateBind(meta: CapabilityMeta, expected_name: []const u8, context: ?*const anyopaque) AdapterError!void {
    if (context == null) return error.Unsupported;
    if (!meta.available) return error.Unsupported;
    if (!std.mem.eql(u8, meta.name, expected_name)) return error.Unsupported;
    if (!std.mem.eql(u8, meta.version, contract.CONTRACT_VERSION)) return error.Unsupported;
}

fn adapterReady(meta: CapabilityMeta, expected_name: []const u8, bound: bool, context: ?*const anyopaque) bool {
    return bound and context != null and meta.available and
        std.mem.eql(u8, meta.name, expected_name) and
        std.mem.eql(u8, meta.version, contract.CONTRACT_VERSION);
}

pub const TransportKind = enum { mutual_tls, local_ipc, unknown };

pub const LocalPeer = struct {
    pid: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    token: []const u8 = "",
};

/// Listener-verified authentication material. `client_identity_header` is
/// recorded only so adapters can ignore it; it must never authenticate.
pub const AuthMaterial = struct {
    transport: TransportKind = .unknown,
    mtls_peer: []const u8 = "",
    local_peer: LocalPeer = .{},
    client_identity_header: []const u8 = "",
};

/// `id` is request-backed from authenticate `AuthMaterial` (`mtls_peer`, or
/// `local_peer.token` when present) until those slices are mutated or released.
/// Pid-only local IPC (`local_peer.pid != 0` and empty token) is a supported
/// adapter-backed path: `id` is borrowed from adapter identity storage and
/// remains valid until that storage is overwritten or the adapter is rebound.
pub const Principal = struct {
    id: []const u8 = "",
    transport: TransportKind = .unknown,
};

pub const Action = struct {
    name: []const u8 = "",
};

pub const ResourceRef = struct {
    kind: []const u8 = "",
    id: []const u8 = "",
};

pub const Admission = struct {
    principal: Principal = .{},
    action: Action = .{},
    resource: ResourceRef = .{},
};

pub const TxHandle = struct {
    id: u64 = 0,
    generation: u64 = 0,
};

pub const ReplayOutcome = enum { miss, replay, conflict };

/// `payload` is borrowed from adapter durable storage and remains valid after
/// `commit` until that idempotency record is overwritten or the store is rebound.
pub const ReplayRecord = struct {
    outcome: ReplayOutcome = .miss,
    payload: []const u8 = "",
};

pub const FsKind = enum { none, guest_disk, sqlitefs, host_export };

pub const FsNodeKind = enum { file, dir, symlink, other };

pub const FsStat = struct {
    kind: FsNodeKind = .file,
    size: u64 = 0,
    mtime_unix: u64 = 0,
};

pub const ByteRange = struct {
    offset: u64 = 0,
    length: u64 = 0,
};

pub const ReadResult = struct {
    bytes: usize = 0,
    eof: bool = true,
};

pub const LeaseHandle = struct {
    id: u64 = 0,
    fence: u64 = 0,
};

pub const VmLease = struct {
    id: []const u8 = "",
    fence: u64 = 0,
};

pub const VmBootSpec = struct {
    image_digest: []const u8 = "",
    profile: contract.ProfileId = .linux_vm_x64,
    config: []const u8 = "",
    lease: VmLease = .{},
};

pub const VmInstance = struct {
    id: u64 = 0,
    fence: u64 = 0,
};

pub const LifecycleObject = struct {
    id: u64 = 0,
    state: contract.LifecycleState = .creating,
};

/// `digest` is borrowed from the `resolve` request argument.
pub const ResolvedImage = struct {
    digest: []const u8 = "",
    size: u64 = 0,
};

pub const MountHandle = struct { id: u64 = 0 };
pub const ExportHandle = struct { id: u64 = 0 };
pub const PtyHandle = struct { id: u64 = 0 };
pub const ChannelHandle = struct { id: u64 = 0 };
/// `cursor` is borrowed from adapter session storage until the next subscribe or rebind.
pub const EventCursor = struct { cursor: []const u8 = "" };
/// `id` is borrowed from adapter session storage until the next register or rebind.
pub const CallbackId = struct { id: []const u8 = "" };

fn unsupportedTime(_: ?*const anyopaque) AdapterError!u64 {
    return error.Unsupported;
}
fn unsupportedBootId(_: ?*const anyopaque, _: []u8) AdapterError!usize {
    return error.Unsupported;
}
fn unsupportedFill(_: ?*const anyopaque, _: []u8) AdapterError!void {
    return error.Unsupported;
}
fn unsupportedAuthN(_: ?*const anyopaque, _: AuthMaterial) AdapterError!Principal {
    return error.Unsupported;
}
fn unsupportedAuthZ(_: ?*const anyopaque, _: Principal, _: Action, _: ResourceRef) AdapterError!void {
    return error.Unsupported;
}
fn unsupportedBegin(_: ?*const anyopaque) AdapterError!TxHandle {
    return error.Unsupported;
}
fn unsupportedTx(_: ?*const anyopaque, _: TxHandle) AdapterError!void {
    return error.Unsupported;
}
fn unsupportedReplay(_: ?*const anyopaque, _: TxHandle, _: []const u8, _: []const u8) AdapterError!ReplayRecord {
    return error.Unsupported;
}
fn unsupportedAdmit(_: ?*const anyopaque, _: Admission) AdapterError!void {
    return error.Unsupported;
}
fn unsupportedLease(_: ?*const anyopaque) AdapterError!LeaseHandle {
    return error.Unsupported;
}
fn unsupportedRevert(_: ?*const anyopaque, _: LeaseHandle) AdapterError!void {
    return error.Unsupported;
}
fn unsupportedStat(_: ?*const anyopaque, _: []const u8) AdapterError!FsStat {
    return error.Unsupported;
}
fn unsupportedRead(_: ?*const anyopaque, _: []const u8, _: ByteRange, _: []u8) AdapterError!ReadResult {
    return error.Unsupported;
}
fn unsupportedWrite(_: ?*const anyopaque, _: []const u8, _: ByteRange, _: []const u8) AdapterError!usize {
    return error.Unsupported;
}
fn unsupportedMount(_: ?*const anyopaque, _: []const u8) AdapterError!MountHandle {
    return error.Unsupported;
}
fn unsupportedConnect(_: ?*const anyopaque, _: []const u8) AdapterError!void {
    return error.Unsupported;
}
fn unsupportedBoot(_: ?*const anyopaque, _: VmBootSpec) AdapterError!VmInstance {
    return error.Unsupported;
}
fn unsupportedVmOp(_: ?*const anyopaque, _: VmInstance) AdapterError!void {
    return error.Unsupported;
}
fn unsupportedLifeCreate(_: ?*const anyopaque) AdapterError!LifecycleObject {
    return error.Unsupported;
}
fn unsupportedLifeDestroy(_: ?*const anyopaque, _: LifecycleObject) AdapterError!void {
    return error.Unsupported;
}
fn unsupportedResolveImage(_: ?*const anyopaque, _: []const u8) AdapterError!ResolvedImage {
    return error.Unsupported;
}
fn unsupportedExport(_: ?*const anyopaque) AdapterError!ExportHandle {
    return error.Unsupported;
}
fn unsupportedAttach(_: ?*const anyopaque, _: ExportHandle, _: MountHandle) AdapterError!void {
    return error.Unsupported;
}
fn unsupportedSecret(_: ?*const anyopaque, _: []const u8, _: []u8) AdapterError!usize {
    return error.Unsupported;
}
fn unsupportedPty(_: ?*const anyopaque) AdapterError!PtyHandle {
    return error.Unsupported;
}
fn unsupportedChannel(_: ?*const anyopaque) AdapterError!ChannelHandle {
    return error.Unsupported;
}
fn unsupportedSubscribe(_: ?*const anyopaque) AdapterError!EventCursor {
    return error.Unsupported;
}
fn unsupportedCallback(_: ?*const anyopaque) AdapterError!CallbackId {
    return error.Unsupported;
}
fn unsupportedMetric(_: ?*const anyopaque, _: []const u8) AdapterError!void {
    return error.Unsupported;
}

pub const Clock = struct {
    meta: CapabilityMeta = unavailableMeta("clock"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    monotonic_nanos_fn: *const fn (?*const anyopaque) AdapterError!u64 = unsupportedTime,
    boot_id_fn: *const fn (?*const anyopaque, []u8) AdapterError!usize = unsupportedBootId,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        monotonic_nanos_fn: *const fn (?*const anyopaque) AdapterError!u64,
        boot_id_fn: *const fn (?*const anyopaque, []u8) AdapterError!usize,
    ) AdapterError!Clock {
        try validateBind(meta, "clock", context);
        return .{
            .meta = meta,
            .context = context,
            .bound = true,
            .monotonic_nanos_fn = monotonic_nanos_fn,
            .boot_id_fn = boot_id_fn,
        };
    }

    pub fn ready(self: Clock) bool {
        return adapterReady(self.meta, "clock", self.bound, self.context);
    }

    pub fn monotonicNanos(self: Clock) AdapterError!u64 {
        if (!self.ready()) return error.Unsupported;
        return self.monotonic_nanos_fn(self.context);
    }

    pub fn bootId(self: Clock, buf: []u8) AdapterError!usize {
        if (!self.ready()) return error.Unsupported;
        return self.boot_id_fn(self.context, buf);
    }
};

pub const Entropy = struct {
    meta: CapabilityMeta = unavailableMeta("entropy"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    fill_fn: *const fn (?*const anyopaque, []u8) AdapterError!void = unsupportedFill,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        fill_fn: *const fn (?*const anyopaque, []u8) AdapterError!void,
    ) AdapterError!Entropy {
        try validateBind(meta, "entropy", context);
        return .{ .meta = meta, .context = context, .bound = true, .fill_fn = fill_fn };
    }

    pub fn ready(self: Entropy) bool {
        return adapterReady(self.meta, "entropy", self.bound, self.context);
    }

    pub fn fill(self: Entropy, buf: []u8) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.fill_fn(self.context, buf);
    }
};

pub const Auth = struct {
    meta: CapabilityMeta = unavailableMeta("auth"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    authenticate_fn: *const fn (?*const anyopaque, AuthMaterial) AdapterError!Principal = unsupportedAuthN,
    authorize_fn: *const fn (?*const anyopaque, Principal, Action, ResourceRef) AdapterError!void = unsupportedAuthZ,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        authenticate_fn: *const fn (?*const anyopaque, AuthMaterial) AdapterError!Principal,
        authorize_fn: *const fn (?*const anyopaque, Principal, Action, ResourceRef) AdapterError!void,
    ) AdapterError!Auth {
        try validateBind(meta, "auth", context);
        return .{
            .meta = meta,
            .context = context,
            .bound = true,
            .authenticate_fn = authenticate_fn,
            .authorize_fn = authorize_fn,
        };
    }

    pub fn ready(self: Auth) bool {
        return adapterReady(self.meta, "auth", self.bound, self.context);
    }

    pub fn authenticate(self: Auth, material: AuthMaterial) AdapterError!Principal {
        if (!self.ready()) return error.Unsupported;
        return self.authenticate_fn(self.context, material);
    }

    pub fn authorize(self: Auth, principal: Principal, action: Action, resource: ResourceRef) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.authorize_fn(self.context, principal, action, resource);
    }
};

pub const Store = struct {
    meta: CapabilityMeta = unavailableMeta("store"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    begin_fn: *const fn (?*const anyopaque) AdapterError!TxHandle = unsupportedBegin,
    commit_fn: *const fn (?*const anyopaque, TxHandle) AdapterError!void = unsupportedTx,
    rollback_fn: *const fn (?*const anyopaque, TxHandle) AdapterError!void = unsupportedTx,
    replay_fn: *const fn (?*const anyopaque, TxHandle, []const u8, []const u8) AdapterError!ReplayRecord = unsupportedReplay,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        begin_fn: *const fn (?*const anyopaque) AdapterError!TxHandle,
        commit_fn: *const fn (?*const anyopaque, TxHandle) AdapterError!void,
        rollback_fn: *const fn (?*const anyopaque, TxHandle) AdapterError!void,
        replay_fn: *const fn (?*const anyopaque, TxHandle, []const u8, []const u8) AdapterError!ReplayRecord,
    ) AdapterError!Store {
        try validateBind(meta, "store", context);
        return .{
            .meta = meta,
            .context = context,
            .bound = true,
            .begin_fn = begin_fn,
            .commit_fn = commit_fn,
            .rollback_fn = rollback_fn,
            .replay_fn = replay_fn,
        };
    }

    pub fn ready(self: Store) bool {
        return adapterReady(self.meta, "store", self.bound, self.context);
    }

    pub fn begin(self: Store) AdapterError!TxHandle {
        if (!self.ready()) return error.Unsupported;
        return self.begin_fn(self.context);
    }

    pub fn commit(self: Store, tx: TxHandle) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.commit_fn(self.context, tx);
    }

    pub fn rollback(self: Store, tx: TxHandle) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.rollback_fn(self.context, tx);
    }

    pub fn replayIdempotency(self: Store, tx: TxHandle, key: []const u8, fingerprint: []const u8) AdapterError!ReplayRecord {
        if (!self.ready()) return error.Unsupported;
        return self.replay_fn(self.context, tx, key, fingerprint);
    }
};

pub const Policy = struct {
    meta: CapabilityMeta = unavailableMeta("policy"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    admit_fn: *const fn (?*const anyopaque, Admission) AdapterError!void = unsupportedAdmit,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        admit_fn: *const fn (?*const anyopaque, Admission) AdapterError!void,
    ) AdapterError!Policy {
        try validateBind(meta, "policy", context);
        return .{ .meta = meta, .context = context, .bound = true, .admit_fn = admit_fn };
    }

    pub fn ready(self: Policy) bool {
        return adapterReady(self.meta, "policy", self.bound, self.context);
    }

    pub fn admit(self: Policy, req: Admission) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.admit_fn(self.context, req);
    }
};

pub const Launcher = struct {
    meta: CapabilityMeta = unavailableMeta("launcher"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    create_fn: *const fn (?*const anyopaque) AdapterError!LeaseHandle = unsupportedLease,
    revert_fn: *const fn (?*const anyopaque, LeaseHandle) AdapterError!void = unsupportedRevert,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        create_fn: *const fn (?*const anyopaque) AdapterError!LeaseHandle,
        revert_fn: *const fn (?*const anyopaque, LeaseHandle) AdapterError!void,
    ) AdapterError!Launcher {
        try validateBind(meta, "launcher", context);
        return .{
            .meta = meta,
            .context = context,
            .bound = true,
            .create_fn = create_fn,
            .revert_fn = revert_fn,
        };
    }

    pub fn ready(self: Launcher) bool {
        return adapterReady(self.meta, "launcher", self.bound, self.context);
    }

    pub fn createLease(self: Launcher) AdapterError!LeaseHandle {
        if (!self.ready()) return error.Unsupported;
        return self.create_fn(self.context);
    }

    pub fn revertLease(self: Launcher, lease: LeaseHandle) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.revert_fn(self.context, lease);
    }
};

pub const Filesystem = struct {
    meta: CapabilityMeta = unavailableMeta("fs"),
    kind: FsKind = .none,
    context: ?*const anyopaque = null,
    bound: bool = false,
    stat_fn: *const fn (?*const anyopaque, []const u8) AdapterError!FsStat = unsupportedStat,
    read_fn: *const fn (?*const anyopaque, []const u8, ByteRange, []u8) AdapterError!ReadResult = unsupportedRead,
    write_fn: *const fn (?*const anyopaque, []const u8, ByteRange, []const u8) AdapterError!usize = unsupportedWrite,

    pub fn bind(
        meta: CapabilityMeta,
        kind: FsKind,
        context: *const anyopaque,
        stat_fn: *const fn (?*const anyopaque, []const u8) AdapterError!FsStat,
        read_fn: *const fn (?*const anyopaque, []const u8, ByteRange, []u8) AdapterError!ReadResult,
        write_fn: *const fn (?*const anyopaque, []const u8, ByteRange, []const u8) AdapterError!usize,
    ) AdapterError!Filesystem {
        const expected: []const u8 = if (kind == .sqlitefs) "sqlitefs" else "fs";
        try validateBind(meta, expected, context);
        if (kind == .none) return error.Unsupported;
        return .{
            .meta = meta,
            .kind = kind,
            .context = context,
            .bound = true,
            .stat_fn = stat_fn,
            .read_fn = read_fn,
            .write_fn = write_fn,
        };
    }

    pub fn ready(self: Filesystem) bool {
        const expected: []const u8 = if (self.kind == .sqlitefs) "sqlitefs" else "fs";
        return self.kind != .none and adapterReady(self.meta, expected, self.bound, self.context);
    }

    pub fn stat(self: Filesystem, path: []const u8) AdapterError!FsStat {
        if (!self.ready()) return error.Unsupported;
        return self.stat_fn(self.context, path);
    }

    pub fn read(self: Filesystem, path: []const u8, range: ByteRange, buf: []u8) AdapterError!ReadResult {
        if (!self.ready()) return error.Unsupported;
        return self.read_fn(self.context, path, range, buf);
    }

    pub fn write(self: Filesystem, path: []const u8, range: ByteRange, buf: []const u8) AdapterError!usize {
        if (!self.ready()) return error.Unsupported;
        return self.write_fn(self.context, path, range, buf);
    }
};

pub const GuestExposure = struct {
    meta: CapabilityMeta = unavailableMeta("guest_exposure"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    mount_fn: *const fn (?*const anyopaque, []const u8) AdapterError!MountHandle = unsupportedMount,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        mount_fn: *const fn (?*const anyopaque, []const u8) AdapterError!MountHandle,
    ) AdapterError!GuestExposure {
        try validateBind(meta, "guest_exposure", context);
        return .{ .meta = meta, .context = context, .bound = true, .mount_fn = mount_fn };
    }

    pub fn ready(self: GuestExposure) bool {
        return adapterReady(self.meta, "guest_exposure", self.bound, self.context);
    }

    pub fn mount(self: GuestExposure, guest_path: []const u8) AdapterError!MountHandle {
        if (!self.ready()) return error.Unsupported;
        return self.mount_fn(self.context, guest_path);
    }
};

pub const Network = struct {
    meta: CapabilityMeta = unavailableMeta("network"),
    mode: []const u8 = "offline",
    context: ?*const anyopaque = null,
    bound: bool = false,
    allow_connect_fn: *const fn (?*const anyopaque, []const u8) AdapterError!void = unsupportedConnect,

    pub fn bind(
        meta: CapabilityMeta,
        mode: []const u8,
        context: *const anyopaque,
        allow_connect_fn: *const fn (?*const anyopaque, []const u8) AdapterError!void,
    ) AdapterError!Network {
        try validateBind(meta, "network", context);
        if (!(std.mem.eql(u8, mode, "offline") or std.mem.eql(u8, mode, "allowlist"))) return error.Unsupported;
        return .{
            .meta = meta,
            .mode = mode,
            .context = context,
            .bound = true,
            .allow_connect_fn = allow_connect_fn,
        };
    }

    pub fn ready(self: Network) bool {
        return adapterReady(self.meta, "network", self.bound, self.context);
    }

    pub fn allowConnect(self: Network, host: []const u8) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.allow_connect_fn(self.context, host);
    }
};

pub const VmBackend = struct {
    meta: CapabilityMeta = unavailableMeta("vm"),
    kind: contract.ProviderKind = .none,
    profile: ?contract.ProfileId = null,
    image_digest: []const u8 = "",
    pause_resume: bool = false,
    context: ?*const anyopaque = null,
    bound: bool = false,
    boot_fn: *const fn (?*const anyopaque, VmBootSpec) AdapterError!VmInstance = unsupportedBoot,
    pause_fn: *const fn (?*const anyopaque, VmInstance) AdapterError!void = unsupportedVmOp,
    resume_fn: *const fn (?*const anyopaque, VmInstance) AdapterError!void = unsupportedVmOp,
    stop_fn: *const fn (?*const anyopaque, VmInstance) AdapterError!void = unsupportedVmOp,

    pub fn bind(
        meta: CapabilityMeta,
        kind: contract.ProviderKind,
        profile: contract.ProfileId,
        image_digest: []const u8,
        pause_resume: bool,
        context: *const anyopaque,
        boot_fn: *const fn (?*const anyopaque, VmBootSpec) AdapterError!VmInstance,
        pause_fn: *const fn (?*const anyopaque, VmInstance) AdapterError!void,
        resume_fn: *const fn (?*const anyopaque, VmInstance) AdapterError!void,
        stop_fn: *const fn (?*const anyopaque, VmInstance) AdapterError!void,
    ) AdapterError!VmBackend {
        try validateBind(meta, "vm", context);
        if (kind == .none) return error.Unsupported;
        if (!contract.isImageDigest(image_digest)) return error.Unsupported;
        return .{
            .meta = meta,
            .kind = kind,
            .profile = profile,
            .image_digest = image_digest,
            .pause_resume = pause_resume,
            .context = context,
            .bound = true,
            .boot_fn = boot_fn,
            .pause_fn = pause_fn,
            .resume_fn = resume_fn,
            .stop_fn = stop_fn,
        };
    }

    pub fn ready(self: VmBackend) bool {
        return self.kind != .none and self.profile != null and
            contract.isImageDigest(self.image_digest) and
            adapterReady(self.meta, "vm", self.bound, self.context);
    }

    pub fn boot(self: VmBackend, spec: VmBootSpec) AdapterError!VmInstance {
        if (!self.ready()) return error.Unsupported;
        if (self.profile) |profile| {
            if (spec.profile != profile) return error.Invalid;
        }
        if (!std.mem.eql(u8, spec.image_digest, self.image_digest)) return error.Invalid;
        return self.boot_fn(self.context, spec);
    }

    pub fn pause(self: VmBackend, instance: VmInstance) AdapterError!void {
        if (!self.ready() or !self.pause_resume) return error.Unsupported;
        return self.pause_fn(self.context, instance);
    }

    /// Live resume of the same execution. Named `resumeGuest` because `resume`
    /// is a reserved Zig token. The HTTP contract remains POST /v1/sandboxes/{id}/resume.
    pub fn resumeGuest(self: VmBackend, instance: VmInstance) AdapterError!void {
        if (!self.ready() or !self.pause_resume) return error.Unsupported;
        return self.resume_fn(self.context, instance);
    }

    pub fn stop(self: VmBackend, instance: VmInstance) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.stop_fn(self.context, instance);
    }
};

pub const Lifecycle = struct {
    meta: CapabilityMeta = unavailableMeta("lifecycle"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    create_fn: *const fn (?*const anyopaque) AdapterError!LifecycleObject = unsupportedLifeCreate,
    destroy_fn: *const fn (?*const anyopaque, LifecycleObject) AdapterError!void = unsupportedLifeDestroy,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        create_fn: *const fn (?*const anyopaque) AdapterError!LifecycleObject,
        destroy_fn: *const fn (?*const anyopaque, LifecycleObject) AdapterError!void,
    ) AdapterError!Lifecycle {
        try validateBind(meta, "lifecycle", context);
        return .{
            .meta = meta,
            .context = context,
            .bound = true,
            .create_fn = create_fn,
            .destroy_fn = destroy_fn,
        };
    }

    pub fn ready(self: Lifecycle) bool {
        return adapterReady(self.meta, "lifecycle", self.bound, self.context);
    }

    pub fn create(self: Lifecycle) AdapterError!LifecycleObject {
        if (!self.ready()) return error.Unsupported;
        return self.create_fn(self.context);
    }

    pub fn destroy(self: Lifecycle, obj: LifecycleObject) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.destroy_fn(self.context, obj);
    }
};

pub const ImageRegistry = struct {
    meta: CapabilityMeta = unavailableMeta("image_registry"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    resolve_fn: *const fn (?*const anyopaque, []const u8) AdapterError!ResolvedImage = unsupportedResolveImage,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        resolve_fn: *const fn (?*const anyopaque, []const u8) AdapterError!ResolvedImage,
    ) AdapterError!ImageRegistry {
        try validateBind(meta, "image_registry", context);
        return .{ .meta = meta, .context = context, .bound = true, .resolve_fn = resolve_fn };
    }

    pub fn ready(self: ImageRegistry) bool {
        return adapterReady(self.meta, "image_registry", self.bound, self.context);
    }

    pub fn resolve(self: ImageRegistry, digest: []const u8) AdapterError!ResolvedImage {
        if (!self.ready()) return error.Unsupported;
        return self.resolve_fn(self.context, digest);
    }
};

pub const ExportBroker = struct {
    meta: CapabilityMeta = unavailableMeta("export"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    register_fn: *const fn (?*const anyopaque) AdapterError!ExportHandle = unsupportedExport,
    attach_fn: *const fn (?*const anyopaque, ExportHandle, MountHandle) AdapterError!void = unsupportedAttach,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        register_fn: *const fn (?*const anyopaque) AdapterError!ExportHandle,
        attach_fn: *const fn (?*const anyopaque, ExportHandle, MountHandle) AdapterError!void,
    ) AdapterError!ExportBroker {
        try validateBind(meta, "export", context);
        return .{
            .meta = meta,
            .context = context,
            .bound = true,
            .register_fn = register_fn,
            .attach_fn = attach_fn,
        };
    }

    pub fn ready(self: ExportBroker) bool {
        return adapterReady(self.meta, "export", self.bound, self.context);
    }

    pub fn register(self: ExportBroker) AdapterError!ExportHandle {
        if (!self.ready()) return error.Unsupported;
        return self.register_fn(self.context);
    }

    pub fn attach(self: ExportBroker, handle: ExportHandle, mount: MountHandle) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.attach_fn(self.context, handle, mount);
    }
};

pub const SecretBroker = struct {
    meta: CapabilityMeta = unavailableMeta("secret"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    resolve_fn: *const fn (?*const anyopaque, []const u8, []u8) AdapterError!usize = unsupportedSecret,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        resolve_fn: *const fn (?*const anyopaque, []const u8, []u8) AdapterError!usize,
    ) AdapterError!SecretBroker {
        try validateBind(meta, "secret", context);
        return .{ .meta = meta, .context = context, .bound = true, .resolve_fn = resolve_fn };
    }

    pub fn ready(self: SecretBroker) bool {
        return adapterReady(self.meta, "secret", self.bound, self.context);
    }

    pub fn resolve(self: SecretBroker, ref: []const u8, buf: []u8) AdapterError!usize {
        if (!self.ready()) return error.Unsupported;
        return self.resolve_fn(self.context, ref, buf);
    }
};

pub const Pty = struct {
    meta: CapabilityMeta = unavailableMeta("pty"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    open_fn: *const fn (?*const anyopaque) AdapterError!PtyHandle = unsupportedPty,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        open_fn: *const fn (?*const anyopaque) AdapterError!PtyHandle,
    ) AdapterError!Pty {
        try validateBind(meta, "pty", context);
        return .{ .meta = meta, .context = context, .bound = true, .open_fn = open_fn };
    }

    pub fn ready(self: Pty) bool {
        return adapterReady(self.meta, "pty", self.bound, self.context);
    }

    pub fn open(self: Pty) AdapterError!PtyHandle {
        if (!self.ready()) return error.Unsupported;
        return self.open_fn(self.context);
    }
};

pub const Channels = struct {
    meta: CapabilityMeta = unavailableMeta("channels"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    open_fn: *const fn (?*const anyopaque) AdapterError!ChannelHandle = unsupportedChannel,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        open_fn: *const fn (?*const anyopaque) AdapterError!ChannelHandle,
    ) AdapterError!Channels {
        try validateBind(meta, "channels", context);
        return .{ .meta = meta, .context = context, .bound = true, .open_fn = open_fn };
    }

    pub fn ready(self: Channels) bool {
        return adapterReady(self.meta, "channels", self.bound, self.context);
    }

    pub fn open(self: Channels) AdapterError!ChannelHandle {
        if (!self.ready()) return error.Unsupported;
        return self.open_fn(self.context);
    }
};

pub const Events = struct {
    meta: CapabilityMeta = unavailableMeta("events"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    subscribe_fn: *const fn (?*const anyopaque) AdapterError!EventCursor = unsupportedSubscribe,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        subscribe_fn: *const fn (?*const anyopaque) AdapterError!EventCursor,
    ) AdapterError!Events {
        try validateBind(meta, "events", context);
        return .{ .meta = meta, .context = context, .bound = true, .subscribe_fn = subscribe_fn };
    }

    pub fn ready(self: Events) bool {
        return adapterReady(self.meta, "events", self.bound, self.context);
    }

    pub fn subscribe(self: Events) AdapterError!EventCursor {
        if (!self.ready()) return error.Unsupported;
        return self.subscribe_fn(self.context);
    }
};

pub const Callbacks = struct {
    meta: CapabilityMeta = unavailableMeta("callbacks"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    register_fn: *const fn (?*const anyopaque) AdapterError!CallbackId = unsupportedCallback,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        register_fn: *const fn (?*const anyopaque) AdapterError!CallbackId,
    ) AdapterError!Callbacks {
        try validateBind(meta, "callbacks", context);
        return .{ .meta = meta, .context = context, .bound = true, .register_fn = register_fn };
    }

    pub fn ready(self: Callbacks) bool {
        return adapterReady(self.meta, "callbacks", self.bound, self.context);
    }

    pub fn register(self: Callbacks) AdapterError!CallbackId {
        if (!self.ready()) return error.Unsupported;
        return self.register_fn(self.context);
    }
};

pub const Metrics = struct {
    meta: CapabilityMeta = unavailableMeta("metrics"),
    context: ?*const anyopaque = null,
    bound: bool = false,
    emit_fn: *const fn (?*const anyopaque, []const u8) AdapterError!void = unsupportedMetric,

    pub fn bind(
        meta: CapabilityMeta,
        context: *const anyopaque,
        emit_fn: *const fn (?*const anyopaque, []const u8) AdapterError!void,
    ) AdapterError!Metrics {
        try validateBind(meta, "metrics", context);
        return .{ .meta = meta, .context = context, .bound = true, .emit_fn = emit_fn };
    }

    pub fn ready(self: Metrics) bool {
        return adapterReady(self.meta, "metrics", self.bound, self.context);
    }

    pub fn emit(self: Metrics, name: []const u8) AdapterError!void {
        if (!self.ready()) return error.Unsupported;
        return self.emit_fn(self.context, name);
    }
};

pub const EngineSeams = struct {
    clock: Clock = .{},
    entropy: Entropy = .{},
    auth: Auth = .{},
    store: Store = .{},
    policy: Policy = .{},
    launcher: Launcher = .{},
    fs: Filesystem = .{},
    sqlitefs: Filesystem = .{ .meta = unavailableMeta("sqlitefs"), .kind = .sqlitefs },
    guest_exposure: GuestExposure = .{},
    network: Network = .{},
    vm: VmBackend = .{},
    lifecycle: Lifecycle = .{},
    image_registry: ImageRegistry = .{},
    export_broker: ExportBroker = .{},
    secret_broker: SecretBroker = .{},
    pty: Pty = .{},
    channels: Channels = .{},
    events: Events = .{},
    callbacks: Callbacks = .{},
    metrics: Metrics = .{},
    inventory: contract.ProviderInventory = .{},

    pub fn toEvidence(self: EngineSeams) contract.CompositionEvidence {
        const vm_ready = self.vm.ready();
        return .{
            .inventory = self.inventory,
            .auth = self.auth.ready(),
            .store = self.store.ready(),
            .launcher = self.launcher.ready(),
            .guest = self.guest_exposure.ready(),
            .policy = self.policy.ready(),
            .clock = self.clock.ready(),
            .entropy = self.entropy.ready(),
            .image_registry = self.image_registry.ready(),
            .lifecycle = self.lifecycle.ready(),
            .vm_ready = vm_ready,
            .vm_kind = if (vm_ready) self.vm.kind else .none,
            .vm_version = self.vm.meta.version,
            .vm_pause_resume = vm_ready and self.vm.pause_resume,
            .vm_profile = if (vm_ready) self.vm.profile else null,
            .vm_image_digest = if (vm_ready) self.vm.image_digest else "",
            .pty = self.pty.ready(),
            .channels = self.channels.ready(),
            .sse = self.events.ready(),
            .exports = self.export_broker.ready(),
            .callbacks = self.callbacks.ready(),
            .snapshots = false,
            .forks = false,
            .wasm_core = false,
            .guest_wasi = false,
            .network_allowlist = self.network.ready() and std.mem.eql(u8, self.network.mode, "allowlist"),
        };
    }

    /// Four public `available` booleans cannot authorize execution. Bound
    /// adapters, matching contract version, a ready VM with live pause/resume,
    /// required controls, and a matching qualified inventory record are required.
    pub fn advertisesExecution(self: EngineSeams) bool {
        return contract.capabilitiesFromComposition(self.toEvidence()).execution;
    }
};

pub const unavailable_seams = EngineSeams{};

const TEST_DIGEST = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const OTHER_DIGEST = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

const AllowBox = struct {
    n: usize = 0,
    tx: u64 = 0,
    instance: u64 = 0,
    fence: u64 = 0,
    fingerprint_buf: [64]u8 = undefined,
    fingerprint_len: usize = 0,
    payload_buf: [32]u8 = undefined,
    payload_len: usize = 0,
    cursor_buf: [8]u8 = undefined,
    cursor_len: usize = 0,
    callback_buf: [8]u8 = undefined,
    callback_len: usize = 0,
    /// Pid-only local `Principal.id`. Valid after authenticate until overwritten
    /// (later pid-only authenticate) or the adapter is rebound.
    local_id_buf: [16]u8 = undefined,
    principal: []const u8 = "spiffe://example/sa/allow",
};

const DenyBox = struct {
    n: usize = 0,
};

fn boxAllow(ctx: ?*const anyopaque) *AllowBox {
    return @ptrCast(@alignCast(@constCast(ctx.?)));
}

fn boxDeny(ctx: ?*const anyopaque) *DenyBox {
    return @ptrCast(@alignCast(@constCast(ctx.?)));
}

fn allowTime(ctx: ?*const anyopaque) AdapterError!u64 {
    boxAllow(ctx).n += 1;
    return 7;
}
fn allowBootId(ctx: ?*const anyopaque, buf: []u8) AdapterError!usize {
    boxAllow(ctx).n += 1;
    if (buf.len == 0) return 0;
    buf[0] = 'b';
    return 1;
}
fn allowFill(ctx: ?*const anyopaque, buf: []u8) AdapterError!void {
    boxAllow(ctx).n += 1;
    if (buf.len != 0) buf[0] = 1;
}
fn allowAuthN(ctx: ?*const anyopaque, material: AuthMaterial) AdapterError!Principal {
    const box = boxAllow(ctx);
    box.n += 1;
    _ = material.client_identity_header;
    switch (material.transport) {
        .mutual_tls => {
            if (material.mtls_peer.len == 0) return error.Unauthenticated;
            // Request-owned: Principal.id borrows mtls_peer, valid until that slice is mutated or released.
            return .{ .id = material.mtls_peer, .transport = .mutual_tls };
        },
        .local_ipc => {
            if (material.local_peer.pid == 0 and material.local_peer.token.len == 0) return error.Unauthenticated;
            if (material.local_peer.token.len != 0) {
                // Request-backed: Principal.id borrows local_peer.token.
                return .{ .id = material.local_peer.token, .transport = .local_ipc };
            }
            // Adapter-backed pid-only path: identity lives in local_id_buf until
            // overwritten or the adapter is rebound. Not request-owned.
            const id = "local:peer";
            @memcpy(box.local_id_buf[0..id.len], id);
            return .{ .id = box.local_id_buf[0..id.len], .transport = .local_ipc };
        },
        .unknown => return error.Unauthenticated,
    }
}
fn allowAuthZ(ctx: ?*const anyopaque, _: Principal, action: Action, resource: ResourceRef) AdapterError!void {
    boxAllow(ctx).n += 1;
    if (!std.mem.eql(u8, action.name, "sandbox.exec")) return error.Denied;
    if (!(std.mem.eql(u8, resource.kind, "sandbox") and std.mem.eql(u8, resource.id, "sbx_allow")))
        return error.Denied;
}
fn allowBegin(ctx: ?*const anyopaque) AdapterError!TxHandle {
    const box = boxAllow(ctx);
    box.n += 1;
    box.tx += 1;
    return .{ .id = box.tx, .generation = 1 };
}
fn allowCommit(ctx: ?*const anyopaque, tx: TxHandle) AdapterError!void {
    const box = boxAllow(ctx);
    box.n += 1;
    if (tx.id == 0 or tx.id != box.tx) return error.Stale;
}
fn allowRollback(ctx: ?*const anyopaque, tx: TxHandle) AdapterError!void {
    const box = boxAllow(ctx);
    box.n += 1;
    if (tx.id == 0) return error.NotFound;
    if (tx.id == box.tx) box.tx = 0;
}
fn allowReplay(ctx: ?*const anyopaque, tx: TxHandle, key: []const u8, fingerprint: []const u8) AdapterError!ReplayRecord {
    const box = boxAllow(ctx);
    box.n += 1;
    if (tx.id == 0) return error.Stale;
    if (key.len == 0) return error.Invalid;
    if (box.fingerprint_len == 0) {
        if (fingerprint.len > box.fingerprint_buf.len) return error.Invalid;
        @memcpy(box.fingerprint_buf[0..fingerprint.len], fingerprint);
        box.fingerprint_len = fingerprint.len;
        const stored = "durable-result";
        @memcpy(box.payload_buf[0..stored.len], stored);
        box.payload_len = stored.len;
        return .{ .outcome = .miss, .payload = box.payload_buf[0..0] };
    }
    if (std.mem.eql(u8, box.fingerprint_buf[0..box.fingerprint_len], fingerprint))
        return .{ .outcome = .replay, .payload = box.payload_buf[0..box.payload_len] };
    return .{ .outcome = .conflict, .payload = box.payload_buf[0..0] };
}
fn allowAdmit(ctx: ?*const anyopaque, req: Admission) AdapterError!void {
    boxAllow(ctx).n += 1;
    if (!std.mem.eql(u8, req.resource.id, "sbx_allow")) return error.Denied;
}
fn allowLease(ctx: ?*const anyopaque) AdapterError!LeaseHandle {
    boxAllow(ctx).n += 1;
    return .{ .id = 11, .fence = 4 };
}
fn allowRevert(ctx: ?*const anyopaque, lease: LeaseHandle) AdapterError!void {
    boxAllow(ctx).n += 1;
    if (lease.id != 11) return error.NotFound;
}
fn allowStat(ctx: ?*const anyopaque, path: []const u8) AdapterError!FsStat {
    boxAllow(ctx).n += 1;
    if (!std.mem.eql(u8, path, "/workspace/a")) return error.NotFound;
    return .{ .kind = .file, .size = 42, .mtime_unix = 1 };
}
fn allowRead(ctx: ?*const anyopaque, path: []const u8, range: ByteRange, buf: []u8) AdapterError!ReadResult {
    boxAllow(ctx).n += 1;
    if (!std.mem.eql(u8, path, "/workspace/a")) return error.NotFound;
    if (range.offset > 42) return error.Invalid;
    const remaining: u64 = 42 - range.offset;
    const want: u64 = @min(range.length, remaining);
    const n: usize = @intCast(@min(want, @as(u64, @intCast(buf.len))));
    if (n != 0) buf[0] = 'x';
    return .{ .bytes = n, .eof = range.offset + range.length >= 42 };
}
fn allowWrite(ctx: ?*const anyopaque, path: []const u8, _: ByteRange, buf: []const u8) AdapterError!usize {
    boxAllow(ctx).n += 1;
    if (!std.mem.eql(u8, path, "/workspace/a")) return error.Denied;
    return buf.len;
}
fn allowMount(ctx: ?*const anyopaque, path: []const u8) AdapterError!MountHandle {
    boxAllow(ctx).n += 1;
    if (path.len == 0) return error.Invalid;
    return .{ .id = 3 };
}
fn allowConnect(ctx: ?*const anyopaque, host: []const u8) AdapterError!void {
    boxAllow(ctx).n += 1;
    if (host.len == 0) return error.Denied;
}
fn allowBoot(ctx: ?*const anyopaque, spec: VmBootSpec) AdapterError!VmInstance {
    const box = boxAllow(ctx);
    box.n += 1;
    box.instance = 7;
    box.fence = spec.lease.fence;
    return .{ .id = 7, .fence = spec.lease.fence };
}
fn allowVmOp(ctx: ?*const anyopaque, instance: VmInstance) AdapterError!void {
    const box = boxAllow(ctx);
    box.n += 1;
    if (instance.id != box.instance) return error.NotFound;
    if (instance.fence != box.fence) return error.Stale;
}
fn allowLifeCreate(ctx: ?*const anyopaque) AdapterError!LifecycleObject {
    boxAllow(ctx).n += 1;
    return .{ .id = 9, .state = .ready };
}
fn allowLifeDestroy(ctx: ?*const anyopaque, obj: LifecycleObject) AdapterError!void {
    boxAllow(ctx).n += 1;
    if (obj.id != 9) return error.NotFound;
}
fn allowResolveImage(ctx: ?*const anyopaque, digest: []const u8) AdapterError!ResolvedImage {
    boxAllow(ctx).n += 1;
    if (!std.mem.eql(u8, digest, TEST_DIGEST)) return error.NotFound;
    // Request-owned: digest remains valid until the resolve argument is mutated or released.
    return .{ .digest = digest, .size = 4096 };
}
fn allowExport(ctx: ?*const anyopaque) AdapterError!ExportHandle {
    boxAllow(ctx).n += 1;
    return .{ .id = 5 };
}
fn allowAttach(ctx: ?*const anyopaque, handle: ExportHandle, _: MountHandle) AdapterError!void {
    boxAllow(ctx).n += 1;
    if (handle.id != 5) return error.NotFound;
}
fn allowSecret(ctx: ?*const anyopaque, _: []const u8, buf: []u8) AdapterError!usize {
    boxAllow(ctx).n += 1;
    if (buf.len == 0) return 0;
    buf[0] = 9;
    return 1;
}
fn allowPty(ctx: ?*const anyopaque) AdapterError!PtyHandle {
    boxAllow(ctx).n += 1;
    return .{ .id = 2 };
}
fn allowChannel(ctx: ?*const anyopaque) AdapterError!ChannelHandle {
    boxAllow(ctx).n += 1;
    return .{ .id = 2 };
}
fn allowSubscribe(ctx: ?*const anyopaque) AdapterError!EventCursor {
    const box = boxAllow(ctx);
    box.n += 1;
    const cur = "cur_1";
    @memcpy(box.cursor_buf[0..cur.len], cur);
    box.cursor_len = cur.len;
    return .{ .cursor = box.cursor_buf[0..box.cursor_len] };
}
fn allowCallback(ctx: ?*const anyopaque) AdapterError!CallbackId {
    const box = boxAllow(ctx);
    box.n += 1;
    const id = "cb_1";
    @memcpy(box.callback_buf[0..id.len], id);
    box.callback_len = id.len;
    return .{ .id = box.callback_buf[0..box.callback_len] };
}
fn allowMetric(ctx: ?*const anyopaque, _: []const u8) AdapterError!void {
    boxAllow(ctx).n += 1;
}

fn denyAuthN(ctx: ?*const anyopaque, material: AuthMaterial) AdapterError!Principal {
    boxDeny(ctx).n += 1;
    if (material.client_identity_header.len != 0 and material.mtls_peer.len == 0 and
        material.local_peer.pid == 0 and material.local_peer.token.len == 0)
        return error.Denied;
    if (material.transport == .unknown) return error.Unauthenticated;
    if (material.transport == .mutual_tls and material.mtls_peer.len == 0) return error.Unauthenticated;
    return error.Denied;
}
fn denyAuthZ(ctx: ?*const anyopaque, _: Principal, _: Action, resource: ResourceRef) AdapterError!void {
    boxDeny(ctx).n += 1;
    if (std.mem.eql(u8, resource.id, "missing")) return error.NotFound;
    return error.Denied;
}
fn denyBegin(ctx: ?*const anyopaque) AdapterError!TxHandle {
    boxDeny(ctx).n += 1;
    return error.Capacity;
}
fn denyTx(ctx: ?*const anyopaque, _: TxHandle) AdapterError!void {
    boxDeny(ctx).n += 1;
    return error.Stale;
}
fn denyReplay(ctx: ?*const anyopaque, _: TxHandle, _: []const u8, _: []const u8) AdapterError!ReplayRecord {
    boxDeny(ctx).n += 1;
    return error.Io;
}
fn denyAdmit(ctx: ?*const anyopaque, _: Admission) AdapterError!void {
    boxDeny(ctx).n += 1;
    return error.Denied;
}
fn denyLease(ctx: ?*const anyopaque) AdapterError!LeaseHandle {
    boxDeny(ctx).n += 1;
    return error.Capacity;
}
fn denyRevert(ctx: ?*const anyopaque, _: LeaseHandle) AdapterError!void {
    boxDeny(ctx).n += 1;
    return error.NotFound;
}
fn denyStat(ctx: ?*const anyopaque, path: []const u8) AdapterError!FsStat {
    boxDeny(ctx).n += 1;
    if (std.mem.eql(u8, path, "/workspace/io")) return error.Io;
    return error.NotFound;
}
fn denyRead(ctx: ?*const anyopaque, _: []const u8, _: ByteRange, _: []u8) AdapterError!ReadResult {
    boxDeny(ctx).n += 1;
    return error.Denied;
}
fn denyWrite(ctx: ?*const anyopaque, _: []const u8, _: ByteRange, _: []const u8) AdapterError!usize {
    boxDeny(ctx).n += 1;
    return error.Capacity;
}
fn denyMount(ctx: ?*const anyopaque, _: []const u8) AdapterError!MountHandle {
    boxDeny(ctx).n += 1;
    return error.Denied;
}
fn denyConnect(ctx: ?*const anyopaque, _: []const u8) AdapterError!void {
    boxDeny(ctx).n += 1;
    return error.Denied;
}
fn denyBoot(ctx: ?*const anyopaque, _: VmBootSpec) AdapterError!VmInstance {
    boxDeny(ctx).n += 1;
    return error.Capacity;
}
fn denyVmOp(ctx: ?*const anyopaque, instance: VmInstance) AdapterError!void {
    boxDeny(ctx).n += 1;
    if (instance.id == 0) return error.NotFound;
    return error.Stale;
}
fn denyLifeCreate(ctx: ?*const anyopaque) AdapterError!LifecycleObject {
    boxDeny(ctx).n += 1;
    return error.Unavailable;
}
fn denyLifeDestroy(ctx: ?*const anyopaque, _: LifecycleObject) AdapterError!void {
    boxDeny(ctx).n += 1;
    return error.NotFound;
}
fn denyResolveImage(ctx: ?*const anyopaque, _: []const u8) AdapterError!ResolvedImage {
    boxDeny(ctx).n += 1;
    return error.NotFound;
}
fn denyExport(ctx: ?*const anyopaque) AdapterError!ExportHandle {
    boxDeny(ctx).n += 1;
    return error.Denied;
}
fn denyAttach(ctx: ?*const anyopaque, _: ExportHandle, _: MountHandle) AdapterError!void {
    boxDeny(ctx).n += 1;
    return error.Denied;
}
fn denySecret(ctx: ?*const anyopaque, _: []const u8, _: []u8) AdapterError!usize {
    boxDeny(ctx).n += 1;
    return error.Denied;
}
fn denyPty(ctx: ?*const anyopaque) AdapterError!PtyHandle {
    boxDeny(ctx).n += 1;
    return error.Unsupported;
}
fn denyChannel(ctx: ?*const anyopaque) AdapterError!ChannelHandle {
    boxDeny(ctx).n += 1;
    return error.Unsupported;
}
fn denySubscribe(ctx: ?*const anyopaque) AdapterError!EventCursor {
    boxDeny(ctx).n += 1;
    return error.Unsupported;
}
fn denyCallback(ctx: ?*const anyopaque) AdapterError!CallbackId {
    boxDeny(ctx).n += 1;
    return error.Unsupported;
}
fn denyMetric(ctx: ?*const anyopaque, _: []const u8) AdapterError!void {
    boxDeny(ctx).n += 1;
    return error.Unavailable;
}

fn exerciseAuth(auth: Auth, material: AuthMaterial, action: Action, resource: ResourceRef) AdapterError!Principal {
    const principal = try auth.authenticate(material);
    try auth.authorize(principal, action, resource);
    return principal;
}

fn exerciseStore(store: Store, key: []const u8, fingerprint: []const u8) AdapterError!ReplayRecord {
    const tx = try store.begin();
    const replay = store.replayIdempotency(tx, key, fingerprint) catch |err| {
        store.rollback(tx) catch {};
        return err;
    };
    store.commit(tx) catch |err| {
        store.rollback(tx) catch {};
        return err;
    };
    // Replay payload must remain valid after commit; it is not tx-scratch.
    return replay;
}

fn exerciseFs(fs: Filesystem, path: []const u8, buf: []u8) AdapterError!FsStat {
    const st = try fs.stat(path);
    _ = try fs.read(path, .{ .offset = 0, .length = st.size }, buf);
    return st;
}

fn exerciseVm(vm: VmBackend, spec: VmBootSpec) AdapterError!VmInstance {
    const instance = try vm.boot(spec);
    try vm.pause(instance);
    try vm.resumeGuest(instance);
    try vm.stop(instance);
    return instance;
}

const test_kvm_providers = [_]contract.ProviderRecord{.{
    .kind = .qemu_kvm,
    .profile = .linux_vm_x64,
    .image_digest = TEST_DIGEST,
    .pause_resume = true,
    .qualified = true,
}};

fn bindAllowVm(ctx: *const anyopaque, kind: contract.ProviderKind, profile: contract.ProfileId, digest: []const u8, pause_resume: bool) AdapterError!VmBackend {
    return VmBackend.bind(qualifiedMeta("vm"), kind, profile, digest, pause_resume, ctx, allowBoot, allowVmOp, allowVmOp, allowVmOp);
}

fn bindRequiredAllow(seams: *EngineSeams, ctx: *const anyopaque) !void {
    seams.clock = try Clock.bind(qualifiedMeta("clock"), ctx, allowTime, allowBootId);
    seams.entropy = try Entropy.bind(qualifiedMeta("entropy"), ctx, allowFill);
    seams.auth = try Auth.bind(qualifiedMeta("auth"), ctx, allowAuthN, allowAuthZ);
    seams.store = try Store.bind(qualifiedMeta("store"), ctx, allowBegin, allowCommit, allowRollback, allowReplay);
    seams.policy = try Policy.bind(qualifiedMeta("policy"), ctx, allowAdmit);
    seams.launcher = try Launcher.bind(qualifiedMeta("launcher"), ctx, allowLease, allowRevert);
    seams.guest_exposure = try GuestExposure.bind(qualifiedMeta("guest_exposure"), ctx, allowMount);
    seams.lifecycle = try Lifecycle.bind(qualifiedMeta("lifecycle"), ctx, allowLifeCreate, allowLifeDestroy);
    seams.image_registry = try ImageRegistry.bind(qualifiedMeta("image_registry"), ctx, allowResolveImage);
    seams.vm = try bindAllowVm(ctx, .qemu_kvm, .linux_vm_x64, TEST_DIGEST, true);
    seams.inventory = .{ .providers = &test_kvm_providers };
}

test "default seams are unavailable and do not advertise execution" {
    var scratch: [1]u8 = .{0};
    try std.testing.expect(!unavailable_seams.advertisesExecution());
    try std.testing.expectError(error.Unsupported, unavailable_seams.clock.monotonicNanos());
    try std.testing.expectError(error.Unsupported, unavailable_seams.entropy.fill(scratch[0..0]));
    try std.testing.expectError(error.Unsupported, unavailable_seams.auth.authenticate(.{}));
    try std.testing.expectError(error.Unsupported, unavailable_seams.store.begin());
    try std.testing.expectError(error.Unsupported, unavailable_seams.policy.admit(.{}));
    try std.testing.expectError(error.Unsupported, unavailable_seams.launcher.createLease());
    try std.testing.expectError(error.Unsupported, unavailable_seams.fs.stat("/workspace"));
    try std.testing.expectError(error.Unsupported, unavailable_seams.sqlitefs.read("/workspace/a", .{}, scratch[0..0]));
    try std.testing.expectError(error.Unsupported, unavailable_seams.guest_exposure.mount("/workspace"));
    try std.testing.expectError(error.Unsupported, unavailable_seams.network.allowConnect("example.com"));
    try std.testing.expectError(error.Unsupported, unavailable_seams.vm.boot(.{}));
    try std.testing.expectError(error.Unsupported, unavailable_seams.vm.pause(.{}));
    try std.testing.expectError(error.Unsupported, unavailable_seams.vm.resumeGuest(.{}));
    try std.testing.expectError(error.Unsupported, unavailable_seams.vm.stop(.{}));
    try std.testing.expectError(error.Unsupported, unavailable_seams.lifecycle.create());
    try std.testing.expectError(error.Unsupported, unavailable_seams.image_registry.resolve("sha256:00"));
    try std.testing.expectError(error.Unsupported, unavailable_seams.export_broker.register());
    try std.testing.expectError(error.Unsupported, unavailable_seams.secret_broker.resolve("ref", scratch[0..]));
    try std.testing.expectError(error.Unsupported, unavailable_seams.pty.open());
    try std.testing.expectError(error.Unsupported, unavailable_seams.channels.open());
    try std.testing.expectError(error.Unsupported, unavailable_seams.events.subscribe());
    try std.testing.expectError(error.Unsupported, unavailable_seams.callbacks.register());
    try std.testing.expectError(error.Unsupported, unavailable_seams.metrics.emit("n"));
    try std.testing.expect(std.mem.eql(u8, unavailable_seams.network.mode, "offline"));
}

test "marking available booleans is not enough to advertise execution" {
    var seams = unavailable_seams;
    seams.vm.meta.available = true;
    seams.lifecycle.meta.available = true;
    seams.auth.meta.available = true;
    seams.store.meta.available = true;
    seams.launcher.meta.available = true;
    seams.guest_exposure.meta.available = true;
    seams.vm.kind = .qemu_kvm;
    seams.inventory = .{ .providers = &test_kvm_providers };
    try std.testing.expect(!seams.advertisesExecution());
    try std.testing.expectError(error.Unsupported, seams.vm.boot(.{ .image_digest = TEST_DIGEST }));
}

test "bind rejects version mismatch missing context and none vm kind" {
    var box = AllowBox{};
    try std.testing.expectError(error.Unsupported, Auth.bind(.{
        .name = "auth",
        .version = "0",
        .available = true,
    }, @ptrCast(&box), allowAuthN, allowAuthZ));
    try std.testing.expectError(error.Unsupported, VmBackend.bind(
        qualifiedMeta("vm"),
        .none,
        .linux_vm_x64,
        TEST_DIGEST,
        true,
        @ptrCast(&box),
        allowBoot,
        allowVmOp,
        allowVmOp,
        allowVmOp,
    ));
}

test "two independent fake adapters prove typed results denial and resource scope" {
    var allow = AllowBox{};
    var deny = DenyBox{};
    const allow_ctx: *const anyopaque = @ptrCast(&allow);
    const deny_ctx: *const anyopaque = @ptrCast(&deny);

    const allow_auth = try Auth.bind(qualifiedMeta("auth"), allow_ctx, allowAuthN, allowAuthZ);
    const deny_auth = try Auth.bind(qualifiedMeta("auth"), deny_ctx, denyAuthN, denyAuthZ);
    const header_only = AuthMaterial{ .client_identity_header = "X-Sandbox-Local-Identity: root" };
    try std.testing.expectError(error.Unauthenticated, exerciseAuth(allow_auth, header_only, .{ .name = "sandbox.exec" }, .{ .kind = "sandbox", .id = "sbx_allow" }));
    try std.testing.expectError(error.Denied, exerciseAuth(deny_auth, header_only, .{ .name = "sandbox.exec" }, .{ .kind = "sandbox", .id = "sbx_allow" }));
    const mtls = AuthMaterial{ .transport = .mutual_tls, .mtls_peer = "spiffe://example/sa/allow", .client_identity_header = "forged" };
    const principal = try exerciseAuth(allow_auth, mtls, .{ .name = "sandbox.exec" }, .{ .kind = "sandbox", .id = "sbx_allow" });
    try std.testing.expect(std.mem.eql(u8, principal.id, "spiffe://example/sa/allow"));
    try std.testing.expectError(error.Denied, exerciseAuth(allow_auth, mtls, .{ .name = "sandbox.exec" }, .{ .kind = "sandbox", .id = "sbx_other" }));
    try std.testing.expectError(error.Denied, exerciseAuth(deny_auth, mtls, .{ .name = "sandbox.exec" }, .{ .kind = "sandbox", .id = "sbx_allow" }));
    try std.testing.expectEqual(contract.CanonicalCode.forbidden, adapterCanonical(error.Denied));
    try std.testing.expect(!adapterRetryable(error.Denied));
    try std.testing.expect(adapterRetryable(error.Capacity));
    try std.testing.expect(adapterRetryable(error.Io));

    const allow_store = try Store.bind(qualifiedMeta("store"), allow_ctx, allowBegin, allowCommit, allowRollback, allowReplay);
    const deny_store = try Store.bind(qualifiedMeta("store"), deny_ctx, denyBegin, denyTx, denyTx, denyReplay);
    const replay = try exerciseStore(allow_store, "idem-key-1", "fp-a");
    try std.testing.expectEqual(ReplayOutcome.miss, replay.outcome);
    const replayed = try exerciseStore(allow_store, "idem-key-1", "fp-a");
    try std.testing.expectEqual(ReplayOutcome.replay, replayed.outcome);
    try std.testing.expect(std.mem.eql(u8, replayed.payload, "durable-result"));
    try std.testing.expectError(error.Capacity, exerciseStore(deny_store, "idem-key-1", "fp-a"));

    var buf: [8]u8 = undefined;
    const allow_fs = try Filesystem.bind(qualifiedMeta("fs"), .guest_disk, allow_ctx, allowStat, allowRead, allowWrite);
    const deny_fs = try Filesystem.bind(qualifiedMeta("fs"), .guest_disk, deny_ctx, denyStat, denyRead, denyWrite);
    const st = try exerciseFs(allow_fs, "/workspace/a", buf[0..]);
    try std.testing.expectEqual(@as(u64, 42), st.size);
    try std.testing.expectError(error.NotFound, exerciseFs(allow_fs, "/workspace/missing", buf[0..]));
    try std.testing.expectError(error.Io, deny_fs.stat("/workspace/io"));
    try std.testing.expectError(error.NotFound, deny_fs.stat("/workspace/a"));

    const allow_vm = try bindAllowVm(allow_ctx, .qemu_kvm, .linux_vm_x64, TEST_DIGEST, true);
    const deny_vm = try VmBackend.bind(qualifiedMeta("vm"), .qemu_kvm, .linux_vm_x64, TEST_DIGEST, true, deny_ctx, denyBoot, denyVmOp, denyVmOp, denyVmOp);
    const spec = VmBootSpec{ .image_digest = TEST_DIGEST, .profile = .linux_vm_x64, .lease = .{ .id = "lease_1", .fence = 4 } };
    const instance = try exerciseVm(allow_vm, spec);
    try std.testing.expectEqual(@as(u64, 7), instance.id);
    try std.testing.expectError(error.Invalid, allow_vm.boot(.{ .image_digest = OTHER_DIGEST, .profile = .linux_vm_x64 }));
    try std.testing.expectError(error.NotFound, allow_vm.pause(.{ .id = 99, .fence = 4 }));
    try std.testing.expectError(error.Stale, allow_vm.resumeGuest(.{ .id = 7, .fence = 99 }));
    try std.testing.expectError(error.Capacity, deny_vm.boot(spec));
    try std.testing.expectError(error.NotFound, deny_vm.pause(.{}));
    try std.testing.expectError(error.Stale, deny_vm.pause(.{ .id = 1, .fence = 0 }));

    const allow_net = try Network.bind(qualifiedMeta("network"), "offline", allow_ctx, allowConnect);
    try allow_net.allowConnect("example.com");
    const exp = try ExportBroker.bind(qualifiedMeta("export"), allow_ctx, allowExport, allowAttach);
    const eh = try exp.register();
    try exp.attach(eh, .{ .id = 3 });
    const secrets = try SecretBroker.bind(qualifiedMeta("secret"), allow_ctx, allowSecret);
    try std.testing.expectEqual(@as(usize, 1), try secrets.resolve("ref", buf[0..]));
    const cb = try Callbacks.bind(qualifiedMeta("callbacks"), allow_ctx, allowCallback);
    try std.testing.expect(std.mem.eql(u8, (try cb.register()).id, "cb_1"));
    const metrics = try Metrics.bind(qualifiedMeta("metrics"), allow_ctx, allowMetric);
    try metrics.emit("n");
}

test "result slices remain usable after commit and observe mutation invalidation" {
    var allow = AllowBox{};
    const allow_ctx: *const anyopaque = @ptrCast(&allow);

    const auth = try Auth.bind(qualifiedMeta("auth"), allow_ctx, allowAuthN, allowAuthZ);
    var peer = "spiffe://example/sa/allow".*;
    const mtls = AuthMaterial{ .transport = .mutual_tls, .mtls_peer = peer[0..] };
    const principal = try auth.authenticate(mtls);
    try std.testing.expect(std.mem.eql(u8, principal.id, peer[0..]));
    peer[0] = 'X';
    try std.testing.expectEqual(@as(u8, 'X'), principal.id[0]);

    const store = try Store.bind(qualifiedMeta("store"), allow_ctx, allowBegin, allowCommit, allowRollback, allowReplay);
    var fp: [4]u8 = undefined;
    @memcpy(fp[0..], "fp-a");
    const miss = try exerciseStore(store, "idem-key-1", fp[0..]);
    try std.testing.expectEqual(ReplayOutcome.miss, miss.outcome);
    fp[0] = 'Z';
    const replayed = try exerciseStore(store, "idem-key-1", "fp-a");
    try std.testing.expectEqual(ReplayOutcome.replay, replayed.outcome);
    try std.testing.expect(std.mem.eql(u8, replayed.payload, "durable-result"));
    allow.payload_buf[0] = 'Q';
    try std.testing.expectEqual(@as(u8, 'Q'), replayed.payload[0]);
    const replacement = "CHANGED-result";
    @memcpy(allow.payload_buf[0..replacement.len], replacement);
    try std.testing.expect(std.mem.eql(u8, replayed.payload, replacement));

    const images = try ImageRegistry.bind(qualifiedMeta("image_registry"), allow_ctx, allowResolveImage);
    var digest: [TEST_DIGEST.len]u8 = undefined;
    @memcpy(digest[0..], TEST_DIGEST);
    const resolved = try images.resolve(digest[0..]);
    try std.testing.expect(std.mem.eql(u8, resolved.digest, digest[0..]));
    digest[0] = 'x';
    try std.testing.expectEqual(@as(u8, 'x'), resolved.digest[0]);

    const events = try Events.bind(qualifiedMeta("events"), allow_ctx, allowSubscribe);
    const cursor = try events.subscribe();
    try std.testing.expect(std.mem.eql(u8, cursor.cursor, "cur_1"));
    allow.cursor_buf[0] = 'Z';
    try std.testing.expectEqual(@as(u8, 'Z'), cursor.cursor[0]);

    const cbs = try Callbacks.bind(qualifiedMeta("callbacks"), allow_ctx, allowCallback);
    const cb = try cbs.register();
    try std.testing.expect(std.mem.eql(u8, cb.id, "cb_1"));
    allow.callback_buf[0] = 'Z';
    try std.testing.expectEqual(@as(u8, 'Z'), cb.id[0]);
}

test "pid-only local principal is adapter-backed and invalidated by overwrite" {
    var allow = AllowBox{};
    const allow_ctx: *const anyopaque = @ptrCast(&allow);
    const auth = try Auth.bind(qualifiedMeta("auth"), allow_ctx, allowAuthN, allowAuthZ);

    var token: [5]u8 = undefined;
    @memcpy(token[0..], "tok_a");
    const local_token = AuthMaterial{
        .transport = .local_ipc,
        .local_peer = .{ .pid = 7, .token = token[0..] },
    };
    const token_principal = try auth.authenticate(local_token);
    try std.testing.expect(std.mem.eql(u8, token_principal.id, token[0..]));
    token[0] = 'X';
    try std.testing.expectEqual(@as(u8, 'X'), token_principal.id[0]);

    const pid_only = AuthMaterial{
        .transport = .local_ipc,
        .local_peer = .{ .pid = 42, .token = "" },
    };
    const local_principal = try auth.authenticate(pid_only);
    try std.testing.expectEqual(TransportKind.local_ipc, local_principal.transport);
    try std.testing.expect(std.mem.eql(u8, local_principal.id, "local:peer"));
    try std.testing.expect(std.mem.eql(u8, local_principal.id, allow.local_id_buf[0..local_principal.id.len]));
    allow.local_id_buf[0] = 'X';
    try std.testing.expectEqual(@as(u8, 'X'), local_principal.id[0]);
}

test "unbound vm wrong kind image profile missing lifecycle pause and controls stay unavailable" {
    var allow = AllowBox{};
    const ctx: *const anyopaque = @ptrCast(&allow);
    var seams = unavailable_seams;
    try bindRequiredAllow(&seams, ctx);
    try std.testing.expect(seams.advertisesExecution());

    var unbound = seams;
    unbound.vm = .{};
    unbound.vm.kind = .qemu_kvm;
    unbound.vm.meta.version = contract.CONTRACT_VERSION;
    try std.testing.expect(!unbound.advertisesExecution());
    try std.testing.expectError(error.Unsupported, unbound.vm.boot(.{ .image_digest = TEST_DIGEST }));

    var wrong_kind = seams;
    wrong_kind.vm = try bindAllowVm(ctx, .qemu_whpx, .linux_vm_x64, TEST_DIGEST, true);
    try std.testing.expect(!wrong_kind.advertisesExecution());

    var wrong_image = seams;
    wrong_image.vm = try bindAllowVm(ctx, .qemu_kvm, .linux_vm_x64, OTHER_DIGEST, true);
    try std.testing.expect(!wrong_image.advertisesExecution());

    var wrong_profile = seams;
    wrong_profile.vm = try bindAllowVm(ctx, .qemu_kvm, .linux_vm_arm64, TEST_DIGEST, true);
    try std.testing.expect(!wrong_profile.advertisesExecution());

    var missing_life = seams;
    missing_life.lifecycle = .{};
    try std.testing.expect(!missing_life.advertisesExecution());

    var missing_pause = seams;
    missing_pause.vm = try bindAllowVm(ctx, .qemu_kvm, .linux_vm_x64, TEST_DIGEST, false);
    try std.testing.expect(!missing_pause.advertisesExecution());
    try std.testing.expectError(error.Unsupported, missing_pause.vm.pause(.{ .id = 7, .fence = 4 }));

    var missing_policy = seams;
    missing_policy.policy = .{};
    try std.testing.expect(!missing_policy.advertisesExecution());

    seams.pty = try Pty.bind(qualifiedMeta("pty"), ctx, allowPty);
    try std.testing.expect(contract.capabilitiesFromComposition(seams.toEvidence()).pty);
    seams.inventory = .{};
    try std.testing.expect(!seams.advertisesExecution());
}

test "deny adapters surface denial notfound stale capacity io and retryability" {
    var deny = DenyBox{};
    const ctx: *const anyopaque = @ptrCast(&deny);
    const policy = try Policy.bind(qualifiedMeta("policy"), ctx, denyAdmit);
    const launcher = try Launcher.bind(qualifiedMeta("launcher"), ctx, denyLease, denyRevert);
    const guest = try GuestExposure.bind(qualifiedMeta("guest_exposure"), ctx, denyMount);
    const net = try Network.bind(qualifiedMeta("network"), "offline", ctx, denyConnect);
    const life = try Lifecycle.bind(qualifiedMeta("lifecycle"), ctx, denyLifeCreate, denyLifeDestroy);
    const images = try ImageRegistry.bind(qualifiedMeta("image_registry"), ctx, denyResolveImage);
    const exports = try ExportBroker.bind(qualifiedMeta("export"), ctx, denyExport, denyAttach);
    const secrets = try SecretBroker.bind(qualifiedMeta("secret"), ctx, denySecret);
    const pty = try Pty.bind(qualifiedMeta("pty"), ctx, denyPty);
    const channels = try Channels.bind(qualifiedMeta("channels"), ctx, denyChannel);
    const events = try Events.bind(qualifiedMeta("events"), ctx, denySubscribe);
    const callbacks = try Callbacks.bind(qualifiedMeta("callbacks"), ctx, denyCallback);
    const metrics = try Metrics.bind(qualifiedMeta("metrics"), ctx, denyMetric);
    var scratch: [1]u8 = .{0};
    try std.testing.expectError(error.Denied, policy.admit(.{}));
    try std.testing.expectError(error.Capacity, launcher.createLease());
    try std.testing.expectError(error.NotFound, launcher.revertLease(.{}));
    try std.testing.expectError(error.Denied, guest.mount("/workspace"));
    try std.testing.expectError(error.Denied, net.allowConnect("example.com"));
    try std.testing.expectError(error.Unavailable, life.create());
    try std.testing.expectError(error.NotFound, life.destroy(.{}));
    try std.testing.expectError(error.NotFound, images.resolve(TEST_DIGEST));
    try std.testing.expectError(error.Denied, exports.register());
    try std.testing.expectError(error.Denied, exports.attach(.{}, .{}));
    try std.testing.expectError(error.Denied, secrets.resolve("ref", scratch[0..]));
    try std.testing.expectError(error.Unsupported, pty.open());
    try std.testing.expectError(error.Unsupported, channels.open());
    try std.testing.expectError(error.Unsupported, events.subscribe());
    try std.testing.expectError(error.Unsupported, callbacks.register());
    try std.testing.expectError(error.Unavailable, metrics.emit("n"));
    try std.testing.expectEqual(contract.CanonicalCode.unavailable, adapterCanonical(error.Unavailable));
    try std.testing.expect(adapterRetryable(error.Unavailable));
}

test "feature flags without composition remain unsupported" {
    var allow = AllowBox{};
    const ctx: *const anyopaque = @ptrCast(&allow);
    var seams = unavailable_seams;
    seams.pty = try Pty.bind(qualifiedMeta("pty"), ctx, allowPty);
    seams.channels = try Channels.bind(qualifiedMeta("channels"), ctx, allowChannel);
    seams.events = try Events.bind(qualifiedMeta("events"), ctx, allowSubscribe);
    const caps = contract.capabilitiesFromComposition(seams.toEvidence());
    try std.testing.expect(!caps.execution);
    try std.testing.expect(!caps.pty);
    try std.testing.expect(!caps.channels);
    try std.testing.expect(!caps.sse);
}
