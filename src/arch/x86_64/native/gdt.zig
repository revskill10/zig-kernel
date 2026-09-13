// arch/x86_64/native/gdt — real GDT/TSS storage and register wiring.
// Distinct from the hosted policy module (../gdt.zig): this builds permanent
// tables, loads GDTR/TR, and reloads segment registers. The architectural
// TSS64 layout here is the packed hardware form, not the policy struct.

pub const KERNEL_CODE_SEL: u16 = 0x08;
pub const KERNEL_DATA_SEL: u16 = 0x10;
pub const USER_DATA_SEL: u16 = 0x1B; // index 3, RPL 3 (sysret ordering)
pub const USER_CODE_SEL: u16 = 0x23; // index 4, RPL 3
pub const TSS_SEL: u16 = 0x28; // index 5

pub const ACC_KERNEL_CODE: u8 = 0x9A;
pub const ACC_KERNEL_DATA: u8 = 0x92;
pub const ACC_USER_DATA: u8 = 0xF2;
pub const ACC_USER_CODE: u8 = 0xFA;
/// Available 64-bit TSS: P=1 DPL=0 S=0 type=9.
pub const ACC_TSS_AVAILABLE: u8 = 0x89;
/// Busy 64-bit TSS after LTR: P=1 DPL=0 S=0 type=B.
pub const ACC_TSS_BUSY: u8 = 0x8B;

pub const FLG_CODE64: u4 = 0xA;
pub const FLG_DATA: u4 = 0xC;
pub const FLG_TSS: u4 = 0x0;

pub const GDT_COUNT: usize = 7;
pub const TSS_LIMIT: u20 = @sizeOf(Tss64) - 1; // 103; I/O map sits at 104

/// Architectural TSS64 (104 bytes). Every field align(1) so the layout
/// matches the packed hardware form and @sizeOf/offsets are exact on
/// Zig 0.16 (verified: size 104, rsp0=4, ist1=36, iopb=102).
pub const Tss64 = extern struct {
    _reserved0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    _reserved1: u64 align(1) = 0,
    ist1: u64 align(1) = 0,
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    _reserved2: u64 align(1) = 0,
    _reserved3: u16 align(1) = 0,
    iopb_offset: u16 align(1) = 104,
};

/// 10-byte GDTR operand: limit:u16 + base:u64, each align(1).
pub const GdtPointer = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};
/// Alias kept so hosted fixtures can name either production type.
pub const GdtPointerTest = GdtPointer;

pub const TssDescriptor = struct {
    lo: u64,
    hi: u64,
};

pub const DecodedTss = struct {
    base: u64,
    limit: u20,
    access: u8,
    flags: u4,
    reserved_hi: u32,
};

comptime {
    if (@sizeOf(Tss64) != 104 or @alignOf(Tss64) != 1)
        @compileError("TSS64 must be 104 bytes, align 1");
    if (@offsetOf(Tss64, "rsp0") != 4 or
        @offsetOf(Tss64, "rsp1") != 12 or
        @offsetOf(Tss64, "rsp2") != 20 or
        @offsetOf(Tss64, "ist1") != 36 or
        @offsetOf(Tss64, "ist2") != 44 or
        @offsetOf(Tss64, "ist3") != 52 or
        @offsetOf(Tss64, "ist4") != 60 or
        @offsetOf(Tss64, "ist5") != 68 or
        @offsetOf(Tss64, "ist6") != 76 or
        @offsetOf(Tss64, "ist7") != 84 or
        @offsetOf(Tss64, "_reserved2") != 92 or
        @offsetOf(Tss64, "_reserved3") != 100 or
        @offsetOf(Tss64, "iopb_offset") != 102)
        @compileError("TSS64 field offset mismatch");
    if (@sizeOf(GdtPointer) != 10 or @alignOf(GdtPointer) != 1 or
        @offsetOf(GdtPointer, "limit") != 0 or
        @offsetOf(GdtPointer, "base") != 2)
        @compileError("GDTR operand must be 10 bytes (limit@0, base@2)");
    if (TSS_LIMIT != 103)
        @compileError("TSS descriptor limit must be size-1 = 103");
}

/// Intel segment-descriptor encoder. Limit occupies bits 0–15 and 48–51;
/// base 0–15 lives at bits 16–31 (not in the limit field).
pub fn encodeSegment(base: u32, limit: u20, access: u8, flags: u4) u64 {
    const lim: u32 = limit;
    var e: u64 = 0;
    e |= @as(u64, lim & 0xFFFF);
    e |= @as(u64, base & 0xFFFF) << 16;
    e |= @as(u64, (base >> 16) & 0xFF) << 32;
    e |= @as(u64, access) << 40;
    e |= @as(u64, (lim >> 16) & 0x0F) << 48;
    e |= @as(u64, flags) << 52;
    e |= @as(u64, (base >> 24) & 0xFF) << 56;
    return e;
}

pub fn encodeTssDescriptor(base: u64, limit: u20, access: u8) TssDescriptor {
    return .{
        .lo = encodeSegment(@truncate(base), limit, access, FLG_TSS),
        .hi = base >> 32,
    };
}

