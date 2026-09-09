// time — Kernel clocks, timers, and sleep (analog: vinix time module)
// Clean: Entity (TimeSpec, Timer), UseCases (monotonicNs, newTimer), Framework (clocks)
const std = @import("std");
const printk = @import("../lib/printk.zig");
const klock = @import("../lib/klock.zig");
const eventstruct = @import("../event/eventstruct.zig");

pub const timerFrequency: u64 = 1000; // 1000 Hz (vinix analog)

pub const clockTypeMonotonic: u32 = 0;
pub const clockTypeRealtime: u32 = 1;

const maxTimers: usize = 8;
const maxTickHooks: usize = 8;

/// TimeSpec — matches Linux struct timespec (analog: vinix TimeSpec)
pub const TimeSpec = extern struct {
    tv_sec: i64 = 0,
    tv_nsec: i64 = 0,

    pub fn add(self: *TimeSpec, interval: TimeSpec) void {
        if (self.tv_nsec + interval.tv_nsec > 999_999_999) {
            const diff = (self.tv_nsec + interval.tv_nsec) - 1_000_000_000;
            self.tv_nsec = diff;
            self.tv_sec += 1;
        } else {
            self.tv_nsec += interval.tv_nsec;
        }
        self.tv_sec += interval.tv_sec;
    }

    pub fn sub(self: *TimeSpec, interval: TimeSpec) bool {
        if (interval.tv_nsec > self.tv_nsec) {
            const diff = interval.tv_nsec - self.tv_nsec;
            self.tv_nsec = 999_999_999 - diff;
            if (self.tv_sec == 0) {
                self.tv_sec = 0;
                self.tv_nsec = 0;
                return true;
            }
            self.tv_sec -= 1;
        } else {
            self.tv_nsec -= interval.tv_nsec;
        }
        if (interval.tv_sec > self.tv_sec) {
            self.tv_sec = 0;
            self.tv_nsec = 0;
            return true;
        }
        self.tv_sec -= interval.tv_sec;
        if (self.tv_sec == 0 and self.tv_nsec == 0) {
            return true;
        }
        return false;
    }
};

// ─── Global clocks ─────────────────────────────────────────────────────────

var monotonicClock: TimeSpec = .{};
var realtimeClock: TimeSpec = .{};

var clockTickLock: klock.Lock = .{};
var timersLock: klock.Lock = .{};

var armedTimers: [maxTimers]?*Timer = [_]?*Timer{null} ** maxTimers;
var timerStorage: [maxTimers]Timer = undefined;
var timerCount: usize = 0;

var tickHooks: [maxTickHooks]*const fn () void = undefined;
var tickHooksLen: usize = 0;
var tickHooksLock: klock.Lock = .{};

/// monotonicNs — monotonic clock as u64 nanoseconds
pub fn monotonicNs() u64 {
    const seconds = monotonicClock.tv_sec;
    const nanoseconds = monotonicClock.tv_nsec;
    if (seconds < 0 or nanoseconds < 0) {
        return 0;
    }
    return @as(u64, @intCast(seconds)) * 1_000_000_000 + @as(u64, @intCast(nanoseconds));
}

/// Advance clocks by an interval (simulated tick)
pub fn advanceClocks(interval: TimeSpec) void {
    monotonicClock.add(interval);
    realtimeClock.add(interval);

    timersLock.acquire();
    defer timersLock.release();

    var i: usize = 0;
    while (i < timerCount) : (i += 1) {
        if (armedTimers[i]) |timer| {
            if (!timer.fired) {
                var remaining = timer.when;
                if (remaining.sub(interval)) {
                    timer.fired = true;
                    timer.event.signal();
                }
            }
        }
    }

    // Fire tick hooks
    const count = tickHooksLen;
    tickHooksLock.acquire();
    var j: usize = 0;
    while (j < count) : (j += 1) {
        tickHooks[j]();
    }
    tickHooksLock.release();
}

/// Timer — armed timer with deadline and event for wakeup
pub const Timer = struct {
    when: TimeSpec = .{},
    event: eventstruct.Event = .{},
    index: i32 = -1,
    fired: bool = false,

    pub fn disarm(self: *Timer) void {
        timersLock.acquire();
        defer timersLock.release();

        if (timerCount == 0 or self.index == -1) {
            return;
        }
        if (self.index >= timerCount) {
            return;
        }

        // Swap-remove from armed list
        armedTimers[self.index] = armedTimers[timerCount - 1];
        if (armedTimers[self.index]) |t| {
            t.index = self.index;
        }
        armedTimers[timerCount - 1] = null;
        timerCount -= 1;
        self.index = -1;
    }

    pub fn arm(self: *Timer) void {
        timersLock.acquire();
        defer timersLock.release();

        self.fired = false;
        self.index = @intCast(timerCount);
        if (timerCount < maxTimers) {
            armedTimers[timerCount] = self;
            timerCount += 1;
        }
    }
};

/// newTimer — alloc a Timer, set deadline, arm it
pub fn newTimer(when: TimeSpec) *Timer {
    if (timerCount >= maxTimers) {
        panic("time: timer pool exhausted");
    }
    const t = &timerStorage[timerCount];
    t.* = .{ .when = when, .event = .{ .lock = .{} }, .index = -1, .fired = false };
    t.event.init();
    t.arm();
    return t;
}

/// registerTickHook — register a callback invoked on every clock tick
pub fn registerTickHook(hook: fn () void) bool {
    tickHooksLock.acquire();
    defer tickHooksLock.release();

    if (tickHooksLen >= maxTickHooks) {
        return false;
    }
    tickHooks[tickHooksLen] = hook;
    tickHooksLen += 1;
    return true;
}

fn panic(msg: []const u8) noreturn {
    printk.printk(.emerg, "time: FATAL: {s}", .{msg});
    unreachable;
}

/// Simulated sleep — in hosted mode, advances clock by requested ns and returns
pub fn nsleep(ns: i64) void {
    const interval = TimeSpec{
        .tv_sec = @divTrunc(ns, 1_000_000_000),
        .tv_nsec = @rem(ns, 1_000_000_000),
    };
    advanceClocks(interval);
}

pub fn init() void {
    monotonicClock = .{};
    realtimeClock = .{};
    timerCount = 0;
    tickHooksLen = 0;
    println("[INFO] time: clocks + timer wheel ready (freq={d} Hz)", .{timerFrequency});
}

fn println(comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.comptimePrint(fmt, args);
    std.debug.print("{s}\n", .{formatted});
}
