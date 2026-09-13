// arch/x86_64/native/idt — real IDT, exception/trap dispatch, PIC + PIT.
// N2 descriptor layout is preserved. N6: one-shot site-bound recovery,
// per-entry FXSAVE64/FXRSTOR64 (non-AVX), CLD+SysV dispatch, atomic
// publication. Trap stubs/N6 continuation no longer IRET to Zig functions.

const serial = @import("serial");
const gdt = @import("gdt");
const std = @import("std");
/// Naked probe helpers; sibling file import so main needs no extra named module.
pub const probes = @import("probes.zig");

/// Register/interrupt frame built by the stubs (lowest address first).
pub const TrapFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

comptime {
    if (@sizeOf(TrapFrame) != 176) @compileError("TrapFrame must be 176 bytes");
    if (@offsetOf(TrapFrame, "r15") != 0 or @offsetOf(TrapFrame, "r14") != 8 or
        @offsetOf(TrapFrame, "r13") != 16 or @offsetOf(TrapFrame, "r12") != 24 or
        @offsetOf(TrapFrame, "r11") != 32 or @offsetOf(TrapFrame, "r10") != 40 or
        @offsetOf(TrapFrame, "r9") != 48 or @offsetOf(TrapFrame, "r8") != 56 or
        @offsetOf(TrapFrame, "rbp") != 64 or @offsetOf(TrapFrame, "rdi") != 72 or
        @offsetOf(TrapFrame, "rsi") != 80 or @offsetOf(TrapFrame, "rdx") != 88 or
        @offsetOf(TrapFrame, "rcx") != 96 or @offsetOf(TrapFrame, "rbx") != 104 or
        @offsetOf(TrapFrame, "rax") != 112)
        @compileError("TrapFrame GPR offset mismatch");
    if (@offsetOf(TrapFrame, "vector") != 120 or
        @offsetOf(TrapFrame, "error_code") != 128 or
        @offsetOf(TrapFrame, "rip") != 136 or
        @offsetOf(TrapFrame, "cs") != 144 or
        @offsetOf(TrapFrame, "rflags") != 152 or
        @offsetOf(TrapFrame, "rsp") != 160 or
        @offsetOf(TrapFrame, "ss") != 168)
        @compileError("TrapFrame vector/IRET offset mismatch");
}

pub const IdtEntry = packed struct {
    offset_lo: u16,
    selector: u16,
    ist: u3,
    _zero0: u5 = 0,
    type_attr: u8,
    offset_mid: u16,
    offset_hi: u32,
    _zero1: u32 = 0,
};
pub const IdtEntryTest = IdtEntry;

pub const IdtPointer = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};
pub const IdtPointerTest = IdtPointer;

comptime {
    if (@bitSizeOf(IdtEntry) != 128 or @sizeOf(IdtEntry) != 16)
        @compileError("IDT gate must be 128 bits, 16-byte stride");
    if (@bitOffsetOf(IdtEntry, "selector") != 16 or
        @bitOffsetOf(IdtEntry, "ist") != 32 or
        @bitOffsetOf(IdtEntry, "type_attr") != 40 or
        @bitOffsetOf(IdtEntry, "offset_mid") != 48 or
        @bitOffsetOf(IdtEntry, "offset_hi") != 64 or
        @bitOffsetOf(IdtEntry, "_zero1") != 96)
        @compileError("IDT gate field bit layout mismatch");
    if (@sizeOf(IdtPointer) != 10 or @alignOf(IdtPointer) != 1 or
        @offsetOf(IdtPointer, "limit") != 0 or
        @offsetOf(IdtPointer, "base") != 2)
        @compileError("IDTR operand must be 10 bytes (limit@0, base@2)");
}

pub const TRAP_GATE: u8 = 0x8F;
pub const INT_GATE: u8 = 0x8E;
pub const IDT_LEN: usize = 256;
pub const IDT_LIMIT: u16 = @intCast(@sizeOf(IdtEntry) * IDT_LEN - 1);

pub const PFEC_MASK: u64 = 0x1F; // architectural P|W/R|U/S|RSVD|I/D; bits 5+ are rejected
pub const ERR_UD2: u64 = 0;
pub const ERR_PF_NOTPRESENT_READ: u64 = 0;
pub const ERR_PF_RO_WRITE: u64 = 0x3; // P=1 W=1 supervisor data
pub const ERR_PF_NX_FETCH: u64 = 0x11; // P=1 I/D=1

/// Production 128-bit gate encoder used by init/setGate.
pub fn encodeGate(handler: u64, selector: u16, ist: u3, type_attr: u8) IdtEntry {
    return .{
        .offset_lo = @truncate(handler),
        .selector = selector,
        .ist = ist,
        .type_attr = type_attr,
        .offset_mid = @truncate(handler >> 16),
        .offset_hi = @truncate(handler >> 32),
    };
}