/// Inverse of encodeTssDescriptor. Base bits 0–15 come from lo>>16;
/// lo&0xFFFF is the limit low word.
pub fn decodeTssDescriptor(lo: u64, hi: u64) DecodedTss {
    const base: u64 = ((lo >> 16) & 0xFFFF) |
        (((lo >> 32) & 0xFF) << 16) |
        (((lo >> 56) & 0xFF) << 24) |
        ((hi & 0xFFFFFFFF) << 32);
    const limit: u20 = @intCast((lo & 0xFFFF) | (((lo >> 48) & 0x0F) << 16));
    const access: u8 = @intCast((lo >> 40) & 0xFF);
    const flags: u4 = @intCast((lo >> 52) & 0x0F);
    const reserved_hi: u32 = @intCast(hi >> 32);
    return .{
        .base = base,
        .limit = limit,
        .access = access,
        .flags = flags,
        .reserved_hi = reserved_hi,
    };
}

pub fn selectorIndex(sel: u16) u16 {
    return sel >> 3;
}

pub fn selectorTi(sel: u16) u1 {
    return @truncate((sel >> 2) & 1);
}

pub fn selectorRpl(sel: u16) u2 {
    return @truncate(sel & 3);
}

pub fn accessType(access: u8) u4 {
    return @truncate(access & 0x0F);
}

pub fn accessSystem(access: u8) bool {
    return (access & 0x10) == 0;
}

pub fn accessDpl(access: u8) u2 {
    return @truncate((access >> 5) & 0x3);
}

pub fn accessPresent(access: u8) bool {
    return (access & 0x80) != 0;
}

/// Post-LTR TSS access byte: present, DPL0, system (S=0), busy 64-bit TSS.
pub fn isBusySystemTssDpl0(access: u8) bool {
    return access == ACC_TSS_BUSY;
}

pub fn isAvailableSystemTssDpl0(access: u8) bool {
    return access == ACC_TSS_AVAILABLE;
}

comptime {
    if (selectorIndex(KERNEL_CODE_SEL) != 1 or selectorTi(KERNEL_CODE_SEL) != 0 or selectorRpl(KERNEL_CODE_SEL) != 0)
        @compileError("KERNEL_CODE_SEL must be GDT index 1, TI=0, RPL=0");
    if (selectorIndex(KERNEL_DATA_SEL) != 2 or selectorTi(KERNEL_DATA_SEL) != 0 or selectorRpl(KERNEL_DATA_SEL) != 0)
        @compileError("KERNEL_DATA_SEL must be GDT index 2, TI=0, RPL=0");
    if (selectorIndex(USER_DATA_SEL) != 3 or selectorRpl(USER_DATA_SEL) != 3)
        @compileError("USER_DATA_SEL must be GDT index 3, RPL=3");
    if (selectorIndex(USER_CODE_SEL) != 4 or selectorRpl(USER_CODE_SEL) != 3)
        @compileError("USER_CODE_SEL must be GDT index 4, RPL=3");
    if (selectorIndex(TSS_SEL) != 5 or selectorTi(TSS_SEL) != 0 or selectorRpl(TSS_SEL) != 0)
        @compileError("TSS_SEL must be GDT index 5, TI=0, RPL=0");
}

comptime {
    // Descriptor byte-value fixtures for the fixed selectors.
    if (encodeSegment(0, 0xFFFFF, ACC_KERNEL_CODE, FLG_CODE64) != 0x00AF9A000000FFFF)
        @compileError("kernel code descriptor bytes mismatch");
    if (encodeSegment(0, 0xFFFFF, ACC_KERNEL_DATA, FLG_DATA) != 0x00CF92000000FFFF)
        @compileError("kernel data descriptor bytes mismatch");
    if (encodeSegment(0, 0xFFFFF, ACC_USER_DATA, FLG_DATA) != 0x00CFF2000000FFFF)
        @compileError("user data descriptor bytes mismatch");
    if (encodeSegment(0, 0xFFFFF, ACC_USER_CODE, FLG_CODE64) != 0x00AFFA000000FFFF)
        @compileError("user code descriptor bytes mismatch");

    // Asymmetric TSS fixture: distinct limit vs base-low, nonzero high base.
    // LE bytes 67 BC 18 07 F6 89 0A E5 = limitlo, baselo16, base[23:16],
    // access, limithi/flags, base[31:24]. Do not swap F6/E5.
    const sample_base: u64 = 0xA1B2C3D4E5F60718;
    const sample_limit: u20 = 0xABC67;
    const sample = encodeTssDescriptor(sample_base, sample_limit, ACC_TSS_AVAILABLE);
    if (sample.lo != 0xE50A89F60718BC67)
        @compileError("TSS lo encode mismatch");
    if (sample.hi != 0xA1B2C3D4)
        @compileError("TSS hi encode mismatch");
    const decoded = decodeTssDescriptor(sample.lo, sample.hi);
    if (decoded.base != sample_base or decoded.limit != sample_limit or
        decoded.access != ACC_TSS_AVAILABLE or decoded.flags != 0 or
        decoded.reserved_hi != 0)
        @compileError("TSS encode/decode roundtrip mismatch");
    // The old lo&0xFFFF base reconstruction cannot equal this fixture.
    if ((sample.lo & 0xFFFF) == (sample_base & 0xFFFF))
        @compileError("TSS fixture does not distinguish limit from base-low");
    if (isBusySystemTssDpl0(ACC_TSS_AVAILABLE) or !isBusySystemTssDpl0(ACC_TSS_BUSY))
        @compileError("busy TSS access predicate mismatch");
    if (isBusySystemTssDpl0(0x9B) or isBusySystemTssDpl0(0x99) or isBusySystemTssDpl0(0x0B))
        @compileError("busy TSS must reject S=1 / not-present lookalikes");
}

