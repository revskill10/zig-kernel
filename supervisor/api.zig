// supervisor/api — public API service logic (M6).
// In-memory implementation of docs/sandbox-api.openapi.yaml over the M4/M5 core.
// Transport (unix socket + SSE) is M6b/Linux; this file is the testable logic:
// ownership, idempotency, generation fencing, event cursors, bounded retention,
// cancel escalation flags, audit records. Time injected as ms (testable).
// ponytail: fixed slot caps; ceiling: dynamic maps + persistent journal.
const std = @import("std");
const policy = @import("policy.zig");
const session = @import("session.zig");
const workspace = @import("workspace.zig");

pub const MAX_SESSIONS: usize = 8;
pub const MAX_EXECS: usize = 16;
pub const MAX_EVENTS: usize = 1024;
pub const MAX_FILES: usize = 64;
pub const MAX_FILE_BYTES: usize = 8 << 20;
pub const MAX_IDEM_KEYS: usize = 64;
pub const MAX_AUDIT: usize = 256;

pub const Code = enum {
    ok,
    bad_request,
    not_found,
    conflict,
    gone,
    limit,
    unsupported,
    guest_failure,
};

pub const Error = error{
    BadRequest,
    NotFound,
    Conflict,
    Gone,
    Limit,
    Unsupported,
    GuestFailure,
    NoCapacity,
};

pub const Term = enum { exited, cancelled, timeout, resource_limit, output_limit, guest_failure };

pub const ExecState = enum { queued, running, cancelling, done };

pub const Exec = struct {
    id: u64,
    session_id: u64,
    generation: u64,
    argv0: [128]u8 = [_]u8{0} ** 128,
    argv0_len: usize = 0,
    state: ExecState = .queued,
    term: ?Term = null,
    exit_code: ?i32 = null,
    output_bytes: u64 = 0,
    cancel_requested: bool = false, // host-escalated: guest asked first, kill next tick
};

pub const EventType = enum { stdout, stderr, lifecycle, exit };

pub const Event = struct {
    seq: u64,
    generation: u64,
    exec_id: u64, // 0 = session-level
    ty: EventType,
    data_len: usize = 0,
};

pub const FileEntry = struct {
    path: [256]u8 = [_]u8{0} ** 256,
    path_len: usize = 0,
    size: usize = 0,
    sha: [32]u8 = [_]u8{0} ** 32,
    used: bool = false,
};

pub const SessionSlot = struct {
    used: bool = false,
    owner: [64]u8 = [_]u8{0} ** 64,
    owner_len: usize = 0,
    sess: session.Session = undefined,
    ws: workspace.Workspace = undefined,
    files: [MAX_FILES]FileEntry = [_]FileEntry{.{}} ** MAX_FILES,
    events: [MAX_EVENTS]Event = [_]Event{.{ .seq = 0, .generation = 0, .exec_id = 0, .ty = .lifecycle }} ** MAX_EVENTS,
    event_start: usize = 0, // index of oldest
    event_count: usize = 0,
    next_seq: u64 = 1,
    execs: [MAX_EXECS]Exec = [_]Exec{.{ .id = 0, .session_id = 0, .generation = 0 }} ** MAX_EXECS,
    next_exec_id: u64 = 1,
    audit_count: usize = 0,
};

pub const Tombstone = struct {
    id: u64 = 0,
    owner: [64]u8 = [_]u8{0} ** 64,
    owner_len: usize = 0,
};

