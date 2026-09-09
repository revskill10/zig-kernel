// sched — Process Management: task_struct, runqueue, sched_class vtable
// Clean Entities: Task (pure), SchedEntity. UseCases: schedule(), enqueue(), dequeue().
//   Adapters: sched_class vt (cfs, rt, deadline).
// Enhanced with vinix-parity: enqueue/dequeue, CPU time accounting, runqueue.
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

// CFS-like class (round-robin for simulation)
fn cfs_pick_next() ?*Task {
    if (rq_count == 0) return null;
    // Round-robin: pick front of runqueue, move it to back
    const t = runqueue[0] orelse return null;
    // Rotate: move front to back
    var i: usize = 0;
    while (i < rq_count - 1) : (i += 1) {
        runqueue[i] = runqueue[i + 1];
    }
    runqueue[rq_count - 1] = t;
    return if (t.state == .runnable or t.state == .running) blk: {
        t.state = .running;
        break :blk t;
    } else null;
}

fn cfs_enqueue(t: *Task) void {
    if (rq_count >= MAX_RUNQUEUE) return;
    runqueue[rq_count] = t;
    rq_count += 1;
    t.state = .runnable;
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
    if (task_count >= MAX_TASKS) return null;
    const t = &tasks[task_count];
    t.* = .{ .pid = next_pid, .name = name, .entry = entry };
    next_pid += 1;
    task_count += 1;
    // Auto-enqueue new tasks (vinix: enqueue_thread)
    enqueue(t);
    printk.printk(.info, "sched: created task pid={d} name={s}", .{ t.pid, t.name });
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

/// Run the next scheduled task (analog: vinix scheduler_isr tick handler)
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
        println("__schedule → pid={d} {s} (prio {d}) cpu_time={d}ns", .{ t.pid, t.name, t.priority, t.cpu_time_ns });
        t.beginCpuTime(time_mod.monotonicNs());
        if (t.entry) |e| e();
        t.ticks += 1;
        t.state = .runnable;
        println("tick complete (total_ticks={d})", .{t.ticks});
    } else {
        println("no runnable tasks — idle", .{});
    }
}

pub fn taskCount() usize { return task_count; }
pub fn getTasks() []Task { return tasks[0..task_count]; }

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[INFO] sched: " ++ fmt ++ "\n", args);
}
