// arch/x86_64/native/user_vm — allocation-free private user page-table
// construction and teardown (KWP3a.2a).
//
// Pure core: no asm, no global PMM import, no integer-to-pointer conversion.
// Frame bytes are reached only through a caller provider. Re-parses accepted
// ELF bytes rather than trusting a forgeable Plan. Inactive-only teardown.
// No CR3 switch, CPL3, SYSCALL, task entry, or scheduler.

const std = @import("std");
const user_elf = @import("user_elf");

pub const PAGE: u64 = 4096;
pub const HUGE: u64 = 2 * 1024 * 1024;
pub const PHYS_TOP: u64 = 256 * 1024 * 1024;

pub const MAX_IMAGE_PAGES: u32 = 8192;
pub const MAX_STACK_PAGES: u32 = 16;
pub const MAX_IMAGE_PTS: u32 = 17;
pub const MAX_STACK_PTS: u32 = 1;
pub const MAX_ROOT_TABLES: u32 = 3; // PML4 + PDPT + user PD
pub const MAX_TABLE_FRAMES: u32 = MAX_ROOT_TABLES + MAX_IMAGE_PTS + MAX_STACK_PTS; // 21
pub const MAX_OWNED_FRAMES: u32 = MAX_IMAGE_PAGES + MAX_STACK_PAGES + MAX_TABLE_FRAMES; // 8229

pub const STACK_TOP: u64 = 0x7fffe000;
pub const STACK_LO: u64 = 0x7ffee000; // sixteen pages [STACK_LO, STACK_TOP)
pub const STACK_GUARD: u64 = 0x7ffed000;

pub const PTE_P: u64 = 1 << 0;
pub const PTE_W: u64 = 1 << 1;
pub const PTE_U: u64 = 1 << 2;
pub const PTE_A: u64 = 1 << 5;
pub const PTE_D: u64 = 1 << 6;
pub const PTE_PS: u64 = 1 << 7;
pub const PTE_G: u64 = 1 << 8;
pub const PTE_NX: u64 = 1 << 63;
pub const PTE_ADDR: u64 = 0x000F_FFFF_FFFF_F000;
pub const PTE_AD: u64 = PTE_A | PTE_D;
pub const PTE_KNOWN: u64 = PTE_P | PTE_W | PTE_U | PTE_A | PTE_D | PTE_PS | PTE_G | PTE_NX | PTE_ADDR;
/// CR3 address field. PWT/PCD exist without PCID; compare roots after masking.
pub const CR3_PWT: u64 = 1 << 3;
pub const CR3_PCD: u64 = 1 << 4;
pub const CR3_ADDR: u64 = PTE_ADDR;

comptime {
    if (MAX_OWNED_FRAMES != 8229)
        @compileError("owned-frame budget must stay 8229");
    if (MAX_TABLE_FRAMES != 21)
        @compileError("private table budget must stay 21");
    if ((STACK_TOP - STACK_LO) / PAGE != MAX_STACK_PAGES)
        @compileError("stack window must be sixteen pages");
    if (STACK_GUARD + PAGE != STACK_LO)
        @compileError("guard page must sit immediately below the stack");
    if (user_elf.MAX_MAPPED_PAGES != MAX_IMAGE_PAGES)
        @compileError("image page budget must match the accepted parser");
}

pub const AllocError = error{
    OutOfMemory,
    PhysicalZero,
    FrameUnaligned,
    FrameOutOfDomain,
    DuplicateFrame,
    ReservedFrame,
};

pub const AccessError = error{
    PageAccess,
    PhysicalZero,
    FrameUnaligned,
    FrameOutOfDomain,
    NotOwnedFrame,
};

pub const LocalError = error{
    InvalidState,
    JournalFull,
    BudgetExceeded,
    MappingConflict,
    CopyFailed,
    ActiveRoot,
    DuplicateDestroy,
    ReleaseFailed,
    PlanMismatch,
    TemplateNotPresent,
    TemplateUser,
    TemplateHuge,
    TemplateUnaligned,
    TemplateZero,
    TemplateOutOfDomain,
    TemplateRoot,
    ReservedBits,
};

pub const Error = user_elf.Error || AllocError || AccessError || LocalError;

pub const State = enum { empty, building, ready, destroyed };

pub const RootObservation = union(enum) {
    inactive,
    cr3: u64,
};

/// Immutable supervisor snapshot. `pdpt0_entry` is copied into the private
/// PDPT[0]; A/D bits may differ from a later hardware walk, but address and
/// permission bits must not. The object does not own the kernel tables.
pub const KernelTemplate = struct {
    root_phys: u64,
    pdpt0_entry: u64,

    pub fn pdpt0AddrPerm(self: KernelTemplate) u64 {
        return self.pdpt0_entry & ~PTE_AD;
    }
};

