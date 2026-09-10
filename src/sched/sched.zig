// sched — Process Management: task_struct, runqueue, sched_class vtable
// Clean Entities: Task (pure), SchedEntity. UseCases: schedule(), enqueue(), dequeue().
//   Adapters: sched_class vt (cfs, rt, deadline).
// Enhanced with vinix-parity: enqueue/dequeue, CPU time accounting, runqueue.
// p0-sched: preemptive time-sliced priority scheduler (Linux CFS-lite analog).
const std = @import("std");
const printk = @import("../lib/printk.zig");
const signal = @import("../signal/signal.zig");
const time_mod = @import("../time/time.zig");

pub const TaskState = enum { running, runnable, sleeping, stopped, zombie };

pub const Task = struct {
    pid: u32,
    name: []const u8,
    state: TaskState = .runnable,
    priority: u8 = 120, // CFS nice 0
    ticks: u32 = 0,
    entry: ?*const fn () void = null,
    // Signal state (vinix parity: inline sig_state)
    sig_state: signal.SigState = .{},
    exit_code: isize = 0,
    // CPU time accounting (vinix parity: begin_cpu_time / charge_cpu_time)
    scheduled_at_ns: u64 = 0,
    cpu_time_ns: u64 = 0,
    // p0-sched: preemption state
    slice_remaining: u32 = 0, // remaining ticks in this slice
    vruntime: u64 = 0, // virtual runtime accumulator (weighted)
    need_resched: bool = false,

    /// Borrow signal state for the signal module to access without circular import.
    pub fn sigState(self: *Task) ?*signal.SigState {
        return &self.sig_state;
    }

    /// Begin CPU time accounting — mark start of a CPU turn
    pub fn beginCpuTime(self: *Task, now_ns: u64) void {
        self.scheduled_at_ns = now_ns;
    }

    /// Charge accumulated CPU time from the current turn to the task's total
    pub fn chargeCpuTime(self: *Task, now_ns: u64) void {
        const started = self.scheduled_at_ns;
        self.scheduled_at_ns = 0;
        if (started == 0 or now_ns <= started) return;
        const span = now_ns - started;
        self.cpu_time_ns += span;
    }

    /// Get total CPU time in nanoseconds
    pub fn cpuTimeNs(self: *const Task) u64 {
        return self.cpu_time_ns;
    }
};

pub const MAX_TASKS: usize = 32;
pub const MAX_RUNQUEUE: usize = 32;

/// Default time slice in ticks (Linux SCHED_TIMESLICE analog: ~1-6ms; here ticks).
pub const DEFAULT_SLICE: u32 = 3;
/// Nice-to-weight: higher weight = more CPU share (Linux sched_prio_to_weight).
pub fn niceWeight(prio: u8) u32 {
    const delta: i32 = @as(i32, prio) - 120;
    const abs_delta: u32 = @intCast(if (delta < 0) -delta else delta);
    const base: u32 = 1024;
    if (delta == 0) return base;
    // Approximation of Linux weight curve: 1024 * (1.25 ^ -delta)
    var w: u32 = base;
    var i: u32 = 0;
    if (delta < 0) {
        while (i < abs_delta) : (i += 1) w = w * 5 / 4;
    } else {
        while (i < abs_delta) : (i += 1) w = w * 4 / 5;
    }
    return if (w == 0) 1 else w;
}

var tasks: [MAX_TASKS]Task = undefined;
var task_count: usize = 0;
var next_pid: u32 = 1;
var current: usize = 0;

// Runqueue — vinix parity: scheduler_running_queue
var runqueue: [MAX_RUNQUEUE]?*Task = [_]?*Task{null} ** MAX_RUNQUEUE;
var rq_count: usize = 0;

// Comptime vtable analog to struct sched_class
pub const SchedClass = struct {
    name: []const u8,
    pick_next: *const fn () ?*Task,
    enqueue: *const fn (*Task) void,
    dequeue: *const fn (*Task) void,
};

