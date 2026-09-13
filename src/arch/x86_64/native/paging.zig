// arch/x86_64/native/paging — owned page tables for the native kernel.
// First slice: identity map of the low 256 MiB (the 256 MiB qualification
// profile), 2 MiB leaves except the kernel's own 2 MiB
// block which is split into 4 KiB leaves so protection probes can flip
// per-page RW/NX bits. NXE and CR0.WP are enabled so supervisor RO/NX
// violations fault. ponytail: higher-half kernel, per-process address spaces
// and demand paging land in KWP3 per Z3; ceiling: full MM.

const serial = @import("serial");

pub const MAP_TOP: u64 = 256 * 1024 * 1024; // identity-mapped ceiling: full 256 MiB profile
pub const HUGE: u64 = 2 * 1024 * 1024;
pub const PAGE: u64 = 4096;

/// Deliberate unmapped probe address for the PF corpus: 16 MiB above the
/// mapped ceiling, page-aligned, far from the kernel block.
pub const PF_PROBE_ADDR: u64 = MAP_TOP + 16 * 1024 * 1024;

const PRESENT: u64 = 1 << 0;
const WRITE: u64 = 1 << 1;
const HUGE_BIT: u64 = 1 << 7;
const NX: u64 = 1 << 63;

var pml4: [512]u64 align(4096) = [_]u64{0} ** 512;
var pdpt: [512]u64 align(4096) = [_]u64{0} ** 512;
var pd: [512]u64 align(4096) = [_]u64{0} ** 512;
var kernel_pt: [512]u64 align(4096) = [_]u64{0} ** 512;

fn phys(comptime T: type, p: *const T) u64 {
    return @intFromPtr(p); // identity-mapped world
}

/// Build tables. `kernel_base` must be 2 MiB aligned (linker guarantees).
pub fn init(kernel_base: u64) void {
    pml4[0] = phys([512]u64, &pdpt) | PRESENT | WRITE;
    pdpt[0] = phys([512]u64, &pd) | PRESENT | WRITE;
    var i: u64 = 0;
    while (i * HUGE < MAP_TOP) : (i += 1) {
        pd[i] = (i * HUGE) | PRESENT | WRITE | HUGE_BIT;
    }
    // Split the kernel's block into 4 KiB leaves.
    const pd_index = kernel_base / HUGE;
    pd[pd_index] = phys([512]u64, &kernel_pt) | PRESENT | WRITE;
    var j: u64 = 0;
    while (j < 512) : (j += 1) {
        kernel_pt[j] = (kernel_base + j * PAGE) | PRESENT | WRITE;
    }
    enableNxe();
    loadCr3(phys([512]u64, &pml4));
    enableWriteProtect();
}

fn enableNxe() void {
    const efer: u64 = asm volatile (
        \\ movl $0xC0000080, %%ecx
        \\ rdmsr
        \\ shlq $32, %%rdx
        \\ orq %%rdx, %%rax
        : [ret] "={rax}" (-> u64),
        :
        : .{ .rcx = true, .rdx = true }
    );
    asm volatile (
        \\ movl $0xC0000080, %%ecx
        \\ movq %[lo], %%rax
        \\ movq %[hi], %%rdx
        \\ wrmsr
        :
        : [lo] "r" ((efer | (1 << 11)) & 0xFFFFFFFF),
          [hi] "r" ((efer | (1 << 11)) >> 32),
        : .{ .rcx = true, .rax = true, .rdx = true }
    );
}

fn loadCr3(table: u64) void {
    asm volatile ("movq %[t], %%cr3"
        :
        : [t] "r" (table),
        : .{ .memory = true }
    );
}

fn enableWriteProtect() void {
    asm volatile (
        \\ movq %%cr0, %%rax
        \\ orq $0x10000, %%rax
        \\ movq %%rax, %%cr0
        :
        :
        : .{ .rax = true }
    );
}

/// True when `paddr` falls in the fine-grained kernel block.
pub fn inKernelBlock(paddr: u64, kernel_base: u64) bool {
    return paddr >= kernel_base and paddr < kernel_base + HUGE;
}

/// Flip one 4 KiB page inside the kernel block to read-only.
pub fn setReadOnly(paddr: u64, kernel_base: u64) void {
    if (!inKernelBlock(paddr, kernel_base)) return;
    const idx = (paddr - kernel_base) / PAGE;
    kernel_pt[idx] &= ~WRITE;
    invlpg(paddr);
}

/// Flip one 4 KiB page inside the kernel block to no-execute.
pub fn setNoExecute(paddr: u64, kernel_base: u64) void {
    if (!inKernelBlock(paddr, kernel_base)) return;
    const idx = (paddr - kernel_base) / PAGE;
    kernel_pt[idx] |= NX;
    invlpg(paddr);
}

fn invlpg(addr: u64) void {
    asm volatile ("invlpg (%[a])"
        :
        : [a] "r" (addr),
        : .{ .memory = true }
    );
}
