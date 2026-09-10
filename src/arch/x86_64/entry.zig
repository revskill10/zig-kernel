// arch/x86_64 entry — syscall entry, IDT analog, _start stub
// Hosted simulation: syscall table as function-pointer array (Clean Controller boundary).
const std = @import("std");
const printk = @import("../../lib/printk.zig");
pub const gdt = @import("gdt.zig"); // M2 protected-execution policy (selectors, TSS, gates)
pub const paging64 = @import("paging.zig"); // M2 user/kernel split policy

pub const SYSCALL_MAX: usize = 450; // Linux NR parity (was 66 vinix-only) // Match vinix 66-entry table exactly

// Syscall numbers matching vinix layout
pub const NR = struct {
    pub const kprint: usize = 0;
    pub const mmap: usize = 1;
    pub const openat: usize = 2;
    pub const read: usize = 3;
    pub const write: usize = 4;
    pub const seek: usize = 5;
    pub const close: usize = 6;
    pub const set_fs_base: usize = 7;
    pub const set_gs_base: usize = 8;
    pub const ioctl: usize = 9;
    pub const fstat: usize = 10;
    pub const fstatat: usize = 11;
    pub const fcntl: usize = 12;
    pub const dup3: usize = 13;
    pub const fork: usize = 14;
    pub const exit: usize = 15;
    pub const waitpid: usize = 16;
    pub const execve: usize = 17;
    pub const chdir: usize = 18;
    pub const readdir: usize = 19;
    pub const faccessat: usize = 20;
    pub const pipe: usize = 21;
    pub const mkdirat: usize = 22;
    pub const futex_wait: usize = 23;
    pub const futex_wake: usize = 24;
    pub const getcwd: usize = 25;
    pub const kill: usize = 26;
    pub const sigentry: usize = 27;
    pub const sigprocmask: usize = 28;
    pub const sigaction: usize = 29;
    pub const sigreturn: usize = 30;
    pub const getpid: usize = 31;
    pub const getppid: usize = 32;
    pub const readlinkat: usize = 33;
    pub const munmap: usize = 34;
    pub const unlinkat: usize = 35;
    pub const ppoll: usize = 36;
    pub const rmdirat: usize = 37;
    pub const getgroups: usize = 38;
    pub const socket: usize = 39;
    pub const bind: usize = 40;
    pub const listen: usize = 41;
    pub const inotify_init: usize = 42;
    pub const mount: usize = 43;
    pub const umount: usize = 44;
    pub const signalfd: usize = 45;
    pub const socketpair: usize = 46;
    // 47 vacant (reserved)
    pub const mprotect: usize = 48;
    // 49 vacant (reserved)
    pub const clock_get: usize = 50;
    pub const gethostname: usize = 51;
    pub const sethostname: usize = 52;
    pub const nanosleep: usize = 53;
    // 54-56 vacant (reserved)
    pub const fchmod: usize = 57;
    pub const linkat: usize = 58;
    pub const connect: usize = 59;
    pub const getpeername: usize = 60;
    pub const accept: usize = 61;
    pub const recvmsg: usize = 62;
    // 63 vacant (reserved)
    // 64 vacant (reserved)
    pub const new_thread: usize = 65;
};
pub const Ring = enum { ring0, ring3 };
pub const SyscallFn = *const fn (a0: usize, a1: usize, a2: usize, a3: usize) callconv(.c) isize;

pub var syscall_table: [SYSCALL_MAX]?SyscallFn = [_]?SyscallFn{null} ** SYSCALL_MAX;
pub var syscall_names: [SYSCALL_MAX]?[]const u8 = [_]?[]const u8{null} ** SYSCALL_MAX;

pub fn registerSyscall(nr: usize, name: []const u8, func: SyscallFn) void {
    std.debug.assert(nr < SYSCALL_MAX);
    syscall_table[nr] = func;
    syscall_names[nr] = name;
    printk.printk(.debug, "entry: registered syscall {d} ({s})", .{ nr, name });
}

/// Ring3 → Ring0 transition simulation. Returns -ENOSYS if unregistered.
pub fn dispatch(nr: usize, a0: usize, a1: usize, a2: usize, a3: usize) isize {
    if (nr >= SYSCALL_MAX) return -38;
    const func = syscall_table[nr] orelse return -38;
    return func(a0, a1, a2, a3);
}

/// User-mode dispatch (M2): zk-abi-v1 allowlist first, then table.
/// Disallowed NR → -38 even if registered. Kernel path keeps raw dispatch.
pub fn dispatchUser(nr: usize, a0: usize, a1: usize, a2: usize, a3: usize) isize {
    if (!gdt.syscallAllowed(nr)) return -38;
    return dispatch(nr, a0, a1, a2, a3);
}