/// Caller-owned allocation journal. The 8229-ID backing store must not live
/// on a kernel stack; native callers place it in static BSS. Never copy.
pub const Journal = struct {
    frames: []u64,
    count: usize = 0,

    pub fn init(storage: []u64) Journal {
        return .{ .frames = storage, .count = 0 };
    }

    pub fn contains(self: *const Journal, phys: u64) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.frames[i] == phys) return true;
        }
        return false;
    }
};

/// Constructed address space. Always used by pointer; do not copy by value.
///
/// Physical frame 0 is never stored in `journal`: `releaseAll` uses 0 as the
/// successfully-released compaction mark. Outstanding ownership of zero is
/// kept in `owns_zero` so a refused `freePage(0)` cannot be discarded or
/// forgotten. `failed_release_frame` is 0 when there is no nonzero failure;
/// combine it with `owns_zero` to identify a failed zero release.
pub const AddressSpace = struct {
    state: State = .empty,
    journal: *Journal,
    root_phys: u64 = 0,
    entry: u64 = 0,
    stack_top: u64 = 0,
    image_pages: u32 = 0,
    stack_pages: u32 = 0,
    table_pages: u32 = 0,
    image_pts: u32 = 0,
    stack_pts: u32 = 0,
    failed_release_frame: u64 = 0,
    owns_zero: bool = false,

    pub fn init(journal: *Journal) AddressSpace {
        return .{ .journal = journal };
    }

    pub fn ownedCount(self: *const AddressSpace) usize {
        return self.journal.count + @intFromBool(self.owns_zero);
    }
};

pub fn reset(space: *AddressSpace) Error!void {
    if (space.state != .destroyed) return error.InvalidState;
    if (space.journal.count != 0 or space.owns_zero) return error.InvalidState;
    space.state = .empty;
    space.root_phys = 0;
    space.entry = 0;
    space.stack_top = 0;
    space.image_pages = 0;
    space.stack_pages = 0;
    space.table_pages = 0;
    space.image_pts = 0;
    space.stack_pts = 0;
    space.failed_release_frame = 0;
    space.owns_zero = false;
}

/// Public constructor: re-parses `bytes` with the accepted planner and
/// consumes that plan immediately. The ELF slice and template are borrowed.
pub fn construct(
    provider: anytype,
    bytes: []const u8,
    template: KernelTemplate,
    space: *AddressSpace,
) Error!void {
    const plan = user_elf.plan(bytes) catch |e| return e;
    return constructPlan(provider, bytes, plan, template, space);
}

/// Accept a caller plan only after it matches a fresh parse of `bytes`.
/// A forged or mutated plan cannot bypass file/address/permission checks.
pub fn constructClaimedPlan(
    provider: anytype,
    bytes: []const u8,
    claimed: user_elf.Plan,
    template: KernelTemplate,
    space: *AddressSpace,
) Error!void {
    const plan = user_elf.plan(bytes) catch |e| return e;
    if (!plansEqual(plan, claimed)) return error.PlanMismatch;
    return constructPlan(provider, bytes, plan, template, space);
}

pub fn destroy(
    provider: anytype,
    space: *AddressSpace,
    obs: RootObservation,
) Error!void {
    switch (space.state) {
        .empty => return error.InvalidState,
        .destroyed => return error.DuplicateDestroy,
        .building, .ready => {},
    }
    switch (obs) {
        .inactive => {},
        .cr3 => |active| {
            if (space.root_phys != 0 and cr3Root(active) == space.root_phys)
                return error.ActiveRoot;
        },
    }
    releaseAll(provider, space) catch {
        space.state = .destroyed;
        return error.ReleaseFailed;
    };
    clearCounts(space);
    space.root_phys = 0;
    space.entry = 0;
    space.stack_top = 0;
    space.state = .destroyed;
}

/// Retry releasing journaled frames and any outstanding physical zero after
/// a previous `ReleaseFailed`. Successful frees from the first attempt are
/// not retried. Reset/reuse remain prohibited until every owned frame,
/// including zero, has actually been released.
pub fn retryRelease(provider: anytype, space: *AddressSpace) Error!void {
    if (space.state != .destroyed) return error.InvalidState;
    if (space.journal.count == 0 and !space.owns_zero) return;
    releaseAll(provider, space) catch return error.ReleaseFailed;
    clearCounts(space);
    space.root_phys = 0;
    space.entry = 0;
    space.stack_top = 0;
}

