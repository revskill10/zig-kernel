// IDT 256 entries + 0x80 DPL3 trap gate + #PF(14) DPL0 interrupt gate. Parity with arch/x86_64/entry.zig (66 entries).
const paging = @import("paging.zig");

var idt: [256]IDTEntry align(8) = [_]IDTEntry{.{ .offset_low = 0, .selector = 0, .zero = 0, .type_attr = 0, .offset_high = 0 }} ** 256;
var idt_desc: IDTDescriptor align(4) = undefined;

pub const IDTEntry = packed struct { offset_low: u16, selector: u16, zero: u8 = 0, type_attr: u8, offset_high: u16 };
pub const IDTDescriptor = packed struct { limit: u16, base: u32 };
pub inline fn cli() void { asm volatile ("cli" ::: .{ .memory = true }); }
pub inline fn sti() void { asm volatile ("sti" ::: .{ .memory = true }); }

// pf stats (mirrors paging.pf_handled but counted at entry)
pub var pf_hit_count: usize = 0;
pub var pf_last_addr: u32 = 0;
pub var pf_last_err: u32 = 0;

// --- syscall table parity (mirrors entry.zig) ---
pub const SYSCALL_MAX: usize = 66;
pub const NR = struct {
    pub const kprint: usize = 0; pub const mmap: usize = 1; pub const openat: usize = 2; pub const read: usize = 3;
    pub const write: usize = 4; pub const seek: usize = 5; pub const close: usize = 6; pub const set_fs_base: usize = 7;
    pub const set_gs_base: usize = 8; pub const ioctl: usize = 9; pub const fstat: usize = 10; pub const fstatat: usize = 11;
    pub const fcntl: usize = 12; pub const dup3: usize = 13; pub const fork: usize = 14; pub const exit: usize = 15;
    pub const waitpid: usize = 16; pub const execve: usize = 17; pub const chdir: usize = 18; pub const readdir: usize = 19;
    pub const faccessat: usize = 20; pub const pipe: usize = 21; pub const mkdirat: usize = 22; pub const futex_wait: usize = 23;
    pub const futex_wake: usize = 24; pub const getcwd: usize = 25; pub const kill: usize = 26; pub const sigentry: usize = 27;
    pub const sigprocmask: usize = 28; pub const sigaction: usize = 29; pub const sigreturn: usize = 30; pub const getpid: usize = 31;
    pub const getppid: usize = 32; pub const readlinkat: usize = 33; pub const munmap: usize = 34; pub const unlinkat: usize = 35;
    pub const ppoll: usize = 36; pub const rmdirat: usize = 37; pub const getgroups: usize = 38; pub const socket: usize = 39;
    pub const bind: usize = 40; pub const listen: usize = 41; pub const inotify_init: usize = 42; pub const mount: usize = 43;
    pub const umount: usize = 44; pub const signalfd: usize = 45; pub const socketpair: usize = 46; pub const mprotect: usize = 48;
    pub const clock_get: usize = 50; pub const gethostname: usize = 51; pub const sethostname: usize = 52; pub const nanosleep: usize = 53;
    pub const fchmod: usize = 57; pub const linkat: usize = 58; pub const connect: usize = 59; pub const getpeername: usize = 60;
    pub const accept: usize = 61; pub const recvmsg: usize = 62; pub const new_thread: usize = 65;
};
pub const SyscallFn = *const fn (a0: usize, a1: usize, a2: usize, a3: usize) callconv(.c) isize;
pub var syscall_table: [SYSCALL_MAX]?SyscallFn = [_]?SyscallFn{null} ** SYSCALL_MAX;
pub var syscall_names: [SYSCALL_MAX]?[]const u8 = [_]?[]const u8{null} ** SYSCALL_MAX;
pub fn registerSyscall(nr: usize, name: []const u8, func: SyscallFn) void {
    if (nr >= SYSCALL_MAX) return;
    syscall_table[nr] = func;
    syscall_names[nr] = name;
}
pub fn dispatch(nr: usize, a0: usize, a1: usize, a2: usize, a3: usize) isize {
    if (nr >= SYSCALL_MAX) return -38;
    const f = syscall_table[nr] orelse return -38;
    return f(a0, a1, a2, a3);
}

// Trap frame after pusha + push esp. pusha order: EAX,ECX,EDX,EBX,ESP,EBP,ESI,EDI -> memory low=EDI.
pub const TrapFrame = extern struct {
    edi: u32, esi: u32, ebp: u32, esp_orig: u32, ebx: u32, edx: u32, ecx: u32, eax: u32,
    eip: u32, cs: u32, eflags: u32,
};

fn setGate(vec: u8, handler: usize, dpl: u2) void {
    const attr: u8 = 0x80 | (@as(u8, dpl) << 5) | 0x0F;
    idt[vec] = .{ .offset_low = @intCast(handler & 0xFFFF), .selector = 0x08, .type_attr = attr, .offset_high = @intCast((handler >> 16) & 0xFFFF) };
}

fn setInterruptGate(vec: u8, handler: usize) void {
    // P=1, DPL=00, 0, type=1110 (32-bit interrupt gate) => 0x8E. Clears IF on entry.
    const attr: u8 = 0x8E;
    idt[vec] = .{ .offset_low = @intCast(handler & 0xFFFF), .selector = 0x08, .type_attr = attr, .offset_high = @intCast((handler >> 16) & 0xFFFF) };
}

export fn syscall_entry() callconv(.naked) void {
    asm volatile (
        \\pusha
        \\push %esp
        \\call syscall_dispatch
        \\add $4, %esp
        \\popa
        \\iret
        ::: .{ .memory = true }
    );
}

export fn syscall_dispatch(frame: *TrapFrame) callconv(.c) void {
    const nr: usize = @intCast(frame.eax);
    const a0: usize = @intCast(frame.ebx);
    const a1: usize = @intCast(frame.ecx);
    const a2: usize = @intCast(frame.edx);
    const a3: usize = @intCast(frame.esi);
    const ret = dispatch(nr, a0, a1, a2, a3);
    frame.eax = @bitCast(@as(i32, @intCast(ret)));
}

// --- #PF(14) page fault ---
export fn pf_entry() callconv(.naked) void {
    asm volatile (
        \\pusha
        \\mov %cr2, %eax
        \\mov 32(%esp), %ebx
        \\push %ebx
        \\push %eax
        \\call pf_dispatch
        \\add $8, %esp
        \\popa
        \\add $4, %esp
        \\iret
        ::: .{ .memory = true }
    );
}

pub export fn pf_dispatch(fault_addr: u32, error_code: u32) callconv(.c) void {
    pf_hit_count += 1;
    pf_last_addr = fault_addr;
    pf_last_err = error_code;
    _ = paging.handle_mm_fault(fault_addr, error_code);
}

pub fn idt_init() void {
    cli();
    setGate(0x80, @intFromPtr(&syscall_entry), 3);
    setInterruptGate(14, @intFromPtr(&pf_entry));
    idt_desc = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt[0]) };
    asm volatile ("lidt (%[p])" : : [p] "r" (&idt_desc) : .{ .memory = true });
}

// helpers for baremetal introspection
pub fn isPfPresent() bool {
    return (idt[14].type_attr & 0x80) != 0;
}
pub fn pfGateAttr() u8 { return idt[14].type_attr; }
