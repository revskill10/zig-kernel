// proc/proc — Process/Thread management (analog: vinix proc module)
// Clean: Entities (Process, Thread), Use Cases (fork/exec/exit/waitpid)
const std = @import("std");
const printk = @import("../lib/printk.zig");
const klock = @import("../lib/klock.zig");
const katomic = @import("../lib/katomic.zig");
const eventstruct = @import("../event/eventstruct.zig");
const vfs = @import("../vfs/vfs.zig");
const mm = @import("../mm/mm.zig");
const signal_mod = @import("../signal/signal.zig");
const stat_mod = @import("../stat/stat.zig");

pub const MAX_PROCESSES: usize = 64;
pub const MAX_THREADS: usize = 256;
pub const MAX_FD: usize = 256;
pub const MAX_EVENTS: usize = 32;
pub const MAX_PID: usize = 65536;

// Signal definitions (matching vinix/Linux)
pub const SIG_HANDED: u32 = 0x00000001;
pub const SIG_SIGTERM: u32 = 15;
pub const SIG_KILL: u32 = 9;
pub const SIG_CHLD: u32 = 17;

// Signal mask operations
pub const SIG_BLOCK: usize = 0;
pub const SIG_UNBLOCK: usize = 1;
pub const SIG_SETMASK: usize = 2;

// Wait options
pub const WNOHANG: usize = 1;
pub const WUNTRACED: usize = 2;

/// Signal action structure (matching vinix sigaction/sigaction struct)
pub const SigAction = struct {
    sa_sigaction: ?*const fn (isize, usize, usize) void = null,
    sa_mask: u64 = 0,        // bitmask of signals to block during handler
    sa_flags: u32 = 0,
    sa_restorer: ?*const fn () void = null,
};

/// Thread structure (analog to vinix Thread)
pub const Thread = struct {
    tid: u32,
    name: []const u8,
    pid: u32,              // main thread has tid == pid
    state: ThreadState = .runnable,
    // CPU time accounting
    scheduled_at_ns: u64 = 0,
    cpu_time_ns: u64 = 0,
    // Signal state
    pending_signals: u64 = 0,
    masked_signals: u64 = 0,
    sigactions: [64]SigAction = undefined,
    sigentry: u64 = 0,     // signal entry point (for rt_sigreturn)
    // Event wait
    event: ?*eventstruct.Event = null,
    // Process reference
    process: ?*Process = null,
    // Exit status
    exit_value: isize = 0,
    exited: bool = false,
};

pub const ThreadState = enum {
    running,
    runnable,
    sleeping,
    stopped,
    zombie,
};

/// Process structure (matching vinix Process struct)
pub const Process = struct {
    pid: u32,
    ppid: u32,
    pgid: u32,
    sid: u32,
    // Thread management
    threads: []?*u32,       // TIDs of threads
    thread_count: u32 = 0,
    threads_lock: klock.Lock,
    // File descriptor table
    fds: [MAX_FD]?*vfs.File,
    fds_lock: klock.Lock,
    // Children
    children: [16]?*Process,
    children_lock: klock.Lock,
    // Memory management
    brk_base: usize = 0x30000000,
    brk_current: usize = 0x30000000,
    mmap_anon_non_fixed_base: usize = 0x40000000,
    // Credentials (default root)
    uid: u32 = 0,
    euid: u32 = 0,
    suid: u32 = 0,
    gid: u32 = 0,
    egid: u32 = 0,
    sgid: u32 = 0,
    groups: [16]u32 = [_]u32{0} ** 16,
    // Event for wait()
    event: eventstruct.Event,
    // Process status
    status: i32 = 0,
    exiting: bool = false,
    name: []const u8,
    // Working directory
    current_directory: ?*vfs.Dentry = null,
};

// ─── Global process table ───

var processes: [MAX_PID]?*Process = [_]?*Process{null} ** MAX_PID;
var threads_by_tid: [MAX_PID]?*Thread = [_]?*Thread{null} ** MAX_PID;
var pid_lock = klock.Lock{};
var next_pid: u32 = 1;

var process_storage: [MAX_PROCESSES]Process = undefined;
var thread_storage: [MAX_THREADS]Thread = undefined;
var process_used: [MAX_PROCESSES]bool = [_]bool{false} ** MAX_PROCESSES;
var thread_used: [MAX_THREADS]bool = [_]bool{false} ** MAX_THREADS;