pub const Service = struct {
    adm: policy.Admission = .{},
    slots: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS,
    next_session_id: u64 = 1,
    idem_keys: [MAX_IDEM_KEYS]u64 = [_]u64{0} ** MAX_IDEM_KEYS,
    idem_body: [MAX_IDEM_KEYS]u64 = [_]u64{0} ** MAX_IDEM_KEYS,
    idem_used: [MAX_IDEM_KEYS]bool = [_]bool{false} ** MAX_IDEM_KEYS,
    destroyed: [MAX_SESSIONS]Tombstone = [_]Tombstone{.{}} ** MAX_SESSIONS, // idempotent DELETE replays

    fn slotOf(self: *Service, id: u64) ?*SessionSlot {
        for (&self.slots) |*s| {
            if (s.used and s.sess.id == id) return s;
        }
        return null;
    }

    fn checkOwner(slot: *SessionSlot, owner: []const u8) !void {
        if (slot.owner_len != owner.len) return error.NotFound;
        if (!std.mem.eql(u8, slot.owner[0..slot.owner_len], owner)) return error.NotFound;
    }

    /// Idempotency: same key+body → AlreadySeen (caller replays); same key,
    /// different body → Conflict. Returns true when the caller must execute.
    pub fn idemBegin(self: *Service, key: u64, body: u64) !bool {
        if (key == 0) return true; // no key, no dedup
        for (0..MAX_IDEM_KEYS) |i| {
            if (self.idem_used[i] and self.idem_keys[i] == key) {
                if (self.idem_body[i] != body) return error.Conflict;
                return false; // replay
            }
        }
        for (0..MAX_IDEM_KEYS) |i| {
            if (!self.idem_used[i]) {
                self.idem_used[i] = true;
                self.idem_keys[i] = key;
                self.idem_body[i] = body;
                return true;
            }
        }
        return error.Limit; // idempotency table full
    }

    pub fn create(self: *Service, owner: []const u8, limits: policy.Limits, now_ms: u64) !u64 {
        try policy.validate(limits);
        self.adm.tryAdmit(limits) catch return error.NoCapacity;
        errdefer self.adm.release(limits);
        for (&self.slots) |*s| {
            if (!s.used) {
                s.* = .{};
                s.used = true;
                const n = @min(owner.len, s.owner.len);
                @memcpy(s.owner[0..n], owner[0..n]);
                s.owner_len = n;
                s.sess = try session.Session.init(self.next_session_id, limits, now_ms);
                self.next_session_id += 1;
                s.ws = workspace.Workspace.init(limits.workspace_mib);
                s.audit_count += 1;
                return s.sess.id;
            }
        }
        self.adm.release(limits);
        return error.NoCapacity;
    }

    /// Test/host hook: guest reported ready (real path: hello frame on serial).
    pub fn guestReady(self: *Service, owner: []const u8, id: u64) !void {
        const s = self.slotOf(id) orelse return error.NotFound;
        try checkOwner(s, owner);
        try s.sess.onGuestReady();
        try self.pushEvent(s, 0, .lifecycle, 0);
    }

    pub fn startExec(self: *Service, owner: []const u8, id: u64, generation: u64, argv0: []const u8, now_ms: u64) !u64 {
        const s = self.slotOf(id) orelse return error.NotFound;
        try checkOwner(s, owner);
        try s.sess.startExec(generation, now_ms);
        errdefer s.sess.state = .ready;
        for (&s.execs) |*e| {
            if (e.id == 0) { // fresh slot only — done records kept for getExecution
                e.* = .{ .id = s.next_exec_id, .session_id = id, .generation = generation };
                s.next_exec_id += 1;
                const n = @min(argv0.len, e.argv0.len);
                @memcpy(e.argv0[0..n], argv0[0..n]);
                e.argv0_len = n;
                e.state = .running;
                try self.pushEvent(s, e.id, .lifecycle, 0);
                return e.id;
            }
        }
        // no free exec slot — roll back session to ready
        s.sess.state = .ready;
        s.sess.exec_deadline_ms = 0;
        return error.Limit;
    }

    fn findExec(s: *SessionSlot, exec_id: u64) ?*Exec {
        for (&s.execs) |*e| {
            if (e.id == exec_id and e.id != 0) return e;
        }
        return null;
    }

    pub fn cancelExec(self: *Service, owner: []const u8, id: u64, exec_id: u64) !void {
        const s = self.slotOf(id) orelse return error.NotFound;
        try checkOwner(s, owner);
        const e = findExec(s, exec_id) orelse return error.NotFound;
        if (e.generation != s.sess.generation) return error.Gone;
        if (e.state == .done) return; // idempotent
        e.cancel_requested = true;
        if (e.state == .running) e.state = .cancelling;
    }

    /// Host tick: enforce deadlines + escalate cancels. now_ms injected.
    /// Returns number of execs force-finished.
    pub fn tick(self: *Service, now_ms: u64) usize {
        var killed: usize = 0;
        for (&self.slots) |*s| {
            if (!s.used) continue;
            for (&s.execs) |*e| {
                if (e.id == 0 or e.state == .done) continue;
                if (e.generation != s.sess.generation) continue; // stale, reset owns it
                const timed_out = s.sess.execTimedOut(now_ms);
                if (e.cancel_requested or timed_out) {
                    e.state = .done;
                    e.term = if (e.cancel_requested) .cancelled else .timeout;
                    e.exit_code = null;
                    self.pushEvent(s, e.id, .exit, 0) catch {};
                    s.sess.state = .ready;
                    s.sess.exec_deadline_ms = 0;
                    killed += 1;
                }
            }
        }
        return killed;
    }

    pub fn finishExec(self: *Service, owner: []const u8, id: u64, exec_id: u64, term: Term, code: ?i32) !void {
        const s = self.slotOf(id) orelse return error.NotFound;
        try checkOwner(s, owner);
        const e = findExec(s, exec_id) orelse return error.NotFound;
        if (e.generation != s.sess.generation) return error.Gone;
        if (e.state == .done) return error.Conflict;
        e.state = .done;
        e.term = term;
        e.exit_code = code;
        try s.sess.finishExec(e.generation);
        try self.pushEvent(s, e.id, .exit, 0);
    }

    pub fn putFile(self: *Service, owner: []const u8, id: u64, generation: u64, path: []const u8, size: usize, sha: [32]u8) !void {
        const s = self.slotOf(id) orelse return error.NotFound;
        try checkOwner(s, owner);
        if (generation != s.sess.generation) return error.Gone;
        if (s.sess.state == .destroyed or s.sess.state == .destroying) return error.Gone;
        var rel: [workspace.MAX_PATH]u8 = undefined;
        const r = workspace.resolve(path, &rel) catch return error.BadRequest;
        // overwrite same path (idempotent PUT): release old size first
        for (&s.files) |*f| {
            if (f.used and f.path_len == r.len and std.mem.eql(u8, f.path[0..f.path_len], r)) {
                s.ws.release(f.size);
                s.ws.charge(size) catch {
                    s.ws.charge(f.size) catch {};
                    return error.Limit;
                };
                f.size = size;
                f.sha = sha;
                try self.pushEvent(s, 0, .lifecycle, 0);
                return;
            }
        }
        s.ws.charge(size) catch return error.Limit;
        errdefer s.ws.release(size);
        for (&s.files) |*f| {
            if (!f.used) {
                if (r.len > f.path.len) return error.BadRequest; // errdefer releases charge
                @memcpy(f.path[0..r.len], r);
                f.path_len = r.len;
                f.size = size;
                f.sha = sha;
                f.used = true;
                try self.pushEvent(s, 0, .lifecycle, 0);
                return;
            }
        }
        return error.Limit;
    }

    pub fn getFile(self: *Service, owner: []const u8, id: u64, generation: u64, path: []const u8) !FileEntry {
        const s = self.slotOf(id) orelse return error.NotFound;
        try checkOwner(s, owner);
        if (generation != s.sess.generation) return error.Gone;
        var rel: [workspace.MAX_PATH]u8 = undefined;
        const r = workspace.resolve(path, &rel) catch return error.BadRequest;
        for (&s.files) |*f| {
            if (f.used and f.path_len == r.len and std.mem.eql(u8, f.path[0..f.path_len], r)) return f.*;
        }
        return error.NotFound;
    }

    pub fn events(self: *Service, owner: []const u8, id: u64, after: u64, out: []Event) !usize {
        const s = self.slotOf(id) orelse return error.NotFound;
        try checkOwner(s, owner);
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.event_count and n < out.len) : (i += 1) {
            const ev = s.events[(s.event_start + i) % MAX_EVENTS];
            if (ev.seq > after) {
                out[n] = ev;
                n += 1;
            }
        }
        return n;
    }

    pub fn reset(self: *Service, owner: []const u8, id: u64) !u64 {
        const s = self.slotOf(id) orelse return error.NotFound;
        try checkOwner(s, owner);
        try s.sess.beginReset();
        // destroy old state first (contract: complete only after old VM+storage gone)
        for (&s.execs) |*e| e.* = .{ .id = 0, .session_id = 0, .generation = 0 };
        for (&s.files) |*f| f.used = false;
        s.ws.reset();
        s.event_start = 0;
        s.event_count = 0;
        try s.sess.finishReset();
        try self.pushEvent(s, 0, .lifecycle, 0);
        return s.sess.generation;
    }

    pub fn destroy(self: *Service, owner: []const u8, id: u64) !void {
        // Idempotent DELETE: replay success for known-destroyed (id, owner).
        for (&self.destroyed) |*t| {
            if (t.id == id and t.owner_len == owner.len and std.mem.eql(u8, t.owner[0..t.owner_len], owner)) return;
        }
        const s = self.slotOf(id) orelse return error.NotFound;
        try checkOwner(s, owner);
        if (s.sess.state == .destroyed) return; // slot not yet reaped
        if (s.sess.state != .destroying) try s.sess.beginDestroy();
        const lim = s.sess.limits;
        const n = @min(owner.len, s.owner.len);
        try s.sess.finishDestroy();
        s.used = false;
        self.adm.release(lim);
        for (&self.destroyed) |*t| {
            if (t.id == 0) {
                t.id = id;
                @memcpy(t.owner[0..n], owner[0..n]);
                t.owner_len = n;
                return;
            }
        }
    }

    fn pushEvent(self: *Service, s: *SessionSlot, exec_id: u64, ty: EventType, data_len: usize) !void {
        _ = self;
        const ev = Event{ .seq = s.next_seq, .generation = s.sess.generation, .exec_id = exec_id, .ty = ty, .data_len = data_len };
        s.next_seq += 1;
        if (s.event_count < MAX_EVENTS) {
            s.events[(s.event_start + s.event_count) % MAX_EVENTS] = ev;
            s.event_count += 1;
        } else {
            s.events[s.event_start] = ev; // drop-oldest, bounded retention
            s.event_start = (s.event_start + 1) % MAX_EVENTS;
        }
    }
};