fn constructPlan(
    provider: anytype,
    bytes: []const u8,
    plan: user_elf.Plan,
    template: KernelTemplate,
    space: *AddressSpace,
) Error!void {
    if (space.state != .empty) return error.InvalidState;
    if (space.journal.count != 0 or space.owns_zero) return error.InvalidState;
    try validateTemplate(template);

    space.state = .building;
    inner(provider, bytes, plan, template, space) catch |err| {
        releaseAll(provider, space) catch {
            space.state = .destroyed;
            return error.ReleaseFailed;
        };
        clearCounts(space);
        space.root_phys = 0;
        space.entry = 0;
        space.stack_top = 0;
        space.state = .empty;
        return err;
    };
    space.entry = plan.entry;
    space.stack_top = STACK_TOP;
    space.state = .ready;
}

fn inner(
    provider: anytype,
    bytes: []const u8,
    plan: user_elf.Plan,
    template: KernelTemplate,
    space: *AddressSpace,
) Error!void {
    const borrowed_pd = template.pdpt0_entry & PTE_ADDR;

    const pml4 = try takeFrame(provider, space, template);
    space.table_pages += 1;
    space.root_phys = pml4;

    const pdpt = try takeFrame(provider, space, template);
    space.table_pages += 1;
    try writeNew(provider, pml4, 0, pdpt, PTE_P | PTE_W | PTE_U);

    try writeBorrowedPdpt0(provider, pdpt, template);
    if (borrowed_pd == pdpt or borrowed_pd == pml4)
        return error.ReservedFrame;

    const pd = try takeFrame(provider, space, template);
    space.table_pages += 1;
    try writeNew(provider, pdpt, 1, pd, PTE_P | PTE_W | PTE_U);

    var si: u8 = 0;
    while (si < plan.segment_count) : (si += 1) {
        try mapSegment(provider, space, pd, bytes, plan.segments[si], template);
    }
    try mapStack(provider, space, pd, template);
}

fn validateTemplate(template: KernelTemplate) Error!void {
    if (template.root_phys == 0) return error.TemplateZero;
    if (template.root_phys % PAGE != 0) return error.TemplateUnaligned;
    if (template.root_phys >= PHYS_TOP) return error.TemplateOutOfDomain;

    const e = template.pdpt0_entry;
    if (e & PTE_P == 0) return error.TemplateNotPresent;
    if (e & PTE_U != 0) return error.TemplateUser;
    if (e & PTE_PS != 0) return error.TemplateHuge;
    const addr = e & PTE_ADDR;
    if (addr == 0) return error.TemplateZero;
    if (addr % PAGE != 0) return error.TemplateUnaligned;
    if (addr >= PHYS_TOP) return error.TemplateOutOfDomain;
    if (addr == template.root_phys) return error.TemplateRoot;
}

fn takeFrame(provider: anytype, space: *AddressSpace, template: KernelTemplate) Error!u64 {
    if (space.journal.count >= space.journal.frames.len) return error.JournalFull;
    if (space.journal.count >= MAX_OWNED_FRAMES) return error.BudgetExceeded;

    const phys = provider.allocPage() catch |err| return mapAllocErr(err);

    // Never pageBytes(0), never journal 0 (compaction sentinel), and never
    // drop a just-allocated zero. Ownership is recorded here; releaseAll is
    // the only path that may call freePage(0).
    if (phys == 0) {
        space.owns_zero = true;
        return error.PhysicalZero;
    }
    if (phys % PAGE != 0) return error.FrameUnaligned;
    if (phys >= PHYS_TOP) return error.FrameOutOfDomain;
    if (space.journal.contains(phys)) return error.DuplicateFrame;
    const borrowed_pd = template.pdpt0_entry & PTE_ADDR;
    if (phys == template.root_phys or phys == borrowed_pd)
        return error.ReservedFrame;

    space.journal.frames[space.journal.count] = phys;
    space.journal.count += 1;

    const page = provider.pageBytes(phys) catch return error.PageAccess;
    @memset(page, 0);
    return phys;
}

fn mapSegment(
    provider: anytype,
    space: *AddressSpace,
    pd: u64,
    bytes: []const u8,
    seg: user_elf.Segment,
    template: KernelTemplate,
) Error!void {
    if ((seg.flags & user_elf.PF_W) != 0 and (seg.flags & user_elf.PF_X) != 0)
        return error.WriteExecute;

    var va = seg.map_start;
    while (va < seg.map_end) : (va += PAGE) {
        if (pml4Index(va) != 0 or pdptIndex(va) != 1)
            return error.ImageOutOfRange;
        const pt = try ensurePt(provider, space, pd, va, .image, template);
        const idx = ptIndex(va);
        const cur = try readEntry(provider, pt, idx);
        if (cur & PTE_P != 0) return error.MappingConflict;
        if (space.image_pages >= MAX_IMAGE_PAGES) return error.BudgetExceeded;

        const frame = try takeFrame(provider, space, template);
        space.image_pages += 1;
        try copyFileBytes(provider, frame, bytes, seg, va);
        try writeNew(provider, pt, idx, frame, leafFlags(seg.flags));
    }
}