// CFS-lite class: strict priority preemption, weighted round-robin within prio.
fn cfs_pick_next() ?*Task {
    if (rq_count == 0) return null;
    // Pick highest-priority (lowest prio number) runnable task with min vruntime.
    var best: ?*Task = null;
    var i: usize = 0;
    while (i < rq_count) : (i += 1) {
        const t = runqueue[i] orelse continue;
        if (t.state != .runnable and t.state != .running) continue;
        if (best == null) { best = t; continue; }
        const b = best.?;
        if (t.priority < b.priority) { best = t; continue; }
        if (t.priority == b.priority and t.vruntime < b.vruntime) best = t;
    }
    const t = best orelse return null;
    t.state = .running;
    if (t.slice_remaining == 0) t.slice_remaining = DEFAULT_SLICE;
    return t;
}

fn cfs_enqueue(t: *Task) void {
    if (rq_count >= MAX_RUNQUEUE) return;
    // Dedup: already queued
    var i: usize = 0;
    while (i < rq_count) : (i += 1) {
        if (runqueue[i]) |q| { if (q.pid == t.pid) return; }
    }
    runqueue[rq_count] = t;
    rq_count += 1;
    t.state = .runnable;
    if (t.slice_remaining == 0) t.slice_remaining = DEFAULT_SLICE;
}

fn cfs_dequeue(t: *Task) void {
    var i: usize = 0;
    while (i < rq_count) : (i += 1) {
        if (runqueue[i]) |task| {
            if (task.pid == t.pid) {
                // Swap-remove from runqueue
                runqueue[i] = runqueue[rq_count - 1];
                runqueue[rq_count - 1] = null;
                rq_count -= 1;
                t.state = .stopped;
                return;
            }
        }
    }
}

pub const cfs_class = SchedClass{ .name = "cfs", .pick_next = cfs_pick_next, .enqueue = cfs_enqueue, .dequeue = cfs_dequeue };
pub var active_class: *const SchedClass = &cfs_class;

pub fn init() void {
    task_count = 0;
    current = 0;
    next_pid = 1;
    rq_count = 0;
    for (&runqueue) |*slot| slot.* = null;
    for (&tasks) |*t| t.* = .{ .pid = 0, .name = "" };
    printk.printk(.info, "sched: CFS/RT/Deadline framework ready (rq per-CPU simulated, class={s})", .{active_class.name});
}

pub fn create(name: []const u8, entry: ?*const fn () void) ?*Task {
    return createWithPrio(name, entry, 120);
}

pub fn createWithPrio(name: []const u8, entry: ?*const fn () void, prio: u8) ?*Task {
    if (task_count >= MAX_TASKS) return null;
    const t = &tasks[task_count];
    t.* = .{ .pid = next_pid, .name = name, .entry = entry, .priority = prio, .slice_remaining = DEFAULT_SLICE };
    next_pid += 1;
    task_count += 1;
    // Auto-enqueue new tasks (vinix: enqueue_thread)
    enqueue(t);
    printk.printk(.info, "sched: created task pid={d} name={s} prio={d}", .{ t.pid, t.name, prio });
    return t;
}

/// Enqueue a task onto the runqueue (vinix: sched.enqueue_thread)
pub fn enqueue(t: *Task) void {
    active_class.enqueue(t);
}

/// Dequeue a task from the runqueue (vinix: sched.dequeue_thread)
pub fn dequeue(t: *Task) void {
    active_class.dequeue(t);
}

/// Dequeue current task and enter idle loop (noreturn)
/// (analog: vinix sched.dequeue_and_die)
pub fn dequeueAndDie() noreturn {
    const t = schedule() orelse {
        // No tasks to schedule — idle
        while (true) {
            std.Thread.yield() catch {};
        }
    };
    t.beginCpuTime(time_mod.monotonicNs());
    if (t.entry) |e| e();
    unreachable;
}

pub fn schedule() ?*Task {
    // __schedule analog — iterates sched_class priority
    return active_class.pick_next();
}

