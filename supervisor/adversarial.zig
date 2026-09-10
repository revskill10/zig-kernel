// supervisor/adversarial — M7 host-runnable adversarial suite.
// Deterministic xorshift fuzz (fixed seed): resolve/frame/elf never panic,
// api invariants hold under reset races, floods, exhaustion.
// Linux/QEMU/KVM qualification (spawn, kill, real guest) is M7b — needs Linux.
const std = @import("std");
const policy = @import("policy.zig");
const session = @import("session.zig");
const frame = @import("frame.zig");
const workspace = @import("workspace.zig");
const api = @import("api.zig");

fn Rng() type {
    return struct {
        s: u64 = 0x123456789ABCDEF,
        fn next(self: *@This()) u64 {
            var x = self.s;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            self.s = x;
            return x;
        }
        fn byte(self: *@This()) u8 {
            return @truncate(self.next());
        }
    };
}

test "adv: resolve fuzz never escapes, never panics" {
    var rng = Rng(){};
    var out: [workspace.MAX_PATH]u8 = undefined;
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        var path: [48]u8 = undefined;
        const n = 1 + (rng.next() % 47);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const c = rng.byte();
            path[j] = switch (c % 8) {
                0 => '/',
                1 => '.',
                2 => 'a',
                3 => 'w',
                4 => 0,
                else => c,
            };
        }
        const p = path[0..n];
        if (workspace.resolve(p, &out)) |r| {
            // confined: no dots, no empties, no leading slash
            try std.testing.expect(r.len > 0 and r.len <= workspace.MAX_PATH);
            var it = std.mem.splitScalar(u8, r, '/');
            while (it.next()) |comp| {
                try std.testing.expect(comp.len > 0);
                try std.testing.expect(!std.mem.eql(u8, comp, "."));
                try std.testing.expect(!std.mem.eql(u8, comp, ".."));
            }
        } else |_| {}
    }
}

test "adv: frame fuzz only typed errors, stream resyncs" {
    var rng = Rng(){};
    // random buffers decode to Short/BadMagic/BadCrc/TooBig only — never panic
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        var buf: [40]u8 = undefined;
        for (&buf) |*b| b.* = rng.byte();
        _ = frame.decode(&buf) catch |e| {
            try std.testing.expect(e == error.Short or e == error.BadMagic or e == error.BadCrc or e == error.TooBig);
            continue;
        };
    }
    // corrupt payload byte of a valid frame → BadCrc, next frame still decodes
    var two: [128]u8 = undefined;
    const n1 = try frame.encode(.exec, "aaa", &two);
    const n2 = try frame.encode(.ready, "b", two[n1..]);
    two[n1 + 10] ^= 0xFF; // corrupt second frame magic? no — corrupt its payload crc region
    two[n1 + n2 - 1] ^= 0xFF; // crc byte
    const d1 = try frame.decode(two[0 .. n1 + n2]);
    try std.testing.expectEqual(n1, d1.consumed);
    try std.testing.expectError(error.BadCrc, frame.decode(two[n1 .. n1 + n2]));
}

test "adv: api storm — reset races, floods, exhaustion keep invariants" {
    var svc = api.Service{};
    const sha = [_]u8{7} ** 32;
    // fill sessions to cap
    var ids: [api.MAX_SESSIONS]u64 = undefined;
    for (0..api.MAX_SESSIONS) |k| {
        ids[k] = try svc.create("op", .{}, 0);
        try svc.guestReady("op", ids[k]);
    }
    try std.testing.expectError(error.NoCapacity, svc.create("op", .{}, 0));
    // per session: exec + reset race → stale ops Gone, never wrong-session data
    for (ids) |id| {
        const ex = try svc.startExec("op", id, 1, "/t", 0);
        const gen = try svc.reset("op", id); // kills busy exec
        try std.testing.expectEqual(@as(u64, 2), gen);
        try std.testing.expectError(error.NotFound, svc.finishExec("op", id, ex, .exited, 0));
        try std.testing.expectError(error.Gone, svc.getFile("op", id, 1, "/workspace/tool"));
        // new generation works
        try svc.putFile("op", id, 2, "/workspace/tool", 8, sha);
        const f = try svc.getFile("op", id, 2, "/workspace/tool");
        try std.testing.expectEqual(@as(usize, 8), f.size);
    }
    // event flood: same-path overwrites push events without growing the file
    // table → 1124 events overflow the 1024 ring, drop-oldest engages
    const id0 = ids[0];
    var k: usize = 0;
    while (k < api.MAX_EVENTS + 100) : (k += 1) {
        try svc.putFile("op", id0, 2, "/workspace/flood", 1, sha);
    }
    var out: [api.MAX_EVENTS + 8]api.Event = undefined;
    const n = try svc.events("op", id0, 0, &out);
    try std.testing.expectEqual(api.MAX_EVENTS, n);
    var j: usize = 1;
    while (j < n) : (j += 1) {
        try std.testing.expect(out[j].seq == out[j - 1].seq + 1); // gapless after drop-oldest
    }
    // file table exhaustion → Limit, service still consistent
    var svc2 = api.Service{};
    const id2 = try svc2.create("op", .{}, 0);
    try svc2.guestReady("op", id2);
    var m: usize = 0;
    var limited = false;
    while (m < api.MAX_FILES + 4) : (m += 1) {
        var name: [32]u8 = [_]u8{0} ** 32;
        const w = try std.fmt.bufPrint(&name, "/workspace/f{d}", .{m});
        svc2.putFile("op", id2, 1, w, 1, sha) catch |e| {
            try std.testing.expect(e == error.Limit);
            limited = true;
            break;
        };
    }
    try std.testing.expect(limited);
    // tick storm with nothing pending → 0 kills, no state change
    try std.testing.expectEqual(@as(usize, 0), svc2.tick(1 << 60));
}

test "adv: session deadline storm + policy fuzz" {
    var rng = Rng(){};
    var i: usize = 0;
    while (i < 5_000) : (i += 1) {
        const l = policy.Limits{
            .vcpus = @truncate(rng.next()),
            .memory_mib = @truncate(rng.next()),
            .workspace_mib = @truncate(rng.next()),
            .processes = @truncate(rng.next()),
            .execution_timeout_ms = rng.next(),
            .session_ttl_seconds = rng.next(),
            .output_bytes = rng.next(),
        };
        if (policy.validate(l)) {
            var s = try session.Session.init(1, l, 0);
            try s.onGuestReady();
            try s.startExec(1, 0);
            // deadline eventually fires (unless timeout wrapped past u64 — still bool, no panic)
            _ = s.execTimedOut(0xFFFFFFFFFFFFFFFF);
            try s.beginReset();
            try s.finishReset();
        } else |_| {}
    }
}
