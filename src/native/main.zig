// src/native/main — native x86_64 kernel entry (KWP2 first slice).
// Entered from the EFI loader after ExitBootServices via an explicit ABI:
// rdi = physical BootInfo pointer, rsp = owned stack, interrupts masked,
// identity-mapped, no return address (the loader jumps; kmain never returns).
//
// Stage markers on COM1 are the qualification evidence contract; the
// qualifier (scripts/qualify-native) checks their order. Every failure path
// exits through isa-debug-exit with a distinct code — nothing here is a
// hosted fallback.

const boot_info = @import("boot_info");
const serial = @import("serial");
const gdt = @import("gdt");
const idt = @import("idt");
const paging = @import("paging");
const pmm = @import("pmm");
const alloc_probe = @import("alloc_probe.zig");
const probes = idt.probes;

const DEBUG_EXIT_PORT: u16 = 0xF4;
const EXIT_OK: u32 = 0x10; // QEMU reports (code<<1)|1 = 0x21 = host 33
const EXIT_BOOTINFO: u32 = 0x11;
const EXIT_GDT: u32 = 0x12;
const EXIT_PMM: u32 = 0x13;
const EXIT_TRAP: u32 = 0x14;
const EXIT_TIMER: u32 = 0x15;
const EXIT_PAGING: u32 = 0x16;
pub const EXIT_VM: u32 = 0x17; // QEMU reports (code<<1)|1 = 0x2F = host 47
const EXIT_PANIC: u32 = 0x3F;

const TRAP_ITERS: u64 = 64;
const TIMER_TICKS: u64 = 32;
const TIMER_CAP: u64 = 200_000_000;

var df_stack: [16384]u8 align(16) = undefined;
var ro_page: [4096]u8 align(4096) = undefined;
var nx_page: [4096]u8 align(4096) = undefined;

var info_g: *boot_info.BootInfo = undefined;

comptime {
    if (paging.MAP_TOP != pmm.MANAGED_TOP) @compileError("mapped domain != PMM ceiling");
    if (paging.PF_PROBE_ADDR < paging.MAP_TOP) @compileError("PF probe inside mapped domain");
    if (paging.PF_PROBE_ADDR != 0x11000000) @compileError("PF_PROBE_ADDR must stay 0x11000000");
}

fn n6Negative() bool {
    const root = @import("root");
    return @hasDecl(root, "ZK_N6_NEGATIVE") and root.ZK_N6_NEGATIVE;
}

fn nativeExit(code: u32) noreturn {
    serial.print("ZKN: exit code={x}\n", .{code});
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (code),
          [p] "N{dx}" (DEBUG_EXIT_PORT),
    );
    idt.hang();
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    serial.print("\nZKN: PANIC {s}\n", .{msg});
    nativeExit(EXIT_PANIC);
}

fn readCr0() u64 {
    return asm volatile ("movq %%cr0, %[r]"
        : [r] "=r" (-> u64),
    );
}

fn readCr3() u64 {
    return asm volatile ("movq %%cr3, %[r]"
        : [r] "=r" (-> u64),
    );
}

fn readEfer() u64 {
    return asm volatile (
        \\ movl $0xC0000080, %%ecx
        \\ rdmsr
        \\ shlq $32, %%rdx
        \\ orq %%rdx, %%rax
        : [r] "={rax}" (-> u64),
        :
        : .{ .rcx = true, .rdx = true }
    );
}

fn physMask(entry: u64) u64 {
    return entry & 0x000ffffffffff000;
}

fn leafPte(addr: u64) ?u64 {
    const pml4_base = physMask(readCr3());
    const pml4e = @as(*const volatile u64, @ptrFromInt(pml4_base + ((addr >> 39) & 0x1FF) * 8)).*;
    if ((pml4e & 1) == 0) return null;
    const pdpte = @as(*const volatile u64, @ptrFromInt(physMask(pml4e) + ((addr >> 30) & 0x1FF) * 8)).*;
    if ((pdpte & 1) == 0) return null;
    if ((pdpte & (1 << 7)) != 0) return pdpte;
    const pde = @as(*const volatile u64, @ptrFromInt(physMask(pdpte) + ((addr >> 21) & 0x1FF) * 8)).*;
    if ((pde & 1) == 0) return null;
    if ((pde & (1 << 7)) != 0) return pde;
    const pte = @as(*const volatile u64, @ptrFromInt(physMask(pde) + ((addr >> 12) & 0x1FF) * 8)).*;
    if ((pte & 1) == 0) return null;
    return pte;
}

fn expectWpNxe() void {
    if ((readCr0() & (1 << 16)) == 0) nativeExit(EXIT_PAGING);
    if ((readEfer() & (1 << 11)) == 0) nativeExit(EXIT_PAGING);
}

