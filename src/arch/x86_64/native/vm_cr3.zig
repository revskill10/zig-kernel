// arch/x86_64/native/vm_cr3 — narrow CR3/control-register helpers for the
// CPL0 private-VM probe. No scheduler, PCID, INVPCID, or generic
// address-space activation API. Hosted callers may use the pure masking
// helpers; privileged switch/restore must not be referenced on the host.

const builtin = @import("builtin");
const std = @import("std");

pub const PAGE: u64 = 4096;
pub const PHYS_TOP: u64 = 256 * 1024 * 1024;
pub const CR3_PWT: u64 = 1 << 3;
pub const CR3_PCD: u64 = 1 << 4;
pub const CR3_ADDR: u64 = 0x000F_FFFF_FFFF_F000;
pub const RFLAGS_IF: u64 = 1 << 9;
pub const CR0_WP: u64 = 1 << 16;
pub const CR4_LA57: u64 = 1 << 12;
pub const CR4_PCIDE: u64 = 1 << 17;
pub const CR4_SMEP: u64 = 1 << 20;
pub const CR4_SMAP: u64 = 1 << 21;
pub const EFER_NXE: u64 = 1 << 11;

pub fn cr3Addr(cr3: u64) u64 {
    return cr3 & CR3_ADDR;
}

pub fn cr3CacheFlags(cr3: u64) u64 {
    return cr3 & (CR3_PWT | CR3_PCD);
}

pub fn validateFrame(phys: u64) bool {
    return phys != 0 and phys % PAGE == 0 and phys < PHYS_TOP;
}

pub fn interruptsMasked(rflags: u64) bool {
    return rflags & RFLAGS_IF == 0;
}

pub fn writeProtectEnabled(cr0: u64) bool {
    return cr0 & CR0_WP != 0;
}

pub fn nxeEnabled(efer: u64) bool {
    return efer & EFER_NXE != 0;
}

pub fn boundedProfileOk(cr4: u64) bool {
    return cr4 & (CR4_PCIDE | CR4_LA57 | CR4_SMEP | CR4_SMAP) == 0;
}

pub fn readCr3() u64 {
    nativeOnly();
    return asm volatile ("movq %%cr3, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn writeCr3(value: u64) void {
    nativeOnly();
    asm volatile (
        \\ movq %[v], %%cr3
        :
        : [v] "r" (value)
        : .{ .memory = true }
    );
}

pub fn readCr0() u64 {
    nativeOnly();
    return asm volatile ("movq %%cr0, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn readCr4() u64 {
    nativeOnly();
    return asm volatile ("movq %%cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn readEfer() u64 {
    nativeOnly();
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

pub fn readRflags() u64 {
    nativeOnly();
    return asm volatile (
        \\ pushfq
        \\ popq %[r]
        : [r] "=r" (-> u64),
    );
}

pub fn readRsp() u64 {
    nativeOnly();
    return asm volatile ("movq %%rsp, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn cli() void {
    nativeOnly();
    asm volatile ("cli" ::: .{ .memory = true });
}

pub fn invlpg(addr: u64) void {
    nativeOnly();
    asm volatile ("invlpg (%[a])"
        :
        : [a] "r" (addr)
        : .{ .memory = true }
    );
}

pub fn readGdtrBase() u64 {
    nativeOnly();
    var ptr: [10]u8 align(16) = undefined;
    asm volatile ("sgdt %[p]"
        : [p] "=m" (ptr)
        :
        : .{ .memory = true }
    );
    return std.mem.readInt(u64, ptr[2..10], .little);
}

pub fn readIdtrBase() u64 {
    nativeOnly();
    var ptr: [10]u8 align(16) = undefined;
    asm volatile ("sidt %[p]"
        : [p] "=m" (ptr)
        :
        : .{ .memory = true }
    );
    return std.mem.readInt(u64, ptr[2..10], .little);
}

/// Load `root` into CR3 after a compiler memory barrier. Does not treat the
/// `mov` itself as success; callers must read CR3 back.
pub fn switchTo(root: u64) void {
    nativeOnly();
    if (!validateFrame(cr3Addr(root))) return;
    writeCr3(cr3Addr(root));
}

/// Restore the full saved CR3 value, including PWT/PCD.
pub fn restore(saved_cr3: u64) void {
    nativeOnly();
    if (!validateFrame(cr3Addr(saved_cr3))) return;
    writeCr3(saved_cr3);
}

fn nativeOnly() void {
    // Lazy: fires only if a privileged helper is referenced on a hosted
    // target. Pure masking/predicate helpers stay host-testable.
    if (comptime builtin.os.tag != .freestanding) {
        @compileError("vm_cr3 privileged helpers are native-only");
    }
}