pub fn gateHandler(entry: IdtEntry) u64 {
    return @as(u64, entry.offset_lo) |
        (@as(u64, entry.offset_mid) << 16) |
        (@as(u64, entry.offset_hi) << 32);
}

comptime {
    if (IDT_LIMIT != 4095)
        @compileError("IDT limit must be 256*16-1 = 4095");
    const sample_handler: u64 = 0x0102030405060708;
    const sample = encodeGate(sample_handler, gdt.KERNEL_CODE_SEL, 1, TRAP_GATE);
    if (gateHandler(sample) != sample_handler)
        @compileError("IDT handler reconstruction mismatch");
    if (sample.selector != gdt.KERNEL_CODE_SEL or sample.ist != 1 or
        sample.type_attr != TRAP_GATE or sample._zero0 != 0 or sample._zero1 != 0)
        @compileError("IDT gate field/reserved mismatch");
    if (sample.offset_lo != 0x0708 or sample.offset_mid != 0x0506 or
        sample.offset_hi != 0x01020304)
        @compileError("IDT offset fragment split mismatch");
}

pub const VEC_UD: u8 = 6;
pub const VEC_DF: u8 = 8;
pub const VEC_GP: u8 = 13;
pub const VEC_PF: u8 = 14;
pub const VEC_MC: u8 = 18;
pub const VEC_IRQ0: u8 = 32;

var idt: [256]IdtEntry align(16) = [_]IdtEntry{std.mem.zeroes(IdtEntry)} ** 256;

pub const ObservedTrap = struct {
    vector: u8 = 0xFF,
    error_code: u64 = 0,
    rip: u64 = 0,
    cr2: u64 = 0,
    generation: u64 = 0,
};

pub const Expect = struct {
    vector: u8,
    fault_rip: u64,
    resume_rip: u64,
    cr2: u64 = 0,
    match_cr2: bool = false,
    error_code: u64 = 0,
};

const Armed = struct {
    active: std.atomic.Value(u8) = .init(0),
    vector: u8 = 0,
    fault_rip: u64 = 0,
    resume_rip: u64 = 0,
    cr2: u64 = 0,
    match_cr2: bool = false,
    error_code: u64 = 0,
    generation: u64 = 0,
};

/// Skip FXRSTOR after dispatch (restore-failure negative profile only).
export var zk_skip_fxrstor: u8 = 0;

var armed: Armed = .{};
var last_obs: ObservedTrap = .{};
var last_valid: std.atomic.Value(u8) = .init(0);
var generation: std.atomic.Value(u64) = .init(0);
var timer_ticks: std.atomic.Value(u64) = .init(0);

pub fn timerTicks() u64 {
    return timer_ticks.load(.monotonic);
}

pub fn timerTicksAddr() u64 {
    return @intFromPtr(&timer_ticks.raw);
}

/// Exact error equality for this CPL0/qemu64 profile. Unsupported PFEC high
/// bits (e.g. 0x23 vs RO 0x3) do not match.
pub fn eventMatches(
    is_armed: bool,
    exp_vec: u8,
    exp_rip: u64,
    match_cr2: bool,
    exp_cr2: u64,
    exp_err: u64,
    vec: u8,
    rip: u64,
    cr2: u64,
    err: u64,
) bool {
    if (!is_armed) return false;
    if (vec != exp_vec) return false;
    if (rip != exp_rip) return false;
    if (match_cr2 and cr2 != exp_cr2) return false;
    if (err != exp_err) return false;
    return true;
}

/// IF must be 0. Clears the prior record, installs a one-shot expectation, returns generation.
pub fn arm(expect: Expect) u64 {
    last_valid.store(0, .release);
    const gen = generation.fetchAdd(1, .monotonic) + 1;
    armed.vector = expect.vector;
    armed.fault_rip = expect.fault_rip;
    armed.resume_rip = expect.resume_rip;
    armed.cr2 = expect.cr2;
    armed.match_cr2 = expect.match_cr2;
    armed.error_code = expect.error_code;
    armed.generation = gen;
    armed.active.store(1, .release);
    return gen;
}

pub fn disarm() void {
    armed.active.store(0, .release);
}

pub fn takeRecord() ?ObservedTrap {
    if (last_valid.load(.acquire) != 1) return null;
    const rec = last_obs;
    last_valid.store(0, .release);
    return rec;
}

fn setGate(vec: u8, handler: u64, ist: u3, gate: u8) void {
    idt[vec] = encodeGate(handler, gdt.KERNEL_CODE_SEL, ist, gate);
}

inline fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn hang() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

fn cpuid1() struct { ecx: u32, edx: u32 } {
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\ movl $1, %%eax
        \\ cpuid
        : [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        :
        : .{ .rax = true, .rbx = true }
    );
    return .{ .ecx = ecx, .edx = edx };
}