fn mapStack(
    provider: anytype,
    space: *AddressSpace,
    pd: u64,
    template: KernelTemplate,
) Error!void {
    var va: u64 = STACK_LO;
    while (va < STACK_TOP) : (va += PAGE) {
        if (pml4Index(va) != 0 or pdptIndex(va) != 1)
            return error.ImageOutOfRange;
        const pt = try ensurePt(provider, space, pd, va, .stack, template);
        const idx = ptIndex(va);
        const cur = try readEntry(provider, pt, idx);
        if (cur & PTE_P != 0) return error.MappingConflict;
        if (space.stack_pages >= MAX_STACK_PAGES) return error.BudgetExceeded;
        const frame = try takeFrame(provider, space, template);
        space.stack_pages += 1;
        try writeNew(provider, pt, idx, frame, PTE_P | PTE_U | PTE_W | PTE_NX);
    }
}

const PtKind = enum { image, stack };

fn ensurePt(
    provider: anytype,
    space: *AddressSpace,
    pd: u64,
    va: u64,
    kind: PtKind,
    template: KernelTemplate,
) Error!u64 {
    const idx = pdIndex(va);
    const cur = try readEntry(provider, pd, idx);
    if (cur & PTE_P != 0) {
        if (cur & PTE_PS != 0) return error.MappingConflict;
        const pt = cur & PTE_ADDR;
        if (pt == 0) return error.PhysicalZero;
        if (pt % PAGE != 0) return error.FrameUnaligned;
        if (pt >= PHYS_TOP) return error.FrameOutOfDomain;
        if (!space.journal.contains(pt)) return error.ReservedFrame;
        return pt;
    }
    switch (kind) {
        .image => if (space.image_pts >= MAX_IMAGE_PTS) return error.BudgetExceeded,
        .stack => if (space.stack_pts >= MAX_STACK_PTS) return error.BudgetExceeded,
    }
    const pt = try takeFrame(provider, space, template);
    space.table_pages += 1;
    switch (kind) {
        .image => space.image_pts += 1,
        .stack => space.stack_pts += 1,
    }
    try writeNew(provider, pd, idx, pt, PTE_P | PTE_W | PTE_U);
    return pt;
}

fn leafFlags(elf_flags: u32) u64 {
    var f: u64 = PTE_P | PTE_U;
    if ((elf_flags & user_elf.PF_W) != 0) {
        f |= PTE_W | PTE_NX;
    } else if ((elf_flags & user_elf.PF_X) != 0) {
        // RX: W=0, NX=0
    } else {
        f |= PTE_NX;
    }
    return f;
}

fn copyFileBytes(
    provider: anytype,
    frame: u64,
    bytes: []const u8,
    seg: user_elf.Segment,
    page_va: u64,
) Error!void {
    const page_lo = page_va;
    const page_hi = page_va + PAGE;
    const file_lo = seg.vaddr;
    const file_hi = seg.vaddr + seg.filesz;
    const copy_lo = @max(file_lo, page_lo);
    const copy_hi = @min(file_hi, page_hi);
    if (copy_lo >= copy_hi) return;

    const page_off: usize = @intCast(copy_lo - page_lo);
    const va_off = copy_lo - seg.vaddr;
    const file_off = std.math.add(u64, seg.file_off, va_off) catch
        return error.CopyFailed;
    const len_u = copy_hi - copy_lo;
    const copy_end = std.math.add(u64, file_off, len_u) catch
        return error.CopyFailed;
    if (copy_end > bytes.len) return error.CopyFailed;
    if (page_off + @as(usize, @intCast(len_u)) > PAGE) return error.CopyFailed;

    const page = provider.pageBytes(frame) catch return error.CopyFailed;
    const src_off: usize = @intCast(file_off);
    const len: usize = @intCast(len_u);
    @memcpy(page[page_off..][0..len], bytes[src_off..][0..len]);
}

fn writeBorrowedPdpt0(provider: anytype, pdpt: u64, template: KernelTemplate) Error!void {
    try validateTemplate(template);
    try writeRaw(provider, pdpt, 0, template.pdpt0_entry);
}

