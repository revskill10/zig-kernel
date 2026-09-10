// supervisor/policy — admission control + limit validation (M4).
// Host-side tool (Linux): std allowed. Pure logic, fully tested.
// QEMU/KVM process management is Linux-gated (no QEMU on this dev box;
// qualified in M7 on Linux/KVM).
const std = @import("std");

pub const Limits = struct {
    vcpus: u32 = 1,
    memory_mib: u32 = 128,
    workspace_mib: u32 = 32,
    processes: u32 = 16,
    execution_timeout_ms: u64 = 60_000,
    session_ttl_seconds: u64 = 900,
    output_bytes: u64 = 1 << 20,
};

pub const CEILINGS = Limits{
    .vcpus = 8,
    .memory_mib = 4096,
    .workspace_mib = 1024,
    .processes = 64,
    .execution_timeout_ms = 600_000,
    .session_ttl_seconds = 86_400,
    .output_bytes = 16 << 20,
};

pub const FLOORS = Limits{
    .vcpus = 1,
    .memory_mib = 32,
    .workspace_mib = 8,
    .processes = 1,
    .execution_timeout_ms = 1_000,
    .session_ttl_seconds = 60,
    .output_bytes = 64 << 10,
};

/// Unsupported or unenforceable limits fail explicitly (contract rule).
pub fn validate(l: Limits) !void {
    if (l.vcpus < FLOORS.vcpus or l.vcpus > CEILINGS.vcpus) return error.BadLimits;
    if (l.memory_mib < FLOORS.memory_mib or l.memory_mib > CEILINGS.memory_mib) return error.BadLimits;
    if (l.workspace_mib < FLOORS.workspace_mib or l.workspace_mib > CEILINGS.workspace_mib) return error.BadLimits;
    if (l.processes < FLOORS.processes or l.processes > CEILINGS.processes) return error.BadLimits;
    if (l.execution_timeout_ms < FLOORS.execution_timeout_ms or l.execution_timeout_ms > CEILINGS.execution_timeout_ms) return error.BadLimits;
    if (l.session_ttl_seconds < FLOORS.session_ttl_seconds or l.session_ttl_seconds > CEILINGS.session_ttl_seconds) return error.BadLimits;
    if (l.output_bytes < FLOORS.output_bytes or l.output_bytes > CEILINGS.output_bytes) return error.BadLimits;
}

pub const Admission = struct {
    max_sessions: usize = 8,
    mem_budget_mib: u64 = 8192,
    active: usize = 0,
    mem_used_mib: u64 = 0,

    pub fn tryAdmit(self: *Admission, l: Limits) !void {
        try validate(l);
        if (self.active >= self.max_sessions) return error.NoCapacity;
        if (self.mem_used_mib + l.memory_mib > self.mem_budget_mib) return error.NoCapacity;
        self.active += 1;
        self.mem_used_mib += l.memory_mib;
    }

    pub fn release(self: *Admission, l: Limits) void {
        if (self.active > 0) self.active -= 1;
        self.mem_used_mib = if (self.mem_used_mib > l.memory_mib) self.mem_used_mib - l.memory_mib else 0;
    }
};

test "policy: defaults valid, ceilings enforced" {
    try validate(.{});
    try std.testing.expectError(error.BadLimits, validate(.{ .vcpus = 0 }));
    try std.testing.expectError(error.BadLimits, validate(.{ .vcpus = 9 }));
    try std.testing.expectError(error.BadLimits, validate(.{ .memory_mib = 16 }));
    try std.testing.expectError(error.BadLimits, validate(.{ .memory_mib = 8192 }));
    try std.testing.expectError(error.BadLimits, validate(.{ .execution_timeout_ms = 100 }));
    try std.testing.expectError(error.BadLimits, validate(.{ .output_bytes = 1024 }));
    try validate(CEILINGS);
}

test "policy: admission budget + release" {
    var a = Admission{ .max_sessions = 2, .mem_budget_mib = 256 };
    try a.tryAdmit(.{ .memory_mib = 128 });
    try a.tryAdmit(.{ .memory_mib = 128 });
    try std.testing.expectError(error.NoCapacity, a.tryAdmit(.{})); // session cap
    a.release(.{ .memory_mib = 128 });
    try std.testing.expectError(error.NoCapacity, a.tryAdmit(.{ .memory_mib = 256 })); // mem cap
    try a.tryAdmit(.{ .memory_mib = 128 });
    try std.testing.expectEqual(@as(usize, 2), a.active);
    try std.testing.expectEqual(@as(u64, 256), a.mem_used_mib);
}