/// p0-sched: per-tick preemption hook (analog: scheduler_tick / task_tick_fair).
/// Call once per timer tick. Charges 1 tick of slice + vruntime weight to the
/// running task; sets need_resched when the slice expires. Returns true if a
/// reschedule should run.
pub fn schedTick() bool {
    if (current >= task_count) return false;
    const t = &tasks[current];
    if (t.state != .running) return false;
    if (t.slice_remaining > 0) t.slice_remaining -= 1;
    // vruntime advances inversely with weight: lower prio = faster vruntime
    const w = niceWeight(t.priority);
    t.vruntime += 1024 * 1024 / w; // scaled tick credit
    if (t.slice_remaining == 0) {
        t.need_resched = true;
        return true;
    }
    // Strict priority preemption: a higher-prio runnable task forces resched.
    var i: usize = 0;
    while (i < rq_count) : (i += 1) {
        if (runqueue[i]) |q| {
            if (q.pid != t.pid and q.priority < t.priority and
                (q.state == .runnable or q.state == .running))
            {
                t.need_resched = true;
                return true;
            }
        }
    }
    return false;
}

/// Run the next scheduled task (analog: vinix scheduler_isr tick handler).
/// If need_resched is set on the running task, honor it: charge time, rotate.
pub fn runNext() void {
    // Charge CPU time on the previously running task
    if (current < task_count and tasks[current].state == .running) {
        tasks[current].chargeCpuTime(time_mod.monotonicNs());
    }

    if (schedule()) |t| {
        // Find the task index for current tracking
        var idx: usize = 0;
        while (idx < task_count) : (idx += 1) {
            if (tasks[idx].pid == t.pid) { current = idx; break; }
        }
        t.state = .running;
        t.need_resched = false;
        println("__schedule → pid={d} {s} (prio {d}) cpu_time={d}ns vr={d}", .{ t.pid, t.name, t.priority, t.cpu_time_ns, t.vruntime });
        t.beginCpuTime(time_mod.monotonicNs());
        if (t.entry) |e| e();
        t.ticks += 1;
        if (t.slice_remaining > 0) t.slice_remaining -= 1;
        if (t.slice_remaining == 0) {
            // Slice expired: rotate back to runnable, pick another next time
            t.state = .runnable;
        }
        println("tick complete (total_ticks={d} slice_left={d})", .{ t.ticks, t.slice_remaining });
    } else {
        println("no runnable tasks — idle", .{});
    }
}

pub fn taskCount() usize { return task_count; }
pub fn getTasks() []Task { return tasks[0..task_count]; }
pub fn currentTask() ?*Task {
    if (current < task_count) return &tasks[current];
    return null;
}

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[INFO] sched: " ++ fmt ++ "\n", args);
}

// ── p0-sched tests ──
test "sched: priority preemption — higher prio runs first" {
    init();
    const low = createWithPrio("low", null, 130);
    const high = createWithPrio("high", null, 100);
    try std.testing.expect(low != null);
    try std.testing.expect(high != null);
    const picked = schedule().?;
    try std.testing.expectEqualStrings("high", picked.name);
}

test "sched: time slice expiry forces rotate" {
    init();
    _ = createWithPrio("a", null, 120);
    _ = createWithPrio("b", null, 120);
    const first = schedule().?;
    try std.testing.expect(first.state == .running);
    // Burn the whole slice via ticks: each tick decrements, expiry sets need_resched
    var switched = false;
    var i: u32 = 0;
    while (i < DEFAULT_SLICE + 1) : (i += 1) {
        if (schedTick()) { switched = true; break; }
    }
    try std.testing.expect(switched);
    const second = schedule().?;
    try std.testing.expect(second.pid != first.pid);
}

test "sched: cpu_time accumulates via charge" {
    init();
    const t = createWithPrio("acct", null, 120).?;
    t.beginCpuTime(1000);
    t.chargeCpuTime(5000);
    try std.testing.expectEqual(@as(u64, 4000), t.cpuTimeNs());
    // No-op when not started
    t.chargeCpuTime(9000);
    try std.testing.expectEqual(@as(u64, 4000), t.cpuTimeNs());
}

test "sched: nice weight monotonic" {
    try std.testing.expect(niceWeight(100) > niceWeight(120));
    try std.testing.expect(niceWeight(120) > niceWeight(139));
    try std.testing.expectEqual(@as(u32, 1024), niceWeight(120));
}
