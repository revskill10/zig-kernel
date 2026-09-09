// event/eventstruct — Event/listener infrastructure (analog: vinix eventstruct module)
// Clean: low-level event primitive used by proc, sched, futex
// Enhanced with trigger/await for vinix parity.
const std = @import("std");
const klock = @import("../lib/klock.zig");
const printk = @import("../lib/printk.zig");

pub const MAX_LISTENERS: usize = 64;

/// A listener to an event: which thread is waiting and on which event slot
pub const EventListener = struct {
    thread_id: usize = 0,
    which: u64 = 0, // event slot index
};

/// Event: a synchronization primitive that threads can wait on
/// Analog to wake-up events used by futex, wait queues, signal delivery
pub const Event = struct {
    lock: klock.Lock = .{},
    pending: u64 = 0,         // number of pending wakeups
    listeners_i: u64 = 0,     // number of registered listeners
    listeners: [MAX_LISTENERS]EventListener = undefined,

    pub fn init(self: *Event) void {
        self.lock = .{};
        self.pending = 0;
        self.listeners_i = 0;
    }

    /// Register a thread as waiting on this event
    pub fn addListener(self: *Event, thread_id: usize, which: u64) bool {
        self.lock.acquire();
        defer self.lock.release();
        if (self.listeners_i >= MAX_LISTENERS) return false;
        self.listeners[self.listeners_i] = .{ .thread_id = thread_id, .which = which };
        self.listeners_i += 1;
        return true;
    }

    /// Remove a listener
    pub fn removeListener(self: *Event, thread_id: usize) void {
        self.lock.acquire();
        defer self.lock.release();
        var i: u64 = 0;
        while (i < self.listeners_i) : (i += 1) {
            if (self.listeners[i].thread_id == thread_id) {
                // Swap-remove
                self.listeners[i] = self.listeners[self.listeners_i - 1];
                self.listeners_i -= 1;
                return;
            }
        }
    }

    /// Signal the event: increment pending count (no waiter wakeup)
    pub fn signal(self: *Event) void {
        self.lock.acquire();
        defer self.lock.release();
        self.pending += 1;
    }

    /// Trigger: wake up one waiter, or increment pending if no listeners
    /// (analog: vinix event.trigger)
    pub fn trigger(self: *Event, drop: bool) u64 {
        self.lock.acquire();
        defer self.lock.release();

        if (self.listeners_i == 0) {
            if (!drop) {
                self.pending += 1;
            }
            return 0;
        }

        // Wake all listeners (vinix behavior: enqueue all)
        const woken: u64 = self.listeners_i;
        self.listeners_i = 0;
        // In hosted sim, listeners are woken by setting pending
        self.pending += woken;
        return woken;
    }

    /// Check if there's a pending event, consume it
    pub fn tryConsume(self: *Event) bool {
        self.lock.acquire();
        defer self.lock.release();
        if (self.pending > 0) {
            self.pending -= 1;
            return true;
        }
        return false;
    }

/// Check for any pending event across multiple events (non-blocking)
/// Returns the index of the first event with pending > 0, consuming one wakeup.
pub fn checkPending(events: []const *Event) ?u64 {
        for (events, 0..) |ev, i| {
            _ = ev.lock.acquire();
            if (ev.pending > 0) {
                ev.pending -= 1;
                ev.lock.release();
                return @intCast(i);
            }
            ev.lock.release();
        }
        return null;
    }

    /// Block until this event has a pending wakeup, then consume it.
    /// In hosted simulation, this spins briefly (no real thread blocking).
    /// (analog: vinix event.await for single event)
    pub fn await(self: *Event) void {
        self.lock.acquire();
        while (self.pending == 0) {
            // In real kernel: call sched.yield() to release CPU
            // Hosted sim: release lock, yield, reacquire
            self.lock.release();
            std.Thread.yield() catch {};
            self.lock.acquire();
        }
        self.pending -= 1;
        self.lock.release();
    }

    pub fn listenerCount(self: *const Event) u64 {
        return self.listeners_i;
    }

    pub fn pendingCount(self: *const Event) u64 {
        return self.pending;
    }
};

/// Package-level await: check multiple events for pending signals.
/// Returns index of first event with a pending wakeup (consumed), or null.
/// If block is true and no event is pending, simulates blocking via yield.
/// (analog: vinix event.await(mut events, block) ?u64)
pub fn await(events: []const *Event, block: bool) ?u64 {
    // Non-blocking check first
    if (Event.checkPending(events)) |which| {
        return which;
    }

    if (!block) {
        return null;
    }

    // Blocking: spin-yield until one event fires
    // In real kernel: attach listeners, dequeue thread, yield, wake on trigger
    var spin: usize = 0;
    while (spin < 1000) : (spin += 1) {
        std.Thread.yield() catch {};
        if (Event.checkPending(events)) |which| {
            return which;
        }
    }

    printk.printk(.debug, "event: await timed out after {d} spins", .{spin});
    return null;
}
