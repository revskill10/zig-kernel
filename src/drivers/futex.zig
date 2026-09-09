// drivers/futex — Fast Userspace Mutex (analog: kernel/futex.c)
// Uses address-based hashing for wait/wake
const std = @import("std");
const printk = @import("../lib/printk.zig");

const FUTEX_WAIT: usize = 0;
const FUTEX_WAKE: usize = 1;

pub const FutexOp = enum {
    wait,
    wake,
};

const MAX_FUTEXES: usize = 64;
const FutexWaiter = struct {
    addr: u64,
    thread_id: u32,
};

var waiters: [MAX_FUTEXES]FutexWaiter = undefined;
var waiter_count: usize = 0;

pub fn init() void {
    waiter_count = 0;
    for (&waiters) |*w| w.* = .{ .addr = 0, .thread_id = 0 };
    printk.printk(.info, "futex: subsystem ready (max_waiters={d})", .{ MAX_FUTEXES });
}

pub fn wait(addr: u64, expected: u32) i32 {
    printk.printk(.info, "futex: wait(addr=0x{x}, expected={d})", .{ addr, expected });
    // In hosted sim: simulate immediate EAGAIN (no actual blocked threads)
    if (waiter_count < MAX_FUTEXES) {
        waiters[waiter_count] = .{
            .addr = addr,
            .thread_id = 0, // current thread (simulated)
        };
        waiter_count += 1;
    }
    // Return EAGAIN since we can't actually block in hosted sim
    return -11; // -EAGAIN
}

pub fn wake(addr: u64) i32 {
    var woken: i32 = 0;
    var i: usize = 0;
    var new_count: usize = 0;
    while (i < waiter_count) : (i += 1) {
        if (waiters[i].addr == addr) {
            woken += 1;
        } else {
            waiters[new_count] = waiters[i];
            new_count += 1;
        }
    }
    waiter_count = new_count;
    println("[INFO] futex: wake(addr=0x{x}) → woke {d} waiters\n", .{ addr, woken });
    return woken;
}

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
