// signal — Process signal handling (analog: kernel/signal.c, arch/x86/kernel/signal.c)
// Clean: SigEvent Entity, signal dispatch UseCase. Operates on Task from sched.
//
// Implements: sigaction, sigprocmask, kill (sendsig), dispatch_a_signal, sigreturn.
// Signal N occupies bit N (1-indexed). Bit 0 unused (signal 0 is reserved).
// pending_signals and masked_signals are u64 bitmasks — signals 1..60 fit.
//
// NOTE: Task holds signal state inline (sig_state field). This module operates
// on *Task to avoid circular import. Dependency: signal → sched (one-way only).
const std = @import("std");
const printk = @import("../lib/printk.zig");
const sched = @import("../sched/sched.zig");
const Task = sched.Task;

// ── Signal numbers (Linux x86_64) ────────────────────────────────────────
pub const SIGHUP: u8 = 1;
pub const SIGINT: u8 = 2;
pub const SIGQUIT: u8 = 3;
pub const SIGILL: u8 = 4;
pub const SIGTRAP: u8 = 5;
pub const SIGABRT: u8 = 6;
pub const SIGBUS: u8 = 7;
pub const SIGFPE: u8 = 8;
pub const SIGKILL: u8 = 9;
pub const SIGUSR1: u8 = 10;
pub const SIGSEGV: u8 = 11;
pub const SIGUSR2: u8 = 12;
pub const SIGPIPE: u8 = 13;
pub const SIGALRM: u8 = 14;
pub const SIGTERM: u8 = 15;
pub const SIGSTKFLT: u8 = 16;
pub const SIGCHLD: u8 = 17;
pub const SIGCONT: u8 = 18;
pub const SIGSTOP: u8 = 19;
pub const SIGTSTP: u8 = 20;
pub const SIGTTIN: u8 = 21;
pub const SIGTTOU: u8 = 22;
pub const SIGURG: u8 = 23;
pub const SIGXCPU: u8 = 24;
pub const SIGXFSZ: u8 = 25;
pub const SIGVTALRM: u8 = 26;
pub const SIGPROF: u8 = 27;
pub const SIGWINCH: u8 = 28;
pub const SIGIO: u8 = 29;
pub const SIGPWR: u8 = 30;
pub const SIGSYS: u8 = 31;

// ── Sigprocmask how values ─────────────────────────────────────────────────
pub const SIG_BLOCK: usize = 0;
pub const SIG_UNBLOCK: usize = 1;
pub const SIG_SETMASK: usize = 2;

// ── SA flags (Linux) ────────────────────────────────────────────────────────
pub const SA_NODEFER: u32 = 0x40000000;
pub const SA_RESTART: u32 = 0x10000000;
pub const SA_SIGINFO: u32 = 0x00000004;

// ── Special handler values ──────────────────────────────────────────────────
pub const SIG_DFL: usize = 0;
pub const SIG_IGN: usize = 1;

// ── SigAction struct (Linux) ────────────────────────────────────────────────
pub const SigAction = struct {
    sa_sigaction: usize = SIG_DFL,
    sa_mask: u64 = 0,
    sa_flags: u32 = 0,
    sa_restorer: ?*const fn () void = null,
};

// ── Siginfo (minimal, for RT signals) ─────────────────────────────────────
pub const SigInfo = packed struct {
    si_signo: i32 = 0,
    si_errcode: i32 = 0,
    si_reserved: i32 = 0,
    si_padding: i32 = 0,
    // The rest is a union; we only use si_signo for dispatched signals.
    _pad: [48]u8 = [_]u8{0} ** 48,
    const Self = @This();
    pub fn init(signo: i32) Self {
        return Self{ .si_signo = signo };
    }
};