fn expectRoPte(addr: u64) void {
    const pte = leafPte(addr) orelse nativeExit(EXIT_PAGING);
    if ((pte & 1) == 0) nativeExit(EXIT_PAGING);
    if ((pte & 2) != 0) nativeExit(EXIT_PAGING);
}

fn expectNxPte(addr: u64) void {
    const pte = leafPte(addr) orelse nativeExit(EXIT_PAGING);
    if ((pte & 1) == 0) nativeExit(EXIT_PAGING);
    if ((pte & (1 << 63)) == 0) nativeExit(EXIT_PAGING);
}

export fn kmain(info: *boot_info.BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    info_g = info;
    serial.init();
    serial.print("ZKN: entry\n", .{});

    info.validate() catch |err| {
        serial.print("ZKN: bootinfo-invalid reason={s}\n", .{@errorName(err)});
        nativeExit(EXIT_BOOTINFO);
    };
    serial.print("ZKN: bootinfo-ok ranges={d} efi-stride={d} efi-ver={d}\n", .{
        info.range_count, info.efi_desc_size, info.efi_desc_version,
    });
    serial.print("ZKN: serial-ok\n", .{});

    const stack_top = info.stackTop();
    gdt.init(@intFromPtr(&df_stack) + @sizeOf(@TypeOf(df_stack)), stack_top);
    if (!gdt.verify()) nativeExit(EXIT_GDT);
    serial.print("ZKN: gdt-ok\n", .{});

    idt.init();
    serial.print("ZKN: idt-ok\n", .{});

    paging.init(info.kernel_base);
    if (!paging.inKernelBlock(@intFromPtr(&ro_page), info.kernel_base) or
        !paging.inKernelBlock(@intFromPtr(&nx_page), info.kernel_base))
        nativeExit(EXIT_PAGING);
    expectWpNxe();
    if (leafPte(paging.PF_PROBE_ADDR) != null) nativeExit(EXIT_PAGING);
    serial.print("ZKN: paging-ok\n", .{});

    pmm.init(info) catch nativeExit(EXIT_PMM);
    if (!pmm.isInitialized()) nativeExit(EXIT_PMM);
    const st = pmm.stats();
    if (st.free == 0) nativeExit(EXIT_PMM);
    const page = pmm.allocPage() orelse nativeExit(EXIT_PMM);
    if (!pmm.inManagedDomain(page)) nativeExit(EXIT_PMM);
    if (!pmm.isAllocatable(page)) nativeExit(EXIT_PMM);
    {
        const p: [*]volatile u8 = @ptrFromInt(page);
        alloc_probe.writeSentinels(p);
        if (!alloc_probe.checkSentinels(p)) nativeExit(EXIT_PMM);
    }
    if (pmm.stats().free != st.free - 1) nativeExit(EXIT_PMM);
    if (!pmm.freePage(page)) nativeExit(EXIT_PMM);
    if (pmm.stats().free != st.free) nativeExit(EXIT_PMM);
    {
        const s2 = pmm.stats();
        serial.print("ZKN: pmm-ok total={d} free={d} unmanaged={d} excluded={d}\n", .{
            s2.total, s2.free, s2.unmanaged, s2.excluded,
        });
    }

    if (n6Negative()) runNegativeUd2();
    runTrapCorpus();
    maybeRunVmProbe();
    finishBoot();
}

fn maybeRunVmProbe() void {
    const root = @import("root");
    if (comptime @hasDecl(root, "runVmProbe")) {
        root.runVmProbe(@ptrCast(info_g));
    }
}

fn runNegativeUd2() noreturn {
    // Arm vector 6 at a RIP that is not the helper's UD2; the real site must be fatal.
    _ = idt.arm(.{
        .vector = idt.VEC_UD,
        .fault_rip = 0x1111,
        .resume_rip = probes.ud2ContRip(),
        .error_code = idt.ERR_UD2,
    });
    _ = probes.probeUd2();
    nativeExit(EXIT_TRAP);
}