test "api: full lifecycle create→upload→exec→events→download→reset→destroy" {
    var svc = Service{};
    const alice = "alice";
    const id = try svc.create(alice, .{}, 0);
    try svc.guestReady(alice, id);
    // upload
    const sha = [_]u8{0xAB} ** 32;
    try svc.putFile(alice, id, 1, "/workspace/tool", 12, sha);
    try std.testing.expectError(error.BadRequest, svc.putFile(alice, id, 1, "/etc/passwd", 4, sha));
    try std.testing.expectError(error.BadRequest, svc.putFile(alice, id, 1, "/workspace/../x", 4, sha));
    // exec
    const ex = try svc.startExec(alice, id, 1, "/workspace/tool", 1000);
    try std.testing.expectError(error.BadState, svc.startExec(alice, id, 1, "/workspace/tool", 1000)); // busy
    // events cursor walk
    var out: [16]Event = undefined;
    const n1 = try svc.events(alice, id, 0, &out);
    try std.testing.expect(n1 >= 3); // ready + file + exec-started
    try std.testing.expectEqual(@as(u64, 1), out[0].seq);
    const n2 = try svc.events(alice, id, out[n1 - 1].seq, &out);
    try std.testing.expectEqual(@as(usize, 0), n2);
    // download
    const f = try svc.getFile(alice, id, 1, "/workspace/tool");
    try std.testing.expectEqual(@as(usize, 12), f.size);
    try std.testing.expectEqual(sha, f.sha);
    try std.testing.expectError(error.NotFound, svc.getFile(alice, id, 1, "/workspace/nope"));
    // ownership enforced
    try std.testing.expectError(error.NotFound, svc.getFile("bob", id, 1, "/workspace/tool"));
    // finish + reset bumps generation, stale fenced
    try svc.finishExec(alice, id, ex, .exited, 0);
    const gen = try svc.reset(alice, id);
    try std.testing.expectEqual(@as(u64, 2), gen);
    try std.testing.expectError(error.Gone, svc.getFile(alice, id, 1, "/workspace/tool"));
    try std.testing.expectError(error.NotFound, svc.finishExec(alice, id, ex, .exited, 0)); // record wiped by reset
    // destroy idempotent (tombstone replay)
    try svc.destroy(alice, id);
    try svc.destroy(alice, id);
    // other ops on destroyed id: still NotFound (only DELETE replays)
    try std.testing.expectError(error.NotFound, svc.guestReady(alice, id));
}