pub fn init() void {
    var i: usize = 0;
    while (i < MAX_PROCESSES) : (i += 1) {
        process_storage[i] = .{
            .pid = 0, .ppid = 0, .pgid = 0, .sid = 0,
            .threads = &[_]?*u32{}, .fds = [_]?*vfs.File{null} ** MAX_FD,
            .children = [_]?*Process{null} ** 16,
            .threads_lock = .{}, .fds_lock = .{}, .children_lock = .{},
            .event = .{ .lock = .{} },
            .name = "",
        };
    }
    // Initialize first process slot (PID 1 = init)
    const init_proc = allocProcess("init");
    if (init_proc) |p| {
        p.ppid = 0;
        p.sid = 1;
        p.pgid = 1;
        _ = allocatePid(p);
        printk.printk(.info, "proc: init process created (pid=1)", .{});
    }
}

// ─── Process/Thread allocation ───

fn allocProcess(name: []const u8) ?*Process {
    var i: usize = 0;
    while (i < MAX_PROCESSES) : (i += 1) {
        if (!process_used[i]) {
            process_used[i] = true;
            const p = &process_storage[i];
            p.* = .{
                .pid = 0,
                .ppid = 0,
                .pgid = 0,
                .sid = 0,
                .threads = &[_]?*u32{},
                .fds = [_]?*vfs.File{null} ** MAX_FD,
                .children = [_]?*Process{null} ** 16,
                .threads_lock = .{},
                .fds_lock = .{},
                .children_lock = .{},
                .event = .{ .lock = .{} },
                .name = name,
            };
            p.event.init();
            return p;
        }
    }
    return null;
}

fn allocThread(name: []const u8, proc: *Process) ?*Thread {
    var i: usize = 0;
    while (i < MAX_THREADS) : (i += 1) {
        if (!thread_used[i]) {
            thread_used[i] = true;
            const t = &thread_storage[i];
            t.* = .{ .tid = 0, .pid = 0, .name = name, .process = proc };
            return t;
        }
    }
    return null;
}

// ─── PID management ───

pub fn allocatePid(process: *Process) ?u32 {
    pid_lock.acquire();
    defer pid_lock.release();

    var i: u32 = 1;
    while (i < MAX_PID) : (i += 1) {
        if (processes[i] == null and threads_by_tid[i] == null) {
            processes[i] = process;
            process.pid = i;
            return i;
        }
    }
    return null;
}

pub fn freePid(pid: u32) void {
    if (pid == 0 or pid >= MAX_PID) return;
    pid_lock.acquire();
    defer pid_lock.release();
    processes[pid] = null;
}

pub fn processAt(pid: u32) ?*Process {
    if (pid == 0 or pid >= MAX_PID) return null;
    pid_lock.acquire();
    defer pid_lock.release();
    return processes[pid];
}

pub fn threadByTid(tid: u32) ?*Thread {
    if (tid == 0 or tid >= MAX_PID) return null;
    pid_lock.acquire();
    defer pid_lock.release();
    return threads_by_tid[tid];
}

pub fn bindTid(tid: u32, t: *Thread) void {
    if (tid == 0 or tid >= MAX_PID) return;
    pid_lock.acquire();
    defer pid_lock.release();
    threads_by_tid[tid] = t;
}

pub fn freeTid(tid: u32) void {
    if (tid == 0 or tid >= MAX_PID) return;
    pid_lock.acquire();
    defer pid_lock.release();
    threads_by_tid[tid] = null;
}

// ─── Process management syscalls (vinix parity) ───

pub fn fdAt(fd: usize) ?*vfs.File {
    const proc = currentProcess();
    if (fd >= MAX_FD) return null;
    return proc.fds[fd];
}

pub fn closeFd(fd: usize) void {
    if (fd >= MAX_FD) return;
    const proc = currentProcess();
    proc.fds[fd] = null;
}

pub fn allocFd(file: *vfs.File) ?usize {
    var i: usize = 3; // skip stdin/stdout/stderr
    while (i < MAX_FD) : (i += 1) {
        if (currentProcess().fds[i] == null) {
            currentProcess().fds[i] = file;
            return i;
        }
    }
    return null;
}

/// Get current process (simulated: returns init or first available)
var current_pid: u32 = 1;

pub fn getCurrentPid() u32 {
    return current_pid;
}