fn xcr0() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile (
        \\ xorl %%ecx, %%ecx
        \\ xgetbv
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .rcx = true }
    );
    return (@as(u64, hi) << 32) | lo;
}

fn enableFxsave() void {
    const ids = cpuid1();
    const fxsr = (ids.edx & (1 << 24)) != 0;
    const sse = (ids.edx & (1 << 25)) != 0;
    if (!fxsr or !sse) {
        serial.print("\nZKN: FAULT fxsave-cpuid fxsr={d} sse={d}\n", .{
            @intFromBool(fxsr), @intFromBool(sse),
        });
        hang();
    }
    const osxsave = (ids.ecx & (1 << 27)) != 0;
    if (osxsave) {
        const xc = xcr0();
        if ((xc & ~@as(u64, 0x3)) != 0) {
            serial.print("\nZKN: FAULT fxsave-profile unsupported xcr0={x}\n", .{xc});
            hang();
        }
    }
    asm volatile (
        \\ movq %%cr0, %%rax
        \\ andq $0xFFFFFFFFFFFFFFF3, %%rax
        \\ orq $0x22, %%rax
        \\ movq %%rax, %%cr0
        \\ movq %%cr4, %%rax
        \\ orq $0x600, %%rax
        \\ movq %%rax, %%cr4
        \\ fninit
        :
        :
        : .{ .rax = true, .memory = true }
    );
}

fn rflags() u64 {
    return asm volatile (
        \\ pushfq
        \\ popq %[r]
        : [r] "=r" (-> u64),
    );
}

fn restoreFailProfile() bool {
    const root = @import("root");
    return @hasDecl(root, "ZK_N6_RESTORE_FAIL") and root.ZK_N6_RESTORE_FAIL;
}

/// SysV dispatcher called by the naked common stub (rdi = TrapFrame).
export fn zkTrapDispatch(frame: *TrapFrame) callconv(.{ .x86_64_sysv = .{} }) void {
    if ((rflags() & 0x400) != 0) {
        serial.print("\nZKN: FAULT dispatcher DF set\n", .{});
        hang();
    }
    const vec: u8 = @intCast(frame.vector);
    if (vec == VEC_IRQ0) {
        _ = timer_ticks.fetchAdd(1, .monotonic);
        picEoi(0);
        return;
    }
    const cr2: u64 = if (vec == VEC_PF) readCr2() else 0;
    const is_armed = armed.active.load(.acquire) == 1;
    if (eventMatches(
        is_armed,
        armed.vector,
        armed.fault_rip,
        armed.match_cr2,
        armed.cr2,
        armed.error_code,
        vec,
        frame.rip,
        cr2,
        frame.error_code,
    )) {
        last_obs = .{
            .vector = vec,
            .error_code = frame.error_code,
            .rip = frame.rip,
            .cr2 = cr2,
            .generation = armed.generation,
        };
        last_valid.store(1, .release);
        armed.active.store(0, .release);
        frame.rip = armed.resume_rip;
        return;
    }
    if (vec == VEC_DF) {
        serial.print("\nZKN: FAULT double-fault code={x} rip={x:0>16}\n", .{
            frame.error_code, frame.rip,
        });
        hang();
    }
    serial.print("\nZKN: FAULT uncontrolled vector={d} code={x} rip={x:0>16} cr2={x:0>16}\n", .{
        vec, frame.error_code, frame.rip, cr2,
    });
    hang();
}