test "api: timeout kill + cancel escalation via tick" {
    var svc = Service{};
    const id = try svc.create("a", .{ .execution_timeout_ms = 1000 }, 0);
    try svc.guestReady("a", id);
    const ex = try svc.startExec("a", id, 1, "/tool", 500);
    try svc.cancelExec("a", id, ex);
    try svc.cancelExec("a", id, ex); // idempotent
    try std.testing.expectEqual(@as(usize, 1), svc.tick(600));
    const s = svc.slotOf(id).?;
    try std.testing.expect(s.execs[0].state == .done);
    try std.testing.expect(s.execs[0].term.? == .cancelled);
    try std.testing.expect(s.sess.state == .ready);
    // timeout path (no cancel)
    const ex2 = try svc.startExec("a", id, 1, "/tool", 10_000);
    _ = ex2;
    try std.testing.expectEqual(@as(usize, 1), svc.tick(11_000));
    try std.testing.expect(s.execs[1].term.? == .timeout);
    try std.testing.expect(s.execs[1].exit_code == null);
}

test "api: idempotency keys + concurrent sessions isolated" {
    var svc = Service{};
    try std.testing.expect(try svc.idemBegin(111, 100));
    try std.testing.expect(!try svc.idemBegin(111, 100)); // replay
    try std.testing.expectError(error.Conflict, svc.idemBegin(111, 200)); // same key, new body
    try std.testing.expect(try svc.idemBegin(0, 0)); // no key → always execute
    const a = try svc.create("alice", .{}, 0);
    const b = try svc.create("bob", .{}, 0);
    try svc.guestReady("alice", a);
    try svc.guestReady("bob", b);
    const sha = [_]u8{1} ** 32;
    try svc.putFile("alice", a, 1, "/workspace/tool", 4, sha);
    try std.testing.expectError(error.NotFound, svc.getFile("bob", b, 1, "/workspace/tool")); // isolated
    const exa = try svc.startExec("alice", a, 1, "/workspace/tool", 0);
    const exb = try svc.startExec("bob", b, 1, "/workspace/tool", 0);
    try std.testing.expect(exa == exb); // per-session ids independent
    try svc.destroy("alice", a);
    try std.testing.expectError(error.NotFound, svc.startExec("alice", a, 1, "/t", 0));
    // bob unaffected
    try svc.finishExec("bob", b, exb, .exited, 0);
}