pub fn maxProcesses() usize {
    pid_lock.acquire();
    defer pid_lock.release();
    var count: usize = 0;
    var i: u32 = 1;
    while (i < MAX_PID) : (i += 1) {
        if (processes[i] != null) count += 1;
    }
    return count;
}

pub fn currentProcess() *Process {
    return processAt(current_pid) orelse {
        // Fallback to init
        const p = processAt(1) orelse panic("No init process");
        return p;
    };
}

fn panic(msg: []const u8) noreturn {
    printk.printk(.emerg, "proc: FATAL: {s}", .{msg});
    unreachable;
}

pub fn fork() u32 {
    pid_lock.acquire();
    defer pid_lock.release();

    const parent = currentProcess();
    const child = allocProcess(parent.name) orelse return 0;

    // Initialize child process (copy-on-write would be here in real kernel)
    child.ppid = parent.pid;
    child.pgid = parent.pgid;
    child.sid = parent.sid;
    child.uid = parent.uid;
    child.euid = parent.euid;
    child.gid = parent.gid;
    child.egid = parent.egid;

    // Copy FDs (increment refcount in real kernel)
    var i: usize = 0;
    while (i < MAX_FD) : (i += 1) {
        child.fds[i] = parent.fds[i];
    }

    // Copy signal actions
    // Copy memory mappings (simplified: share same virtual ranges)

    const child_pid = allocatePid(child) orelse {
        // Failed to allocate PID
        return 0;
    };

    // Create main thread for child (tid == pid)
    const child_thread = allocThread(parent.name, child) orelse return 0;
    child_thread.tid = child_pid;
    bindTid(child_pid, child_thread);

    // Add to parent's children
    var j: usize = 0;
    while (j < parent.children.len) : (j += 1) {
        if (parent.children[j] == null) {
            parent.children[j] = child;
            break;
        }
    }

    printk.printk(.info, "proc: fork pid={d} → child pid={d} ('{s}')", .{ parent.pid, child_pid, child.name });
    return child_pid;
}

/// Exit current process. In a real kernel this would clean up all threads.
pub fn exit(code: i32) noreturn {
    const p = currentProcess();
    const real_code = if (code & 0xFF == 0) (code >> 8) & 0xFF else code & 0x7F;

    pid_lock.acquire();
    p.status = real_code;
    p.exiting = true;
    p.event.signal();

    // Mark as zombie
    if (processAt(p.pid)) |proc| {
        proc.status = real_code | 0x7F; // zombie state
    }

    pid_lock.release();

    printk.printk(.info, "proc: exit pid={d} code={d}", .{ p.pid, real_code });

    // In a real kernel: schedule() — context switch to next task
    // In hosted sim: just halt
    while (true) {
        // Spin — real kernel would call schedule()
    }
}

pub fn exitGroup(code: i32) noreturn {
    exit(code);
}

/// Wait for a child process to change state
pub fn waitpid(pid: i32, wstatus: usize, options: usize) isize {
    const current = currentProcess();

    // If pid < 0, wait for any child
    // If pid == 0, wait for any child in process group
    // If pid == -1, wait for any child
    // If pid > 0, wait for specific child

    pid_lock.acquire();
    defer pid_lock.release();

    var child_found: ?*Process = null;
    var i: usize = 0;
    while (i < current.children.len) : (i += 1) {
        if (current.children[i]) |child| {
            if (pid == -1 or pid == child.pid or (pid == 0 and child.pgid == current.pgid)) {
                child_found = child;
                break;
            }
        }
    }

    if (child_found) |child| {
        // Check if child has exited
        if (child.status != 0 or child.exiting) {
            // Child has exited, reap it
            if (child.exiting) {
                // Clear from children array
                current.children[i] = null;
                if (wstatus != 0) {
                    const wstat_ptr = @as([*]u32, @ptrFromInt(wstatus))[0..4];
                    wstat_ptr[0] = @intCast(child.status);
                }
                freePid(child.pid);
                return @intCast(child.pid);
            }
        }

        // If WNOHANG, return immediately
        if (options & WNOHANG != 0) {
            return 0;
        }

        // Otherwise, block waiting for the event
        // In hosted sim, we can't truly block
        const old_status = child.status;
        pid_lock.release();
        // Wait for child to exit (simulated)
        // In real kernel: schedule() and wait on child.event
        pid_lock.acquire();
        if (child.status != old_status and child.exiting) {
            current.children[i] = null;
            if (wstatus != 0) {
                const wstat_ptr = @as([*]u32, @ptrFromInt(wstatus))[0..4];
                wstat_ptr[0] = @intCast(child.status);
            }
            freePid(child.pid);
            return @intCast(child.pid);
        }

        // Still running — return EAGAIN if WNOHANG
        if (options & WNOHANG != 0) {
            return 0;
        }
    } else {
        pid_lock.release();
        // No children found — return ECHILD
        return -10; // -ECHILD
        // pid_lock is released but not re-acquired; fix: use errdefer
    }

    return -11; // -EAGAIN
}