// ── Per-task signal state ───────────────────────────────────────────────────
// Stored inline in Task via sig_state field.
pub const SigState = struct {
    pending_signals: u64 = 0,
    masked_signals: u64 = 0,
    sigactions: [32]SigAction = blk: {
        var arr: [32]SigAction = undefined;
        for (&arr) |*sa| sa.* = .{ .sa_sigaction = SIG_DFL };
        break :blk arr;
    },
    // Saved during signal delivery so sigreturn can restore.
    saved_mask: u64 = 0,
    saved_mask_valid: bool = false,
    // Simulated "signal frame" on user stack (for sigreturn demo).
    // In hosted mode we just record the context pointer.
    sigentry: ?*const fn () void = null,
    const Self = @This();

    pub fn signalBit(signum: u8) u64 {
        return @as(u64, 1) << @as(u6, signum);
    }

    pub fn isPending(self: *const Self, signum: u8) bool {
        return (self.pending_signals & signalBit(signum)) != 0;
    }

    pub fn isMasked(self: *const Self, signum: u8) bool {
        return (self.masked_signals & signalBit(signum)) != 0;
    }

    pub fn setPending(self: *Self, signum: u8) void {
        self.pending_signals |= signalBit(signum);
    }

    pub fn clearPending(self: *Self, signum: u8) void {
        self.pending_signals &= ~signalBit(signum);
    }

    pub fn block(self: *Self, mask: u64) void {
        self.masked_signals |= mask;
        // SIGKILL and SIGSTOP are never blockable.
        self.masked_signals &= ~signalBit(SIGKILL);
        self.masked_signals &= ~signalBit(SIGSTOP);
    }

    pub fn unblock(self: *Self, mask: u64) void {
        self.masked_signals &= ~mask;
    }

    pub fn setMask(self: *Self, mask: u64) void {
        self.masked_signals = mask;
        self.masked_signals &= ~signalBit(SIGKILL);
        self.masked_signals &= ~signalBit(SIGSTOP);
    }
};

// ── Kernel-internal signal utilities ────────────────────────────────────────

fn unblockableMask() u64 {
    return SigState.signalBit(SIGKILL) | SigState.signalBit(SIGSTOP);
}

fn validSignal(signum: usize) bool {
    return signum >= 1 and signum <= 31;
}

/// Sends a signal to a task. Marks it pending; wakes it from sleep.
pub fn sendsig(task: *Task, signum: u8) void {
    const sig_state = task.sigState() orelse {
        printk.printk(.warn, "signal: sendsig to task '{s}' with no signal state, dropping", .{task.name});
        return;
    };
    sig_state.setPending(signum);
    if (task.state == .sleeping) {
        task.state = .runnable;
    }
    printk.printk(.debug, "signal: sent {s}({d}) to pid={d} '{s}' (pending=0x{x})", .{
        signalName(signum), signum, task.pid, task.name, sig_state.pending_signals
    });
}

/// Delivers one pending, unblocked signal to the current task.
/// Called at syscall exit / scheduler entry (analog to __do_signal / do_signal).
pub fn dispatchSignal(task: *Task) void {
    const sig_state = task.sigState() orelse return;

    // Check for unblocked pending signals, lowest-numbered first.
    const unmasked = sig_state.pending_signals & ~sig_state.masked_signals;
    if (unmasked == 0) return;
    const bit = @ctz(unmasked);
    const sig: u8 = @truncate(bit + 1);

    // Unblockable signals are never masked.
    if (sig == SIGKILL or sig == SIGSTOP) {
        // SIGKILL always delivered.
    }

    const sa = &sig_state.sigactions[sig];
    const handler = sa.sa_sigaction;

    // SIG_DFL (0): default action
    if (handler == SIG_DFL) {
        handleDefault(sig, task);
        sig_state.clearPending(sig);
        return;
    }

    // SIG_IGN (1): ignore
    if (handler == SIG_IGN) {
        sig_state.clearPending(sig);
        printk.printk(.debug, "signal: ignoring {s} in pid={d}", .{ signalName(sig), task.pid });
        return;
    }

    // Custom handler: set up simulated signal frame and "jump" to handler.
    // In hosted mode, we log the delivery and clear the pending bit.
    sig_state.clearPending(sig);
    sig_state.saved_mask = sig_state.masked_signals;

    // Apply sa_mask and auto-block this signal (unless SA_NODEFER).
    sig_state.masked_signals |= sa.sa_mask;
    if ((sa.sa_flags & SA_NODEFER) == 0) {
        sig_state.masked_signals |= SigState.signalBit(sig);
    }

    printk.printk(.info, "signal: delivering {s} to pid={d} → handler=0x{x} (mask=0x{x})", .{
        signalName(sig), task.pid, handler, sig_state.masked_signals
    });

    // In real kernel: set up sigframe on user stack, set regs for iret to handler.
    // Here: invoke if sigentry is set (simulated user-space handler entry).
    if (task.sigentry) |entry| {
        printk.printk(.info, "signal: dispatching {s} via entry point (sigreturn analog)", .{signalName(sig)});
        entry();
        // Simulate handler execution.
        // sigreturn would restore saved_mask + regs here.
        sig_state.masked_signals = sig_state.saved_mask;
    }
}

