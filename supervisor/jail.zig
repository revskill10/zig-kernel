// supervisor/jail — OS-level confinement spec + launcher plan (P2).
// Pure: computes per-session UID, cgroup v2 paths, namespace flags, seccomp
// profile name, and the exact exec spec for the privileged launcher.
// Actual syscalls live in runtime.zig (Linux-gated); every value here is
// host-testable. No limit may exist only in memory (fail condition #4).
const std = @import("std");
const policy = @import("policy.zig");

/// Deterministic per-session UID/GID in a dedicated range (never root, never
/// a login UID). Session id → uid is injective so ownership checks are O(1).
pub const UID_BASE: u32 = 400_000; // above typical login UID ranges; document in /etc/login.defs
pub const UID_SPAN: u32 = 8_192; // max_sessions ceiling * generations

pub fn uidFor(session_id: u64) !u32 {
    if (session_id == 0 or session_id >= UID_SPAN) return error.BadSessionId;
    return UID_BASE + @as(u32, @intCast(session_id));
}

/// cgroup v2 scope path for a session, relative to the supervisor's delegated
/// cgroup root. One scope per QEMU process; limits written before spawn.
pub fn cgroupPath(session_id: u64, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "zk-{d}.scope", .{session_id});
}

/// cpuset is not set (vcpus enforced by QEMU -smp); cpu.max + memory.max +
/// pids.max come from policy.Limits. Storage quota enforced at FS layer (P5).
pub const CgroupLimits = struct {
    cpu_max: [32]u8, // e.g. "100000 100000" (1 cpu) — quota period
    memory_max: [32]u8, // e.g. "268435456" bytes
    pids_max: [32]u8,
};

pub fn cgroupLimits(l: policy.Limits) !CgroupLimits {
    var out: CgroupLimits = undefined;
    // cpu.max: quota period 100ms; quota = period * vcpus
    @memset(&out.cpu_max, 0);
    @memset(&out.memory_max, 0);
    @memset(&out.pids_max, 0);
    const quota = @as(u64, l.vcpus) * 100_000;
    _ = try std.fmt.bufPrint(&out.cpu_max, "{d} 100000", .{quota});
    _ = try std.fmt.bufPrint(&out.memory_max, "{d}", .{@as(u64, l.memory_mib) * 1024 * 1024});
    _ = try std.fmt.bufPrint(&out.pids_max, "{d}", .{l.processes});
    return out;
}

/// Namespace set applied by the launcher (clone3 flags). User namespace maps
/// the session UID; mount ns gives private /tmp; pid+net isolate process table
/// and remove any host network visibility (belt-and-braces with -nic none).
pub const NsFlags = struct {
    user_ns: bool = true,
    mount_ns: bool = true,
    pid_ns: bool = true,
    net_ns: bool = true,
    ipc_ns: bool = true,
    uts_ns: bool = true,
    // cgroup ns off: supervisor delegates one cgroup subtree; QEMU stays in it.
    cgroup_ns: bool = false,
};

pub const ExecSpec = struct {
    /// Absolute path, no PATH lookup, no shell.
    program: [*:0]const u8,
    /// Exact argv[0..]; argv[0] = program. Launcher execve's directly.
    argv: []const [*:0]const u8,
    /// Empty environment: no credentials, no PATH, no host context leaks.
    envp: []const [*:0]const u8 = &.{},
    uid: u32,
    gid: u32,
    /// no_new_privs is always set before exec (seccomp prerequisite).
    no_new_privs: bool = true,
    /// Seccomp allowlist profile name (BPF program resolved by launcher).
    seccomp_profile: [*:0]const u8 = "zk-qemu-allow",
    /// stdio: all three closed; serial is a unix socket owned by supervisor.
    close_stdio: bool = true,
};

test "jail: uid deterministic, nonzero, range" {
    try std.testing.expectEqual(@as(u32, 400_001), try uidFor(1));
    try std.testing.expectEqual(@as(u32, 400_042), try uidFor(42));
    try std.testing.expectError(error.BadSessionId, uidFor(0));
    try std.testing.expectError(error.BadSessionId, uidFor(UID_SPAN));
}

test "jail: cgroup path + limits from policy" {
    var buf: [64]u8 = undefined;
    const p = try cgroupPath(7, &buf);
    try std.testing.expectEqualStrings("zk-7.scope", p);
    const cl = try cgroupLimits(.{ .vcpus = 2, .memory_mib = 256, .processes = 16 });
    try std.testing.expectEqualStrings("200000 100000", std.mem.sliceTo(&cl.cpu_max, 0));
    try std.testing.expectEqualStrings("268435456", std.mem.sliceTo(&cl.memory_max, 0));
    try std.testing.expectEqualStrings("16", std.mem.sliceTo(&cl.pids_max, 0));
}

test "jail: exec spec shape" {
    const spec = ExecSpec{
        .program = "/usr/bin/qemu-system-x86_64",
        .argv = &.{ "/usr/bin/qemu-system-x86_64", "-nodefaults" },
        .uid = 400_001,
        .gid = 400_001,
    };
    try std.testing.expect(spec.no_new_privs);
    try std.testing.expectEqual(@as(usize, 0), spec.envp.len);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.span(spec.program), "/"));
}