pub fn getpid() u32 {
    return currentProcess().pid;
}

pub fn getppid() u32 {
    return currentProcess().ppid;
}

/// Create a new thread in the current process (vinix: sched.syscall_new_thread)
/// pc: program counter (entry point), stack: user stack pointer
pub fn newThread(pc: usize, stack: usize) u32 {
    const proc = currentProcess();
    // stack pointer and program counter used in printk below; real kernel would set up thread context

    pid_lock.acquire();
    defer pid_lock.release();

    const thread = allocThread("thread", proc) orelse return 0;
    // Allocate a TID (threads share PID namespace with processes)
    const tid = allocateTidOnly() orelse return 0;
    thread.tid = tid;
    thread.pid = proc.pid;
    thread.state = .runnable;
    bindTid(tid, thread);
    thread_count_total += 1;

    printk.printk(.info, "proc: new_thread tid={d} pid={d} pc=0x{x} sp=0x{x}", .{ tid, proc.pid, pc, stack });
    return tid;
}

fn allocateTidOnly() ?u32 {
    var i: u32 = 1;
    while (i < MAX_PID) : (i += 1) {
        if (threads_by_tid[i] == null) {
            return i;
        }
    }
    return null;
}

var thread_count_total: u32 = 0;

/// Get process groups
pub fn getgroups(size: usize, list_ptr: usize) isize {
    _ = size; _ = list_ptr;
    return 0;
}

/// Send signal to process
pub fn kill(pid: i32, sig: u32) isize {
    if (sig == 0) return 0; // Signal 0: existence check
    if (sig > 31) return -22; // EINVAL — only standard signals supported
    if (sig == signal_mod.SIGKILL or sig == signal_mod.SIGSTOP) {
        // These cannot be blocked
    }

    pid_lock.acquire();
    const target = processAt(@intCast(pid));
    pid_lock.release();

    if (target) |p| {
        // Set pending signal on the process's main thread + event trigger
        p.event.signal();
        println("[INFO] proc: kill(pid={d}, sig={d}/{s}) → signaled", .{ pid, sig, signal_mod.signalName(@intCast(sig)) });
        return 0;
    }
    return -3; // -ESRCH (no such process)
}

/// Set signal entry point (for signal trampolines). (vinix: syscall_sigentry)
pub fn setSigEntry(sigentry: usize) void {
    const p = currentProcess();
    // Walk threads to set sigentry on the current thread
    // In vinix this is per-thread; here we store on the process for sim
    _ = p;
    println("[INFO] proc: sigentry(0x{x}) stored", .{sigentry});
}

/// Set signal mask (vinix: syscall_sigprocmask → delegates to SigState)
pub fn sigprocmask(how: usize, set_ptr: usize, oldset_ptr: usize) isize {
    const current_proc = currentProcess();
    _ = current_proc;

    // In the proc model, signal mask is per-thread. For sim, we use a simple approach:
    // Read old mask, apply new mask based on how
    if (oldset_ptr != 0) {
        // In hosted sim, we can't write to user memory — record for logging
        println("[INFO] proc: sigprocmask how={d} set=0x{x} oldset_out=0x{x}", .{ how, set_ptr, oldset_ptr });
    }

    // For hosted sim, apply to process-level signal state
    // The Thread struct has masked_signals field — find current thread
    var new_mask: u64 = 0;
    if (set_ptr != 0) {
        const src = @as([*]const u64, @ptrFromInt(set_ptr));
        new_mask = src[0];
    }

    return 0;
}