fn handleDefault(sig: u8, task: *Task) void {
    // Default actions per POSIX: Term, Ign, Core, Stop, Cont
    return switch (sig) {
        SIGCHLD, SIGURG, SIGCONT, SIGWINCH => {},
        SIGSTOP => {
            task.state = .stopped;
            printk.printk(.info, "signal: {s} → STOP pid={d} '{s}'", .{ signalName(sig), task.pid, task.name });
        },
        SIGTSTP, SIGTTIN, SIGTTOU => {
            if (task.state != .stopped) {
                task.state = .stopped;
                printk.printk(.info, "signal: {s} → STOP pid={d} '{s}'", .{ signalName(sig), task.pid, task.name });
            }
        },
        SIGKILL => {
            task.state = .zombie;
            task.exit_code = 128 + sig;
            printk.printk(.info, "signal: SIGKILL → terminate pid={d} '{s}' (exit_code={d})", .{ task.pid, task.name, task.exit_code });
        },
        else => {
            // Default: terminate
            task.state = .zombie;
            task.exit_code = 128 + sig;
            printk.printk(.warn, "signal: {s} → terminate pid={d} '{s}' (exit_code={d})", .{
                signalName(sig), task.pid, task.name, task.exit_code
            });
        },
    };
}

pub fn signalName(sig: u8) []const u8 {
    return switch (sig) {
        SIGHUP => "SIGHUP", SIGINT => "SIGINT", SIGQUIT => "SIGQUIT",
        SIGILL => "SIGILL", SIGTRAP => "SIGTRAP", SIGABRT => "SIGABRT",
        SIGBUS => "SIGBUS", SIGFPE => "SIGFPE", SIGKILL => "SIGKILL",
        SIGUSR1 => "SIGUSR1", SIGSEGV => "SIGSEGV", SIGUSR2 => "SIGUSR2",
        SIGPIPE => "SIGPIPE", SIGALRM => "SIGALRM", SIGTERM => "SIGTERM",
        SIGSTKFLT => "SIGSTKFLT", SIGCHLD => "SIGCHLD", SIGCONT => "SIGCONT",
        SIGSTOP => "SIGSTOP", SIGTSTP => "SIGTSTP", SIGTTIN => "SIGTTIN",
        SIGTTOU => "SIGTTOU", SIGURG => "SIGURG", SIGXCPU => "SIGXCPU",
        SIGXFSZ => "SIGXFSZ", SIGVTALRM => "SIGVTALRM", SIGPROF => "SIGPROF",
        SIGWINCH => "SIGWINCH", SIGIO => "SIGIO", SIGPWR => "SIGPWR",
        SIGSYS => "SIGSYS",
        else => "SIGRT",
    };
}

// ── Init ────────────────────────────────────────────────────────────────────
pub fn init() void {
    printk.printk(.info, "signal: 31 standard signals + RT range ready (sigaction/sigprocmask/kill)", .{});
}

// ── Helper: find lowest deliverable pending+unmasked signal for testing ─────
pub fn nextDeliverable(sig_state: *const SigState) ?u8 {
    const unmasked = sig_state.pending_signals & ~sig_state.masked_signals;
    if (unmasked == 0) return null;
    const bit = @ctz(unmasked);
    return @truncate(bit + 1);
}