fn runTrapCorpus() void {
    var i: u64 = 0;
    var last_rip: u64 = 0;
    while (i < TRAP_ITERS) : (i += 1) {
        const gen = idt.arm(.{
            .vector = idt.VEC_UD,
            .fault_rip = probes.ud2FaultRip(),
            .resume_rip = probes.ud2ContRip(),
            .error_code = idt.ERR_UD2,
        });
        if (probes.probeUd2() != 1) nativeExit(EXIT_TRAP);
        const rec = idt.takeRecord() orelse nativeExit(EXIT_TRAP);
        if (rec.vector != idt.VEC_UD or rec.rip != probes.ud2FaultRip() or
            rec.error_code != idt.ERR_UD2 or rec.generation != gen)
            nativeExit(EXIT_TRAP);
        last_rip = rec.rip;
    }
    serial.print("ZKN: trap-ud2-ok vector=6 count={d} rip={x:0>16}\n", .{ TRAP_ITERS, last_rip });

    i = 0;
    var last_cr2: u64 = 0;
    var last_err: u64 = 0;
    while (i < TRAP_ITERS) : (i += 1) {
        const gen = idt.arm(.{
            .vector = idt.VEC_PF,
            .fault_rip = probes.unmappedFaultRip(),
            .resume_rip = probes.unmappedContRip(),
            .cr2 = paging.PF_PROBE_ADDR,
            .match_cr2 = true,
            .error_code = idt.ERR_PF_NOTPRESENT_READ,
        });
        if (probes.probeUnmapped(paging.PF_PROBE_ADDR) != 1) nativeExit(EXIT_TRAP);
        const rec = idt.takeRecord() orelse nativeExit(EXIT_TRAP);
        if (rec.vector != idt.VEC_PF or rec.rip != probes.unmappedFaultRip() or
            rec.cr2 != paging.PF_PROBE_ADDR or rec.error_code != idt.ERR_PF_NOTPRESENT_READ or
            rec.generation != gen)
            nativeExit(EXIT_TRAP);
        last_cr2 = rec.cr2;
        last_err = rec.error_code;
    }
    serial.print("ZKN: trap-pf-unmapped-ok vector=14 cr2={x:0>16} code={x} count={d}\n", .{
        last_cr2, last_err, TRAP_ITERS,
    });

    paging.setReadOnly(@intFromPtr(&ro_page), info_g.kernel_base);
    expectRoPte(@intFromPtr(&ro_page));
    expectWpNxe();
    i = 0;
    while (i < TRAP_ITERS) : (i += 1) {
        const gen = idt.arm(.{
            .vector = idt.VEC_PF,
            .fault_rip = probes.roFaultRip(),
            .resume_rip = probes.roContRip(),
            .cr2 = @intFromPtr(&ro_page),
            .match_cr2 = true,
            .error_code = idt.ERR_PF_RO_WRITE,
        });
        if (probes.probeRoWrite(@intFromPtr(&ro_page)) != 1) nativeExit(EXIT_TRAP);
        const rec = idt.takeRecord() orelse nativeExit(EXIT_TRAP);
        if (rec.vector != idt.VEC_PF or rec.rip != probes.roFaultRip() or
            rec.cr2 != @intFromPtr(&ro_page) or rec.error_code != idt.ERR_PF_RO_WRITE or
            rec.generation != gen)
            nativeExit(EXIT_TRAP);
        last_err = rec.error_code;
    }
    serial.print("ZKN: trap-pf-ro-write-ok vector=14 code={x} count={d}\n", .{ last_err, TRAP_ITERS });

    const nx_addr = @intFromPtr(&nx_page);
    const np: [*]volatile u8 = @ptrFromInt(nx_addr);
    np[0] = 0xC3;
    paging.setNoExecute(nx_addr, info_g.kernel_base);
    expectNxPte(nx_addr);
    expectWpNxe();
    i = 0;
    while (i < TRAP_ITERS) : (i += 1) {
        const gen = idt.arm(.{
            .vector = idt.VEC_PF,
            .fault_rip = nx_addr,
            .resume_rip = probes.nxContRip(),
            .cr2 = nx_addr,
            .match_cr2 = true,
            .error_code = idt.ERR_PF_NX_FETCH,
        });
        if (probes.probeNxJump(nx_addr) != 1) nativeExit(EXIT_TRAP);
        const rec = idt.takeRecord() orelse nativeExit(EXIT_TRAP);
        if (rec.vector != idt.VEC_PF or rec.rip != nx_addr or rec.cr2 != nx_addr or
            rec.error_code != idt.ERR_PF_NX_FETCH or rec.generation != gen)
            nativeExit(EXIT_TRAP);
        last_err = rec.error_code;
    }
    serial.print("ZKN: trap-pf-nx-exec-ok vector=14 code={x} count={d}\n", .{ last_err, TRAP_ITERS });
}

fn finishBoot() noreturn {
    idt.timerInit(100);
    const ticks_addr = idt.timerTicksAddr();
    idt.sti();
    const rc = probes.timerSentinelLoop(TIMER_TICKS, TIMER_CAP, ticks_addr);
    idt.cli();
    if (rc == 2 or idt.timerTicks() < TIMER_TICKS) nativeExit(EXIT_TIMER);
    if (rc != 1) nativeExit(EXIT_TRAP);
    serial.print("ZKN: timer-ok ticks={d}\n", .{idt.timerTicks()});
    serial.print("ZKN: done\n", .{});
    nativeExit(EXIT_OK);
}

const std = @import("std");