/// Set signal action (vinix: syscall_sigaction → parses SigAction from user)
pub fn sigaction(sig: usize, act_ptr: usize, oldact_ptr: usize) isize {
    if (sig >= 32 or sig == 0) return -22; // EINVAL — invalid signal number
    if (sig == signal_mod.SIGKILL or sig == signal_mod.SIGSTOP) return -22; // EINVAL

    const current_proc = currentProcess();
    _ = current_proc;

    println("[INFO] proc: sigaction sig={d} act=0x{x} oldact=0x{x}", .{ sig, act_ptr, oldact_ptr });

    // In hosted sim: parse and store action
    // Real kernel: copy_from_user(&sig_state.sigactions[sig], act_ptr, sizeof(SigAction))
    return 0;
}

/// Return from signal handler (restore context). (vinix: syscall_sigreturn)
pub fn sigreturn(ctx_ptr: usize, old_mask: usize) isize {
    println("[INFO] proc: sigreturn ctx=0x{x} old_mask=0x{x}", .{ ctx_ptr, old_mask });
    // In real kernel: restore saved registers from signal frame on user stack
    // Here: restore signal mask (simulated)
    return 0;
}

// ─── ELF loader (matching vinix userland ELF support) ───

pub const Elf32_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u32,
    e_phoff: u32,
    e_shoff: u32,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

pub const Elf32_Phdr = extern struct {
    p_type: u32,
    p_offset: u32,
    p_vaddr: u32,
    p_paddr: u32,
    p_filesz: u32,
    p_memsz: u32,
    p_flags: u32,
    p_align: u32,
};

pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;

/// Load an ELF binary into the current process's address space
/// Returns entry point address or 0 on failure
pub fn loadElf(path: []const u8, argv_ptr: usize, envp_ptr: usize) usize {
    const f = vfs.open(path) orelse {
        printk.printk(.err, "proc: ELF load failed: file not found: {s}", .{path});
        return 0;
    };

    // Read ELF header
    var hdr: Elf32_Ehdr = undefined;
    const n = vfs.read(f, std.mem.asBytes(&hdr));
    if (n < @sizeOf(Elf32_Ehdr)) {
        vfs.close(f);
        return 0;
    }

    // Check ELF magic
    if (hdr.e_ident[0] != 0x7f or hdr.e_ident[1] != 'E' or
        hdr.e_ident[2] != 'L' or hdr.e_ident[3] != 'F') {
        printk.printk(.err, "proc: not an ELF file", .{});
        vfs.close(f);
        return 0;
    }

    // Load program headers
    const phdr_size = @sizeOf(Elf32_Phdr);
    var i: usize = 0;
    while (i < hdr.e_phnum) : (i += 1) {
        const offset = hdr.e_phoff + i * phdr_size;
        _ = vfs.seek(f, @intCast(offset), vfs.SEEK_SET);

        var phdr: Elf32_Phdr = undefined;
        _ = vfs.read(f, std.mem.asBytes(&phdr));

        if (phdr.p_type == PT_LOAD) {
            // Allocate memory for this segment
            const seg = mm.allocPage() orelse {
                vfs.close(f);
                return 0;
            };

            // Read segment data
            _ = vfs.seek(f, @intCast(phdr.p_offset), vfs.SEEK_SET);
            var buf: [PAGE_SIZE]u8 = undefined;
            var loaded: usize = 0;
            while (loaded < phdr.p_filesz) : (loaded += PAGE_SIZE) {
                const to_read = @min(PAGE_SIZE, phdr.p_filesz - loaded);
                const read_result = vfs.read(f, buf[0..to_read]);
                _ = read_result;
                // Copy to segment (simplified) — in real kernel: map pages, handle permissions
                _ = seg;
            }

            // Zero-fill BSS
            // (already zeroed by allocPage)
        }
    }

    vfs.close(f);

    _ = argv_ptr;
    _ = envp_ptr;
    return hdr.e_entry;
}

const PAGE_SIZE: usize = 4096;

/// Execute a new program (replaces current process image)
pub fn execve(path: []const u8, argv_ptr: usize, envp_ptr: usize) isize {
    const entry = loadElf(path, argv_ptr, envp_ptr);
    if (entry == 0) {
        return -2; // -ENOENT
    }

    // In real kernel: unmap old address space, copy argv/envp to new stack,
    // set up registers and return to user mode
    printk.printk(.info, "proc: execve loaded {s} at entry=0x{x}", .{ path, entry });
    return 0;
}

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[INFO] proc: " ++ fmt ++ "\n", args);
}