/// Storage is 16-byte aligned; the type itself stays align(1) so field
/// offsets match the 104-byte hardware TSS.
pub var tss: Tss64 align(16) = .{};
var gdt: [GDT_COUNT]u64 align(16) = undefined;

pub fn init(double_fault_stack_top: u64, ring0_stack_top: u64) void {
    tss = .{};
    tss.rsp0 = ring0_stack_top;
    tss.ist1 = double_fault_stack_top;
    const tss_base: u64 = @intFromPtr(&tss);
    const tss_desc = encodeTssDescriptor(tss_base, TSS_LIMIT, ACC_TSS_AVAILABLE);
    gdt = .{
        0,
        encodeSegment(0, 0xFFFFF, ACC_KERNEL_CODE, FLG_CODE64),
        encodeSegment(0, 0xFFFFF, ACC_KERNEL_DATA, FLG_DATA),
        encodeSegment(0, 0xFFFFF, ACC_USER_DATA, FLG_DATA),
        encodeSegment(0, 0xFFFFF, ACC_USER_CODE, FLG_CODE64),
        tss_desc.lo,
        tss_desc.hi,
    };
    const gdtr = GdtPointer{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };
    loadGdt(&gdtr);
    loadTss(TSS_SEL);
}

fn loadGdt(gdtr: *const GdtPointer) void {
    asm volatile (
        \\ lgdt (%[g])
        \\ mov %[kds], %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%ss
        \\ mov %%ax, %%fs
        \\ mov %%ax, %%gs
        \\ pushq %[kcs]
        \\ leaq 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\ 1:
        :
        : [g] "r" (gdtr),
          [kds] "i" (KERNEL_DATA_SEL),
          [kcs] "i" (@as(u64, KERNEL_CODE_SEL)),
        : .{ .rax = true, .memory = true }
    );
}

fn loadTss(sel: u16) void {
    // LTR writes the busy bit into the TSS descriptor in the GDT.
    asm volatile ("ltr %[s]"
        :
        : [s] "r" (sel),
        : .{ .memory = true }
    );
}

/// Read back live table facts: CS/SS/TR selectors, the loaded GDTR
/// (base/limit), and the decoded TSS descriptor (base/limit/present/type).
/// LTR transitions the TSS descriptor from available (0x89) to busy (0x8B);
/// only the architectural busy system DPL0 present byte is accepted.
pub fn verify() bool {
    const cs = asm volatile ("mov %%cs, %[r]"
        : [r] "=r" (-> u16),
    );
    const ss = asm volatile ("mov %%ss, %[r]"
        : [r] "=r" (-> u16),
    );
    const tr = asm volatile ("str %[r]"
        : [r] "=r" (-> u16),
    );
    if (cs != KERNEL_CODE_SEL or ss != KERNEL_DATA_SEL or tr != TSS_SEL)
        return false;
    if (selectorIndex(cs) != 1 or selectorTi(cs) != 0 or selectorRpl(cs) != 0)
        return false;
    if (selectorIndex(ss) != 2 or selectorTi(ss) != 0 or selectorRpl(ss) != 0)
        return false;
    if (selectorIndex(tr) != 5 or selectorTi(tr) != 0 or selectorRpl(tr) != 0)
        return false;

    var gp: GdtPointer = undefined;
    asm volatile ("sgdt (%[p])"
        :
        : [p] "r" (&gp),
        : .{ .memory = true }
    );
    if (gp.base != @intFromPtr(&gdt) or
        gp.limit != @sizeOf(@TypeOf(gdt)) - 1)
        return false;

    const t = decodeTss();
    return t.base == @intFromPtr(&tss) and
        t.limit == TSS_LIMIT and
        t.flags == FLG_TSS and
        t.reserved_hi == 0 and
        isBusySystemTssDpl0(t.access);
}

fn decodeTss() DecodedTss {
    // Volatile: LTR mutates the in-memory type field; ReleaseSmall/LTO
    // must not reuse the available 0x89 written by init().
    const slots: *volatile [GDT_COUNT]u64 = &gdt;
    return decodeTssDescriptor(slots[5], slots[6]);
}