fn writeNew(provider: anytype, table: u64, index: usize, frame: u64, flags: u64) Error!void {
    if (frame == 0) return error.PhysicalZero;
    if (frame % PAGE != 0) return error.FrameUnaligned;
    if (frame >= PHYS_TOP) return error.FrameOutOfDomain;
    if (flags & PTE_PS != 0) return error.MappingConflict;
    if (flags & PTE_G != 0) return error.ReservedBits;
    const value = frame | flags;
    if (value & ~PTE_KNOWN != 0) return error.ReservedBits;
    try writeRaw(provider, table, index, value);
}

fn writeRaw(provider: anytype, table: u64, index: usize, value: u64) Error!void {
    if (index >= 512) return error.PageAccess;
    const page = provider.pageBytes(table) catch return error.PageAccess;
    storeU64(page, index, value);
}

fn readEntry(provider: anytype, table: u64, index: usize) Error!u64 {
    if (index >= 512) return error.PageAccess;
    const page = provider.pageBytes(table) catch return error.PageAccess;
    return loadU64(page, index);
}

fn releaseAll(provider: anytype, space: *AddressSpace) error{ReleaseFailed}!void {
    const released_mark: u64 = 0;
    var fail: ?u64 = null;
    var i = space.journal.count;
    while (i > 0) {
        i -= 1;
        const phys = space.journal.frames[i];
        scrub(provider, phys);
        if (provider.freePage(phys)) {
            space.journal.frames[i] = released_mark;
        } else if (fail == null) {
            fail = phys;
        }
    }
    var w: usize = 0;
    var r: usize = 0;
    while (r < space.journal.count) : (r += 1) {
        const phys = space.journal.frames[r];
        if (phys != released_mark) {
            space.journal.frames[w] = phys;
            w += 1;
        }
    }
    space.journal.count = w;

    if (space.owns_zero) {
        // Frame 0 is never scrubbed or translated through pageBytes.
        if (provider.freePage(0)) {
            space.owns_zero = false;
        } else if (fail == null) {
            fail = 0;
        }
    }

    if (fail) |f| {
        space.failed_release_frame = f;
        return error.ReleaseFailed;
    }
    space.failed_release_frame = 0;
}

fn scrub(provider: anytype, phys: u64) void {
    if (phys == 0) return;
    const page = provider.pageBytes(phys) catch return;
    @memset(page, 0);
}

fn clearCounts(space: *AddressSpace) void {
    space.image_pages = 0;
    space.stack_pages = 0;
    space.table_pages = 0;
    space.image_pts = 0;
    space.stack_pts = 0;
    space.failed_release_frame = 0;
    space.owns_zero = false;
}

fn plansEqual(a: user_elf.Plan, b: user_elf.Plan) bool {
    if (a.entry != b.entry) return false;
    if (a.segment_count != b.segment_count) return false;
    var i: u8 = 0;
    while (i < a.segment_count) : (i += 1) {
        const x = a.segments[i];
        const y = b.segments[i];
        if (x.file_off != y.file_off or x.filesz != y.filesz or
            x.vaddr != y.vaddr or x.memsz != y.memsz or x.flags != y.flags or
            x.byte_end != y.byte_end or x.map_start != y.map_start or
            x.map_end != y.map_end)
            return false;
    }
    return true;
}

fn loadU64(page: *const [PAGE]u8, index: usize) u64 {
    var tmp: [8]u8 = undefined;
    @memcpy(&tmp, page[index * 8 ..][0..8]);
    return std.mem.readInt(u64, &tmp, .little);
}

fn storeU64(page: *[PAGE]u8, index: usize, value: u64) void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, value, .little);
    @memcpy(page[index * 8 ..][0..8], &tmp);
}

fn mapAllocErr(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PhysicalZero => error.PhysicalZero,
        error.FrameUnaligned => error.FrameUnaligned,
        error.FrameOutOfDomain => error.FrameOutOfDomain,
        error.DuplicateFrame => error.DuplicateFrame,
        error.ReservedFrame => error.ReservedFrame,
        else => error.OutOfMemory,
    };
}

fn cr3Root(cr3: u64) u64 {
    return cr3 & CR3_ADDR;
}

fn pml4Index(va: u64) usize {
    return @intCast((va >> 39) & 0x1FF);
}

fn pdptIndex(va: u64) usize {
    return @intCast((va >> 30) & 0x1FF);
}

fn pdIndex(va: u64) usize {
    return @intCast((va >> 21) & 0x1FF);
}

fn ptIndex(va: u64) usize {
    return @intCast((va >> 12) & 0x1FF);
}
