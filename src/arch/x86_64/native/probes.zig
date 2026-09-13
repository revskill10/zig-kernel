// arch/x86_64/native/probes — SysV-callable assembly probe helpers.
// Implementations live in module-level assembly (no compiler prologue).
// Zig calls them through extern SysV declarations (compiler-generated CALL).
// Fault/continuation labels and RET stay inside the assembly bodies.
// x87 CW and MXCSR control bits are callee-saved: every normal RET restores them.
// Destructive XMM/x87 smash lives in idt.zkTrapCommon after dispatch returns
// and before FXRSTOR; it is not a SysV-preserving helper.

pub fn ud2FaultRip() u64 {
    return asm volatile ("leaq zk_probe_ud2_fault(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn ud2ContRip() u64 {
    return asm volatile ("leaq zk_probe_ud2_cont(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn unmappedFaultRip() u64 {
    return asm volatile ("leaq zk_probe_unmapped_fault(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn unmappedContRip() u64 {
    return asm volatile ("leaq zk_probe_unmapped_cont(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn roFaultRip() u64 {
    return asm volatile ("leaq zk_probe_ro_fault(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn roContRip() u64 {
    return asm volatile ("leaq zk_probe_ro_cont(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn nxContRip() u64 {
    return asm volatile ("leaq zk_probe_nx_cont(%%rip), %[r]"
        : [r] "=r" (-> u64),
    );
}

pub extern fn zkProbeUd2() callconv(.{ .x86_64_sysv = .{} }) u64;
pub extern fn zkProbeUnmapped(addr: u64) callconv(.{ .x86_64_sysv = .{} }) u64;
pub extern fn zkProbeRoWrite(addr: u64) callconv(.{ .x86_64_sysv = .{} }) u64;
pub extern fn zkProbeNxJump(addr: u64) callconv(.{ .x86_64_sysv = .{} }) u64;
pub extern fn zkTimerSentinelLoop(limit: u64, cap: u64, ticks_addr: u64) callconv(.{ .x86_64_sysv = .{} }) u64;
pub extern fn zkAbiClobberProbe() callconv(.{ .x86_64_sysv = .{} }) u64;

pub fn probeUd2() u64 {
    return zkProbeUd2();
}

pub fn probeUnmapped(addr: u64) u64 {
    return zkProbeUnmapped(addr);
}

pub fn probeRoWrite(addr: u64) u64 {
    return zkProbeRoWrite(addr);
}

pub fn probeNxJump(addr: u64) u64 {
    return zkProbeNxJump(addr);
}

pub fn timerSentinelLoop(limit: u64, cap: u64, ticks_addr: u64) u64 {
    return zkTimerSentinelLoop(limit, cap, ticks_addr);
}

comptime {
    asm (
        \\ .text
        \\ .p2align 4
        \\ .globl zkProbeUd2
        \\ zkProbeUd2:
        \\     subq $16, %rsp
        \\     fnstcw (%rsp)
        \\     stmxcsr 4(%rsp)
        \\     movabsq $0x0123456789ABCDEF, %rax
        \\     movq %rax, %xmm0
        \\     movabsq $0xFEDCBA9876543210, %rax
        \\     movq %rax, %xmm7
        \\     punpcklqdq %xmm7, %xmm0
        \\     movabsq $0xA1B2C3D4E5F60718, %rax
        \\     movq %rax, %xmm1
        \\     movabsq $0x8190A0B0C0D0E0F0, %rax
        \\     movq %rax, %xmm7
        \\     punpcklqdq %xmm7, %xmm1
        \\     movl $0x1FA0, 8(%rsp)
        \\     ldmxcsr 8(%rsp)
        \\     movw $0x027F, 8(%rsp)
        \\     fldcw 8(%rsp)
        \\     fld1
        \\     std
        \\ .globl zk_probe_ud2_fault
        \\ zk_probe_ud2_fault:
        \\     ud2
        \\     fstp %st(0)
        \\     xorq %rax, %rax
        \\     jmp 6f
        \\ .globl zk_probe_ud2_cont
        \\ zk_probe_ud2_cont:
        \\     pushfq
        \\     popq %rcx
        \\     testq $0x400, %rcx
        \\     jz 3f
        \\     subq $16, %rsp
        \\     movups %xmm0, (%rsp)
        \\     movabsq $0x0123456789ABCDEF, %rax
        \\     cmpq %rax, (%rsp)
        \\     jne 4f
        \\     movabsq $0xFEDCBA9876543210, %rax
        \\     cmpq %rax, 8(%rsp)
        \\     jne 4f
        \\     movups %xmm1, (%rsp)
        \\     movabsq $0xA1B2C3D4E5F60718, %rax
        \\     cmpq %rax, (%rsp)
        \\     jne 4f
        \\     movabsq $0x8190A0B0C0D0E0F0, %rax
        \\     cmpq %rax, 8(%rsp)
        \\     jne 4f
        \\     stmxcsr (%rsp)
        \\     cmpl $0x1FA0, (%rsp)
        \\     jne 5f
        \\     fnstcw (%rsp)
        \\     cmpw $0x027F, (%rsp)
        \\     jne 5f
        \\     fstpl (%rsp)
        \\     movabsq $0x3FF0000000000000, %rax
        \\     cmpq %rax, (%rsp)
        \\     jne 7f
        \\     addq $16, %rsp
        \\     movq $1, %rax
        \\     jmp 6f
        \\ 3:
        \\     fstp %st(0)
        \\     movq $3, %rax
        \\     jmp 6f
        \\ 4:
        \\     addq $16, %rsp
        \\     fstp %st(0)
        \\     movq $4, %rax
        \\     jmp 6f
        \\ 5:
        \\     addq $16, %rsp
        \\     fstp %st(0)
        \\     movq $5, %rax
        \\     jmp 6f
        \\ 7:
        \\     addq $16, %rsp
        \\     movq $5, %rax
        \\ 6:
        \\     cld
        \\     fldcw (%rsp)
        \\     ldmxcsr 4(%rsp)
        \\     addq $16, %rsp
        \\     ret
        \\
        \\ .p2align 4
        \\ .globl zkProbeUnmapped
        \\ zkProbeUnmapped:
        \\ .globl zk_probe_unmapped_fault
        \\ zk_probe_unmapped_fault:
        \\     movq (%rdi), %rax
        \\     xorq %rax, %rax
        \\     ret
        \\ .globl zk_probe_unmapped_cont
        \\ zk_probe_unmapped_cont:
        \\     movq $1, %rax
        \\     ret
        \\
        \\ .p2align 4
        \\ .globl zkProbeRoWrite
        \\ zkProbeRoWrite:
        \\ .globl zk_probe_ro_fault
        \\ zk_probe_ro_fault:
        \\     movb $0x5A, (%rdi)
        \\     xorq %rax, %rax
        \\     ret
        \\ .globl zk_probe_ro_cont
        \\ zk_probe_ro_cont:
        \\     movq $1, %rax
        \\     ret
        \\
        \\ .p2align 4
        \\ .globl zkProbeNxJump
        \\ zkProbeNxJump:
        \\     xorq %rax, %rax
        \\     jmpq *%rdi
        \\ .globl zk_probe_nx_cont
        \\ zk_probe_nx_cont:
        \\     movq $1, %rax
        \\     ret
        \\
        \\ .p2align 4
        \\ .globl zkTimerSentinelLoop
        \\ zkTimerSentinelLoop:
        \\     pushq %rbp
        \\     pushq %rbx
        \\     pushq %r12
        \\     pushq %r13
        \\     pushq %r14
        \\     pushq %r15
        \\     movq %rdx, %rbp
        \\     movabsq $0xC0DEC0DEDEADBEEF, %rax
        \\     pushq %rax
        \\     subq $16, %rsp
        \\     fnstcw (%rsp)
        \\     stmxcsr 4(%rsp)
        \\     movabsq $0x1111111111111111, %r12
        \\     movabsq $0x2222222222222222, %r13
        \\     movabsq $0x3333333333333333, %r14
        \\     movabsq $0x4444444444444444, %rbx
        \\     movabsq $0xA5A5A5A5A5A5A5A5, %rax
        \\     movq %rax, %xmm0
        \\     movabsq $0x5A5A5A5A5A5A5A5A, %rax
        \\     movq %rax, %xmm7
        \\     punpcklqdq %xmm7, %xmm0
        \\     movabsq $0xB1B1B1B1B1B1B1B1, %rax
        \\     movq %rax, %xmm1
        \\     movabsq $0xC2C2C2C2C2C2C2C2, %rax
        \\     movq %rax, %xmm7
        \\     punpcklqdq %xmm7, %xmm1
        \\     movl $0x1FA0, 8(%rsp)
        \\     ldmxcsr 8(%rsp)
        \\     movw $0x027F, 8(%rsp)
        \\     fldcw 8(%rsp)
        \\     fld1
        \\ 10:
        \\     movq (%rbp), %rax
        \\     cmpq %rdi, %rax
        \\     jae 11f
        \\     pause
        \\     subq $1, %rsi
        \\     jz 12f
        \\     jmp 10b
        \\ 11:
        \\     movabsq $0x1111111111111111, %rax
        \\     cmpq %rax, %r12
        \\     jne 13f
        \\     movabsq $0x2222222222222222, %rax
        \\     cmpq %rax, %r13
        \\     jne 13f
        \\     movabsq $0x3333333333333333, %rax
        \\     cmpq %rax, %r14
        \\     jne 13f
        \\     movabsq $0x4444444444444444, %rax
        \\     cmpq %rax, %rbx
        \\     jne 13f
        \\     subq $16, %rsp
        \\     movups %xmm0, (%rsp)
        \\     movabsq $0xA5A5A5A5A5A5A5A5, %rax
        \\     cmpq %rax, (%rsp)
        \\     jne 14f
        \\     movabsq $0x5A5A5A5A5A5A5A5A, %rax
        \\     cmpq %rax, 8(%rsp)
        \\     jne 14f
        \\     movups %xmm1, (%rsp)
        \\     movabsq $0xB1B1B1B1B1B1B1B1, %rax
        \\     cmpq %rax, (%rsp)
        \\     jne 14f
        \\     movabsq $0xC2C2C2C2C2C2C2C2, %rax
        \\     cmpq %rax, 8(%rsp)
        \\     jne 14f
        \\     stmxcsr (%rsp)
        \\     cmpl $0x1FA0, (%rsp)
        \\     jne 14f
        \\     fnstcw (%rsp)
        \\     cmpw $0x027F, (%rsp)
        \\     jne 14f
        \\     fstpl (%rsp)
        \\     movabsq $0x3FF0000000000000, %rax
        \\     cmpq %rax, (%rsp)
        \\     jne 14f
        \\     addq $16, %rsp
        \\     movabsq $0xC0DEC0DEDEADBEEF, %rax
        \\     cmpq %rax, 16(%rsp)
        \\     jne 16f
        \\     movq $1, %rax
        \\     jmp 15f
        \\ 12:
        \\     fstp %st(0)
        \\     movq $2, %rax
        \\     jmp 15f
        \\ 14:
        \\     addq $16, %rsp
        \\     fstp %st(0)
        \\     xorq %rax, %rax
        \\     jmp 15f
        \\ 13:
        \\     fstp %st(0)
        \\     xorq %rax, %rax
        \\     jmp 15f
        \\ 16:
        \\     xorq %rax, %rax
        \\ 15:
        \\     fldcw (%rsp)
        \\     ldmxcsr 4(%rsp)
        \\     addq $16, %rsp
        \\     addq $8, %rsp
        \\     popq %r15
        \\     popq %r14
        \\     popq %r13
        \\     popq %r12
        \\     popq %rbx
        \\     popq %rbp
        \\     ret
        \\
        \\ .p2align 4
        \\ .globl zkAbiClobberProbe
        \\ zkAbiClobberProbe:
        \\     movq $0xDEAD, %rax
        \\     movq $0xDEAD, %rcx
        \\     movq $0xDEAD, %rdx
        \\     movq $0xDEAD, %rsi
        \\     movq $0xDEAD, %rdi
        \\     movq $0xDEAD, %r8
        \\     movq $0xDEAD, %r9
        \\     movq $0xDEAD, %r10
        \\     movq $0xDEAD, %r11
        \\     pcmpeqd %xmm0, %xmm0
        \\     movdqa %xmm0, %xmm1
        \\     movdqa %xmm0, %xmm2
        \\     movdqa %xmm0, %xmm3
        \\     movdqa %xmm0, %xmm4
        \\     movdqa %xmm0, %xmm5
        \\     movq $1, %rax
        \\     ret
    );
}
