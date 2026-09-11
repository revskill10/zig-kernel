// supervisor/session — session lifecycle + generation + deadlines (M4).
// creating→ready→busy→ready→resetting→ready→expired/destroying→destroyed.
// Host-side (Linux std allowed). Time as injected monotonic ms (testable).
const std = @import("std");
const policy = @import("policy.zig");

fn saturatingAdd(a: u64, b: u64) u64 {
    return std.math.add(u64, a, b) catch std.math.maxInt(u64);
}

fn saturatingMul(a: u64, b: u64) u64 {
    return std.math.mul(u64, a, b) catch std.math.maxInt(u64);
}

pub const State = enum {
    creating,
    ready,
    busy,
    resetting,
    expired,
    destroying,
    destroyed,
};

pub const Session = struct {
    id: u64,
    generation: u64 = 1,
    state: State = .creating,
    limits: policy.Limits = .{},
    created_ms: u64 = 0,
    exec_deadline_ms: u64 = 0, // 0 = no active exec

    pub fn init(id: u64, limits: policy.Limits, now_ms: u64) !Session {
        try policy.validate(limits);
        return .{ .id = id, .limits = limits, .created_ms = now_ms };
    }

    pub fn onGuestReady(self: *Session) !void {
        if (self.state != .creating and self.state != .resetting) return error.BadState;
        self.state = .ready;
    }

    pub fn startExec(self: *Session, generation: u64, now_ms: u64) !void {
        if (self.state != .ready) return error.BadState;
        if (generation != self.generation) return error.StaleGeneration;
        self.state = .busy;
        self.exec_deadline_ms = saturatingAdd(now_ms, self.limits.execution_timeout_ms);
    }

    pub fn finishExec(self: *Session, generation: u64) !void {
        if (self.state != .busy) return error.BadState;
        if (generation != self.generation) return error.StaleGeneration;
        self.state = .ready;
        self.exec_deadline_ms = 0;
    }

    /// Host-enforced deadline: true when busy past deadline (supervisor kills VM).
    pub fn execTimedOut(self: *const Session, now_ms: u64) bool {
        return self.state == .busy and self.exec_deadline_ms != 0 and now_ms >= self.exec_deadline_ms;
    }

    pub fn expiresAt(self: *const Session) u64 {
        return saturatingAdd(self.created_ms, saturatingMul(self.limits.session_ttl_seconds, 1000));
    }

    pub fn isExpired(self: *const Session, now_ms: u64) bool {
        return now_ms >= self.expiresAt();
    }

    pub fn beginReset(self: *Session) !void {
        if (self.state != .ready and self.state != .busy and self.state != .expired) return error.BadState;
        self.state = .resetting;
    }

    /// Reset completes only after old VM+storage destroyed (caller enforces).
    pub fn finishReset(self: *Session) !void {
        if (self.state != .resetting) return error.BadState;
        self.generation += 1;
        self.exec_deadline_ms = 0;
        self.state = .ready;
    }

    pub fn beginDestroy(self: *Session) !void {
        if (self.state == .destroyed or self.state == .destroying) return error.BadState;
        self.state = .destroying;
    }

    pub fn finishDestroy(self: *Session) !void {
        if (self.state != .destroying) return error.BadState;
        self.state = .destroyed;
    }
};

test "session: ready→exec→done lifecycle" {
    var s = try Session.init(1, .{}, 0);
    try s.onGuestReady();
    try std.testing.expect(s.state == .ready);
    try s.startExec(1, 1000);
    try std.testing.expect(s.state == .busy);
    try std.testing.expect(!s.execTimedOut(1000 + 59_999));
    try std.testing.expect(s.execTimedOut(1000 + 60_000));
    try s.finishExec(1);
    try std.testing.expect(s.state == .ready);
}

test "session: stale generation + bad transitions rejected" {
    var s = try Session.init(1, .{}, 0);
    try std.testing.expectError(error.BadState, s.startExec(1, 0)); // creating
    try s.onGuestReady();
    try std.testing.expectError(error.StaleGeneration, s.startExec(2, 0));
    try std.testing.expectError(error.BadState, s.finishExec(1)); // not busy
    try std.testing.expectError(error.BadState, s.finishReset());
    try s.startExec(1, 0);
    try s.beginReset(); // reset kills busy exec
    try s.finishReset();
    try std.testing.expectEqual(@as(u64, 2), s.generation);
    try std.testing.expectError(error.StaleGeneration, s.startExec(1, 0));
    try s.startExec(2, 0);
    try s.finishExec(2);
}

test "session: expiry + destroy idempotency guard" {
    var s = try Session.init(1, .{ .session_ttl_seconds = 60 }, 0);
    try s.onGuestReady();
    try std.testing.expect(!s.isExpired(59_999));
    try std.testing.expect(s.isExpired(60_000));
    try s.beginDestroy();
    try s.finishDestroy();
    try std.testing.expect(s.state == .destroyed);
    try std.testing.expectError(error.BadState, s.beginDestroy()); // already gone
}

test "session: deadlines saturate under hostile clock values" {
    const max = std.math.maxInt(u64);
    var s = try Session.init(1, .{}, max - 1);
    try s.onGuestReady();
    try s.startExec(1, max - 1);
    try std.testing.expectEqual(max, s.exec_deadline_ms);
    try std.testing.expect(!s.execTimedOut(max - 1));
    try std.testing.expect(s.execTimedOut(max));
    try std.testing.expectEqual(max, s.expiresAt());
    try std.testing.expect(!s.isExpired(max - 1));
    try std.testing.expect(s.isExpired(max));
}
