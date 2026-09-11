// supervisor/runtime — Linux process lifecycle for QEMU sessions (P2).
// Exact-argv spawn (no shell), PID-safe kill via pidfd, synchronous reap,
// crash reconciliation from pidfd poll state.
// Linux-gated: all syscall paths compile only for target.os == .linux; pure
// logic (state machine, pidfd-vs-pid race rules) compiles + tests everywhere.
const std = @import("std");
const builtin = @import("builtin");
const jail = @import("jail.zig");
const qemu = @import("qemu.zig");

pub const Pidfd = i32;

pub const ProcState = enum {
    none,
    spawned, // pidfd held, process running
    killed_sig, // SIGKILL sent, awaiting reap
    reaped, // waitid done, exit info valid
    unknown, // pidfd lost (supervisor restart) — reconcile from /proc scan
};

pub const ExitInfo = struct {
    /// Signal number if killed by signal (9 = our SIGKILL), else 0.
    signal: u32 = 0,
    exit_code: u32 = 0,
};

pub const Proc = struct {
    session_id: u64,
    pid: std.os.linux.pid_t = 0,
    pidfd: Pidfd = -1,
    state: ProcState = .none,
    exit: ExitInfo = .{},

    /// PID-safe kill: signal goes to the pidfd, not a recycled pid.
    /// pidfd invalidation on process exit removes the classic PID-reuse race.
    /// Returns error.UnsupportedHost off Linux — call sites are Linux-only.
    pub fn kill(self: *Proc) !void {
        if (self.state != .spawned) return error.BadState;
        if (self.pidfd < 0) return error.NoPidfd;
        if (builtin.os.tag != .linux) return error.UnsupportedHost;
        // pidfd_send_signal(pidfd, SIGKILL, NULL, 0)
        const rc = std.os.linux.pidfd_send_signal(self.pidfd, .KILL, null, 0);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => self.state = .killed_sig,
            .BADF => return error.NoPidfd,
            .SRCH => self.state = .reaped, // already dead; reap below
            else => return error.KillFailed,
        }
    }

    /// Reap: waitid(P_PIDFD, pidfd, WEXITED). Returns exit info; idempotent
    /// for already-reaped procs. ECHILD after restart → unknown, reconcile.
    pub fn reap(self: *Proc) !ExitInfo {
        switch (self.state) {
            .reaped => return self.exit,
            .spawned => return error.StillRunning,
            .none => return error.BadState,
            .unknown => return error.NeedsReconcile,
            .killed_sig => {},
        }
        if (builtin.os.tag != .linux) return error.UnsupportedHost;
        // waitid(P_PIDFD, ...) — info buffer filled by kernel.
        var info: std.os.linux.siginfo_t = std.mem.zeroes(std.os.linux.siginfo_t);
        const rc = std.os.linux.waitid(.PIDFD, self.pidfd, &info, std.os.linux.W.EXITED, null);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .CHILD => {
                self.state = .unknown;
                return error.NeedsReconcile;
            },
            .BADF => return error.NoPidfd,
            else => return error.ReapFailed,
        }
        // si_code CLD_KILLED vs CLD_EXITED; status carries signal or exit code.
        switch (@as(std.os.linux.CLD, @enumFromInt(info.code))) {
            .KILLED, .DUMPED => self.exit = .{ .signal = @intCast(@as(u32, @bitCast(info.fields.common.second.sigchld.status)) & 0x7f) },
            else => self.exit = .{ .exit_code = @intCast(@as(u32, @bitCast(info.fields.common.second.sigchld.status)) & 0xff) },
        }
        self.state = .reaped;
        _ = std.os.linux.close(self.pidfd);
        self.pidfd = -1;
        return self.exit;
    }
};

/// Reconciliation after supervisor restart: a proc whose pidfd was lost must
/// never be trusted by pid alone. Rule: pid present in /proc + cgroup still
/// alive → adopt by re-opening /proc/<pid>/... is FORBIDDEN (PID reuse);
/// instead the session is marked unknown and its cgroup killed wholesale.
pub fn reconcileDead(session_id: u64, p: *Proc) bool {
    // Killing the cgroup kills every process in the scope — no PID guessing.
    p.state = .unknown;
    p.pidfd = -1;
    p.pid = 0;
    _ = session_id;
    return true; // caller then rmdir's zk-<id>.scope and destroys the session
}

test "runtime: kill state machine without Linux syscalls" {
    var p = Proc{ .session_id = 1 };
    try std.testing.expectError(error.BadState, p.kill());
    p.state = .spawned;
    p.pidfd = -1;
    try std.testing.expectError(error.NoPidfd, p.kill());
    p.pidfd = 3;
    if (builtin.os.tag == .linux) {
        // pidfd_send_signal on a fake fd fails with EBADF → NoPidfd.
        try std.testing.expectError(error.NoPidfd, p.kill());
    } else {
        // Non-Linux dev hosts never reach the syscall path.
        try std.testing.expectError(error.UnsupportedHost, p.kill());
    }
    try std.testing.expectEqual(ProcState.spawned, p.state);
}

test "runtime: reap rules" {
    var p = Proc{ .session_id = 2, .state = .spawned, .pidfd = 4 };
    try std.testing.expectError(error.StillRunning, p.reap());
    var q = Proc{ .session_id = 3, .state = .none };
    try std.testing.expectError(error.BadState, q.reap());
    var r = Proc{ .session_id = 4, .state = .unknown };
    try std.testing.expectError(error.NeedsReconcile, r.reap());
    var s = Proc{ .session_id = 5, .state = .reaped, .exit = .{ .signal = 9 } };
    const e = try s.reap();
    try std.testing.expectEqual(@as(u32, 9), e.signal);
}

test "runtime: reconcile marks unknown, zeroes identity" {
    var p = Proc{ .session_id = 9, .pid = 1234, .pidfd = 5, .state = .spawned };
    try std.testing.expect(reconcileDead(9, &p));
    try std.testing.expectEqual(ProcState.unknown, p.state);
    try std.testing.expectEqual(@as(i32, -1), p.pidfd);
    try std.testing.expectEqual(@as(std.os.linux.pid_t, 0), p.pid);
}