/// Common stub: 15 GPRs, CLI, CLD, per-entry FXSAVE64, SysV CALL, FXRSTOR64, IRETQ.
export fn zkTrapCommon() callconv(.naked) void {
    asm volatile (
        \\ pushq %%rax
        \\ pushq %%rbx
        \\ pushq %%rcx
        \\ pushq %%rdx
        \\ pushq %%rsi
        \\ pushq %%rdi
        \\ pushq %%rbp
        \\ pushq %%r8
        \\ pushq %%r9
        \\ pushq %%r10
        \\ pushq %%r11
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15
        \\ cli
        \\ cld
        \\ movq %%rsp, %%rdi
        \\ movq %%rsp, %%rbx
        \\ andq $-16, %%rsp
        \\ subq $512, %%rsp
        \\ fxsave64 (%%rsp)
        \\ call zkTrapDispatch
        \\ subq $16, %%rsp
        \\ pcmpeqd %%xmm0, %%xmm0
        \\ movdqa %%xmm0, %%xmm1
        \\ movdqa %%xmm0, %%xmm2
        \\ movdqa %%xmm0, %%xmm3
        \\ movdqa %%xmm0, %%xmm4
        \\ movdqa %%xmm0, %%xmm5
        \\ movdqa %%xmm0, %%xmm6
        \\ movdqa %%xmm0, %%xmm7
        \\ movdqa %%xmm0, %%xmm8
        \\ movdqa %%xmm0, %%xmm9
        \\ movdqa %%xmm0, %%xmm10
        \\ movdqa %%xmm0, %%xmm11
        \\ movdqa %%xmm0, %%xmm12
        \\ movdqa %%xmm0, %%xmm13
        \\ movdqa %%xmm0, %%xmm14
        \\ movdqa %%xmm0, %%xmm15
        \\ movl $0x1F80, (%%rsp)
        \\ ldmxcsr (%%rsp)
        \\ fninit
        \\ addq $16, %%rsp
        \\ cmpb $0, zk_skip_fxrstor(%%rip)
        \\ jne 1f
        \\ fxrstor64 (%%rsp)
        \\ 1:
        \\ movq %%rbx, %%rsp
        \\ popq %%r15
        \\ popq %%r14
        \\ popq %%r13
        \\ popq %%r12
        \\ popq %%r11
        \\ popq %%r10
        \\ popq %%r9
        \\ popq %%r8
        \\ popq %%rbp
        \\ popq %%rdi
        \\ popq %%rsi
        \\ popq %%rdx
        \\ popq %%rcx
        \\ popq %%rbx
        \\ popq %%rax
        \\ addq $16, %%rsp
        \\ iretq
    );
}

fn hasErrorCode(comptime vec: u8) bool {
    return switch (vec) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

fn makeStub(comptime vec: u8) type {
    return struct {
        const template = if (hasErrorCode(vec))
            std.fmt.comptimePrint("pushq ${d}; jmp zkTrapCommon", .{vec})
        else
            std.fmt.comptimePrint("pushq $0; pushq ${d}; jmp zkTrapCommon", .{vec});

        fn entry() callconv(.naked) void {
            asm volatile (template);
        }
    };
}

fn irq0Stub() callconv(.naked) void {
    asm volatile ("pushq $0; pushq $32; jmp zkTrapCommon");
}

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;
const PIT_CMD: u16 = 0x43;
const PIT_CH0: u16 = 0x40;

fn picRemap() void {
    serial.outb(PIC1_CMD, 0x11);
    serial.outb(PIC2_CMD, 0x11);
    serial.outb(PIC1_DATA, 0x20);
    serial.outb(PIC2_DATA, 0x28);
    serial.outb(PIC1_DATA, 0x04);
    serial.outb(PIC2_DATA, 0x02);
    serial.outb(PIC1_DATA, 0x01);
    serial.outb(PIC2_DATA, 0x01);
    serial.outb(PIC1_DATA, 0xFF);
    serial.outb(PIC2_DATA, 0xFF);
}

fn picEoi(irq: u3) void {
    if (irq >= 8) serial.outb(PIC2_CMD, 0x20);
    serial.outb(PIC1_CMD, 0x20);
}

fn pitStart(hz: u32) void {
    const divisor: u16 = @intCast(@max(@as(u32, 1), 1193182 / hz));
    serial.outb(PIT_CMD, 0x36);
    serial.outb(PIT_CH0, @truncate(divisor));
    serial.outb(PIT_CH0, @truncate(divisor >> 8));
}

fn irqUnmask(irq: u3) void {
    const port = if (irq >= 8) PIC2_DATA else PIC1_DATA;
    const mask = serial.inb(port) & ~(@as(u8, 1) << @intCast(irq & 7));
    serial.outb(port, mask);
}

pub fn init() void {
    if (restoreFailProfile()) zk_skip_fxrstor = 1;
    enableFxsave();
    inline for (0..32) |vec| {
        const stub = makeStub(vec);
        setGate(vec, @intFromPtr(&stub.entry), if (vec == VEC_DF) 1 else 0, TRAP_GATE);
    }
    setGate(VEC_IRQ0, @intFromPtr(&irq0Stub), 0, INT_GATE);
    const idtr = IdtPointer{
        .limit = IDT_LIMIT,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idtr),
        : .{ .memory = true }
    );
    var rd: IdtPointer = undefined;
    asm volatile ("sidt (%[p])"
        :
        : [p] "r" (&rd),
        : .{ .memory = true }
    );
    if (rd.base != @intFromPtr(&idt) or rd.limit != IDT_LIMIT) {
        serial.print("\nZKN: IDTR verify FAILED base={x:0>16} limit={x:0>4}\n", .{
            rd.base, rd.limit,
        });
        hang();
    }
}

pub fn timerInit(hz: u32) void {
    picRemap();
    pitStart(hz);
    irqUnmask(0);
}

pub inline fn sti() void {
    asm volatile ("sti");
}

pub inline fn cli() void {
    asm volatile ("cli");
}
