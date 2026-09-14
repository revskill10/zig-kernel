// tests/native-user/vm_check.zig — hosted KWP3a.2a construction gate.
// Independent walker (effective U/W/NX across all levels) and owned-frame
// live-set oracle. Memory-backed synthetic physical IDs; never @ptrFromInt
// on fixture IDs. No privileged instructions, no CR3, no CPL3 claim.

const std = @import("std");
const vm = @import("user_vm");
const elf = @import("user_elf");

const PAGE: u64 = vm.PAGE;
const HUGE: u64 = vm.HUGE;
const IMAGE_LO: u64 = elf.IMAGE_LO;
const P: u64 = vm.PTE_P;
const W: u64 = vm.PTE_W;
const U: u64 = vm.PTE_U;
const PS: u64 = vm.PTE_PS;
const NX: u64 = vm.PTE_NX;
const ADDR: u64 = vm.PTE_ADDR;

const K_ROOT: u64 = 0x00200000;
const K_PD: u64 = 0x00300000;
const K_PT: u64 = 0x00301000;

const TestProvider = struct {
    pages: [][PAGE]u8,
    phys: []u64,
    used: []bool,
    slots: usize,
    alloc_n: usize = 0,
    access_n: usize = 0,
    fail_alloc_at: ?usize = null,
    fail_access_at: ?usize = null,
    fail_free: bool = false,
    fail_free_phys: ?u64 = null,
    fail_scrub: bool = false,
    free_calls: usize = 0,
    unexpected_free: usize = 0,
    next_phys: u64 = 0x01000000,
    return_zero: bool = false,
    always_zero: bool = false,
    return_zero_at: ?usize = null,
    zero_live: bool = false,
    zero_accesses: usize = 0,
    return_unaligned: bool = false,
    return_high: bool = false,
    return_dup: ?u64 = null,
    dup_at: ?usize = null,
    return_reserved: ?u64 = null,
    scribble_huge: bool = false,
    borrowed_phys: [4]u64 = [_]u64{0} ** 4,
    borrowed_page: [4]?*[PAGE]u8 = [_]?*[PAGE]u8{null} ** 4,
    borrowed_n: usize = 0,

    fn registerBorrowed(self: *TestProvider, phys: u64, page: *[PAGE]u8) void {
        self.borrowed_phys[self.borrowed_n] = phys;
        self.borrowed_page[self.borrowed_n] = page;
        self.borrowed_n += 1;
    }

    pub fn allocPage(self: *TestProvider) vm.AllocError!u64 {
        const n = self.alloc_n;
        self.alloc_n += 1;
        if (self.fail_alloc_at) |f| {
            if (n == f) return error.OutOfMemory;
        }
        if (self.always_zero or self.return_zero or (self.return_zero_at != null and n == self.return_zero_at.?)) {
            if (self.return_zero) self.return_zero = false;
            if (self.return_zero_at != null and n == self.return_zero_at.?) self.return_zero_at = null;
            self.zero_live = true;
            return 0;
        }
        if (self.return_unaligned) {
            self.return_unaligned = false;
            return 0x1001;
        }
        if (self.return_high) {
            self.return_high = false;
            return vm.PHYS_TOP;
        }
        if (self.return_dup) |d| {
            self.return_dup = null;
            return d;
        }
        if (self.dup_at) |d| {
            if (n == d) {
                var di: usize = 0;
                while (di < self.slots) : (di += 1) {
                    if (self.used[di]) return self.phys[di];
                }
            }
        }
        if (self.return_reserved) |r| {
            self.return_reserved = null;
            return r;
        }
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (!self.used[i]) {
                self.used[i] = true;
                const p = self.next_phys;
                self.next_phys += PAGE;
                if (self.next_phys >= vm.PHYS_TOP) return error.FrameOutOfDomain;
                self.phys[i] = p;
                @memset(self.pages[i][0..], 0xA5);
                return p;
            }
        }
        return error.OutOfMemory;
    }

    pub fn pageBytes(self: *TestProvider, phys: u64) vm.AccessError!*[PAGE]u8 {
        const n = self.access_n;
        self.access_n += 1;
        if (self.fail_scrub) return error.PageAccess;
        if (self.fail_access_at) |f| {
            if (n == f) return error.PageAccess;
        }
        if (phys == 0) {
            self.zero_accesses += 1;
            return error.PhysicalZero;
        }
        const page = self.lookup(phys) orelse return error.NotOwnedFrame;
        if (self.scribble_huge) {
            storeU64(page, 0, P | PS | W);
        }
        return page;
    }

    pub fn lookup(self: *TestProvider, phys: u64) ?*[PAGE]u8 {
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (self.used[i] and self.phys[i] == phys) return &self.pages[i];
        }
        var b: usize = 0;
        while (b < self.borrowed_n) : (b += 1) {
            if (self.borrowed_phys[b] == phys) return self.borrowed_page[b].?;
        }
        return null;
    }

    fn peek(self: *const TestProvider, phys: u64) ?*[PAGE]u8 {
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (self.used[i] and self.phys[i] == phys) return @constCast(&self.pages[i]);
        }
        var b: usize = 0;
        while (b < self.borrowed_n) : (b += 1) {
            if (self.borrowed_phys[b] == phys) return self.borrowed_page[b].?;
        }
        return null;
    }

    pub fn freePage(self: *TestProvider, phys: u64) bool {
        self.free_calls += 1;
        if (self.fail_free) return false;
        if (self.fail_free_phys) |f| {
            if (phys == f) return false;
        }
        if (phys == 0) {
            if (!self.zero_live) {
                self.unexpected_free += 1;
                return false;
            }
            self.zero_live = false;
            return true;
        }
        var b: usize = 0;
        while (b < self.borrowed_n) : (b += 1) {
            if (self.borrowed_phys[b] == phys) return false;
        }
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (self.used[i] and self.phys[i] == phys) {
                self.used[i] = false;
                @memset(self.pages[i][0..], 0xA5);
                return true;
            }
        }
        self.unexpected_free += 1;
        return false;
    }

    fn liveCount(self: *const TestProvider) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (self.used[i]) n += 1;
        }
        if (self.zero_live) n += 1;
        return n;
    }

    fn liveSnap(self: *const TestProvider, out: []u64) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (self.used[i]) {
                out[n] = self.phys[i];
                n += 1;
            }
        }
        if (self.zero_live) {
            out[n] = 0;
            n += 1;
        }
        return n;
    }
};

const Walk = struct {
    present: bool = false,
    huge: bool = false,
    phys: u64 = 0,
    u: bool = false,
    w: bool = false,
    nx: bool = false,
};

fn readPte(prov: *const TestProvider, table: u64, index: usize) !u64 {
    const page = prov.peek(table) orelse return error.PageAccess;
    return loadU64(page, index);
}

fn walk(prov: *const TestProvider, root: u64, va: u64) !Walk {
    const e4 = try readPte(prov, root, @intCast((va >> 39) & 0x1FF));
    if (e4 & P == 0) return .{};
    if (e4 & PS != 0) return error.UnexpectedHuge;
    var user = e4 & U != 0;
    var wr = e4 & W != 0;
    var nx = e4 & NX != 0;

    const e3 = try readPte(prov, e4 & ADDR, @intCast((va >> 30) & 0x1FF));
    if (e3 & P == 0) return .{};
    user = user and (e3 & U != 0);
    wr = wr and (e3 & W != 0);
    nx = nx or (e3 & NX != 0);
    if (e3 & PS != 0) {
        return .{ .present = true, .huge = true, .phys = e3 & 0x000F_FFFF_FFE0_0000, .u = user, .w = wr, .nx = nx };
    }

    const e2 = try readPte(prov, e3 & ADDR, @intCast((va >> 21) & 0x1FF));
    if (e2 & P == 0) return .{};
    user = user and (e2 & U != 0);
    wr = wr and (e2 & W != 0);
    nx = nx or (e2 & NX != 0);
    if (e2 & PS != 0) {
        return .{ .present = true, .huge = true, .phys = e2 & 0x000F_FFFF_FFE0_0000, .u = user, .w = wr, .nx = nx };
    }

    const e1 = try readPte(prov, e2 & ADDR, @intCast((va >> 12) & 0x1FF));
    if (e1 & P == 0) return .{};
    user = user and (e1 & U != 0);
    wr = wr and (e1 & W != 0);
    nx = nx or (e1 & NX != 0);
    return .{ .present = true, .huge = false, .phys = e1 & ADDR, .u = user, .w = wr, .nx = nx };
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

fn w8(buf: []u8, off: usize, v: u8) void {
    buf[off] = v;
}
fn w16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}
fn w32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}
fn w64(buf: []u8, off: usize, v: u64) void {
    var i: usize = 0;
    var x = v;
    while (i < 8) : (i += 1) {
        buf[off + i] = @truncate(x);
        x >>= 8;
    }
}

const EHDR: usize = elf.EHDR_SIZE;
const PHDR: usize = elf.PHDR_SIZE;

fn phAt(index: usize) usize {
    return EHDR + index * PHDR;
}

fn writeEhdr(buf: []u8, entry: u64, phnum: u16) void {
    @memcpy(buf[0..4], "\x7fELF");
    w8(buf, 4, elf.ELFCLASS64);
    w8(buf, 5, elf.ELFDATA2LSB);
    w8(buf, 6, elf.EV_CURRENT);
    w8(buf, 7, elf.ELFOSABI_NONE);
    w8(buf, 8, 0);
    w16(buf, 16, elf.ET_EXEC);
    w16(buf, 18, elf.EM_X86_64);
    w32(buf, 20, 1);
    w64(buf, 24, entry);
    w64(buf, 32, EHDR);
    w32(buf, 48, 0);
    w16(buf, 52, elf.EHDR_SIZE);
    w16(buf, 54, elf.PHDR_SIZE);
    w16(buf, 56, phnum);
}

fn writeLoad(buf: []u8, index: usize, flags: u32, off: u64, vaddr: u64, paddr: u64, filesz: u64, memsz: u64, palign: u64) void {
    const at = phAt(index);
    // Parser accepts 0/1 or a congruent power of two. Prefer 1 when the
    // caller omits a load alignment so unaligned vaddr/offset pairs stay valid.
    const align_out: u64 = if (palign == 0) 1 else palign;
    w32(buf, at + 0, elf.PT_LOAD);
    w32(buf, at + 4, flags);
    w64(buf, at + 8, off);
    w64(buf, at + 16, vaddr);
    w64(buf, at + 24, paddr);
    w64(buf, at + 32, filesz);
    w64(buf, at + 40, memsz);
    w64(buf, at + 48, align_out);
}

fn writeGnuStack(buf: []u8, index: usize) void {
    const at = phAt(index);
    w32(buf, at + 0, elf.PT_GNU_STACK);
    w32(buf, at + 4, elf.PF_R | elf.PF_W);
    w64(buf, at + 48, 16);
}

/// Tiny RX/RO/RW+BSS with non-page-aligned file/data and a one-page hole.
fn tinyImage(buf: *[0x4000]u8) []u8 {
    @memset(buf, 0);
    writeEhdr(buf, IMAGE_LO + 0x10, 4);
    writeLoad(buf, 0, elf.PF_R | elf.PF_X, 0x1010, IMAGE_LO + 0x10, 0x11110000, 0x200, 0x200, 0);
    writeLoad(buf, 1, elf.PF_R, 0x2020, IMAGE_LO + 2 * PAGE + 0x20, 0, 0x100, 0x100, 0);
    writeLoad(buf, 2, elf.PF_R | elf.PF_W, 0x3030, IMAGE_LO + 3 * PAGE + 0x30, 0, 0x50, 0x200, 0);
    writeGnuStack(buf, 3);
    buf[0x100F] = 0xFF; // adjacent file byte must not enter RX slack
    buf[0x1010] = 0x90;
    buf[0x1010 + 0x1FF] = 0xC3;
    buf[0x201F] = 0xEE;
    buf[0x2020] = 0x42;
    buf[0x302F] = 0xDD;
    buf[0x3030] = 0x55;
    return buf[0..0x4000];
}

fn boundaryImage(buf: *[0x800]u8) []u8 {
    @memset(buf, 0);
    const lo = IMAGE_LO + HUGE - PAGE;
    const hi = IMAGE_LO + HUGE;
    writeEhdr(buf, lo, 3);
    writeLoad(buf, 0, elf.PF_R | elf.PF_X, 0x200, lo, 0x9999, 0x20, 0x20, 0);
    writeLoad(buf, 1, elf.PF_R | elf.PF_W, 0x300, hi, 0, 0x10, PAGE, 0);
    writeGnuStack(buf, 2);
    buf[0x200] = 0x90;
    buf[0x300] = 0x77;
    return buf[0..0x800];
}

fn crossingImage(buf: *[0x2000]u8) []u8 {
    @memset(buf, 0);
    writeEhdr(buf, IMAGE_LO + 0xFF0, 2);
    writeLoad(buf, 0, elf.PF_R | elf.PF_X, 0x1000, IMAGE_LO + 0xFF0, 0, 0x20, 0x20, 0);
    writeGnuStack(buf, 1);
    var i: usize = 0;
    while (i < 0x20) : (i += 1) buf[0x1000 + i] = @truncate(0xA0 + i);
    return buf[0..0x2000];
}

fn sparseSpanImage(buf: *[0x800]u8) []u8 {
    @memset(buf, 0);
    const first = IMAGE_LO + HUGE - PAGE;
    const last = first + elf.MAX_IMAGE_SPAN - PAGE;
    writeEhdr(buf, first, 3);
    writeLoad(buf, 0, elf.PF_R | elf.PF_X, 0x200, first, 0, 0x10, 0x10, 0);
    writeLoad(buf, 1, elf.PF_R | elf.PF_W, 0x300, last, 0, 0, PAGE, 0);
    writeGnuStack(buf, 2);
    buf[0x200] = 0x90;
    return buf[0..0x800];
}

fn fillKernel(kpd: *[PAGE]u8, kpt: *[PAGE]u8) vm.KernelTemplate {
    @memset(kpd, 0);
    @memset(kpt, 0);
    storeU64(kpd, 0, 0 | P | W | PS);
    storeU64(kpd, 1, K_PT | P | W);
    storeU64(kpt, 0, 0x200000 | P | W | U);
    var j: usize = 1;
    while (j < 512) : (j += 1) {
        storeU64(kpt, j, (0x200000 + j * PAGE) | P | W);
    }
    storeU64(kpd, 2, 0x400000 | P | W | PS);
    storeU64(kpd, 4, 0x800000 | P | W | PS);
    return .{
        .root_phys = K_ROOT,
        .pdpt0_entry = K_PD | P | W | vm.PTE_A,
    };
}

fn bindKernel(prov: *TestProvider, kpd: *[PAGE]u8, kpt: *[PAGE]u8) void {
    prov.registerBorrowed(K_PD, kpd);
    prov.registerBorrowed(K_PT, kpt);
}

fn snapEq(a: []const u64, na: usize, b: []const u64, nb: usize) bool {
    if (na != nb) return false;
    var i: usize = 0;
    while (i < na) : (i += 1) {
        var found = false;
        var j: usize = 0;
        while (j < nb) : (j += 1) {
            if (a[i] == b[j]) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn unique(ids: []const u64) bool {
    var i: usize = 0;
    while (i < ids.len) : (i += 1) {
        var j = i + 1;
        while (j < ids.len) : (j += 1) {
            if (ids[i] == ids[j]) return false;
        }
    }
    return true;
}

fn pageContent(prov: *const TestProvider, root: u64, va: u64) !*[PAGE]u8 {
    const w = try walk(prov, root, va);
    try std.testing.expect(w.present and !w.huge);
    return prov.peek(w.phys) orelse error.PageAccess;
}

fn expectAbsent(prov: *const TestProvider, root: u64, va: u64) !void {
    const w = try walk(prov, root, va);
    try std.testing.expect(!w.present);
}

const Harness = struct {
    pages: [][PAGE]u8,
    phys: []u64,
    used: []bool,
    jbuf: []u64,
    kpd: [PAGE]u8,
    kpt: [PAGE]u8,
    kpd_snap: [PAGE]u8,
    kpt_snap: [PAGE]u8,
    prov: TestProvider,
    journal: vm.Journal,
    space: vm.AddressSpace,
    tmpl: vm.KernelTemplate,
    tmpl_perm: u64,

    fn init(n_pages: usize, jlen: usize) !Harness {
        const alloc = std.testing.allocator;
        var h: Harness = undefined;
        h.pages = try alloc.alignedAlloc([PAGE]u8, .fromByteUnits(4096), n_pages);
        errdefer alloc.free(h.pages);
        h.phys = try alloc.alloc(u64, n_pages);
        errdefer alloc.free(h.phys);
        h.used = try alloc.alloc(bool, n_pages);
        errdefer alloc.free(h.used);
        h.jbuf = try alloc.alloc(u64, jlen);
        errdefer alloc.free(h.jbuf);
        @memset(h.used, false);
        var pi: usize = 0;
        while (pi < n_pages) : (pi += 1) @memset(h.pages[pi][0..], 0xA5);
        h.kpd = [_]u8{0} ** PAGE;
        h.kpt = [_]u8{0} ** PAGE;
        h.kpd_snap = [_]u8{0} ** PAGE;
        h.kpt_snap = [_]u8{0} ** PAGE;
        h.prov = .{
            .pages = h.pages,
            .phys = h.phys,
            .used = h.used,
            .slots = n_pages,
        };
        h.journal = .{ .frames = h.jbuf, .count = 0 };
        h.space = .{ .journal = undefined };
        h.tmpl = .{ .root_phys = 0, .pdpt0_entry = 0 };
        h.tmpl_perm = 0;
        return h;
    }

    fn arm(h: *Harness) void {
        h.tmpl = fillKernel(&h.kpd, &h.kpt);
        h.tmpl_perm = h.tmpl.pdpt0AddrPerm();
        @memcpy(&h.kpd_snap, &h.kpd);
        @memcpy(&h.kpt_snap, &h.kpt);
        h.prov.borrowed_n = 0;
        bindKernel(&h.prov, &h.kpd, &h.kpt);
        h.journal = vm.Journal.init(h.jbuf);
        h.space = vm.AddressSpace.init(&h.journal);
    }

    fn deinit(h: *Harness) void {
        const alloc = std.testing.allocator;
        alloc.free(h.jbuf);
        alloc.free(h.used);
        alloc.free(h.phys);
        alloc.free(h.pages);
    }

    fn kernelUnchanged(h: *const Harness) !void {
        try std.testing.expectEqualSlices(u8, h.kpd_snap[0..], h.kpd[0..]);
        try std.testing.expectEqualSlices(u8, h.kpt_snap[0..], h.kpt[0..]);
        try std.testing.expectEqual(h.tmpl_perm, h.tmpl.pdpt0AddrPerm());
    }
};

fn checkTiny(h: *Harness, img: []const u8) !void {
    const root = h.space.root_phys;
    try std.testing.expectEqual(IMAGE_LO + 0x10, h.space.entry);
    try std.testing.expectEqual(vm.STACK_TOP, h.space.stack_top);
    try std.testing.expectEqual(@as(u32, 3), h.space.image_pages);
    try std.testing.expectEqual(@as(u32, 16), h.space.stack_pages);
    try std.testing.expectEqual(@as(u32, 1), h.space.image_pts);
    try std.testing.expectEqual(@as(u32, 1), h.space.stack_pts);
    try std.testing.expectEqual(@as(u32, 5), h.space.table_pages);
    try std.testing.expectEqual(
        h.space.image_pages + h.space.stack_pages + h.space.table_pages,
        @as(u32, @intCast(h.space.ownedCount())),
    );
    try std.testing.expect(unique(h.journal.frames[0..h.journal.count]));

    const rx = try walk(&h.prov, root, IMAGE_LO);
    try std.testing.expect(rx.present and rx.u and !rx.w and !rx.nx and !rx.huge);
    const hole = try walk(&h.prov, root, IMAGE_LO + PAGE);
    try std.testing.expect(!hole.present);
    const ro = try walk(&h.prov, root, IMAGE_LO + 2 * PAGE);
    try std.testing.expect(ro.present and ro.u and !ro.w and ro.nx);
    const rw = try walk(&h.prov, root, IMAGE_LO + 3 * PAGE);
    try std.testing.expect(rw.present and rw.u and rw.w and rw.nx);

    const rxp = try pageContent(&h.prov, root, IMAGE_LO);
    try std.testing.expectEqual(@as(u8, 0), rxp[0]);
    try std.testing.expectEqual(@as(u8, 0), rxp[0x0F]);
    try std.testing.expectEqual(@as(u8, 0x90), rxp[0x10]);
    try std.testing.expectEqual(@as(u8, 0xC3), rxp[0x10 + 0x1FF]);
    try std.testing.expectEqual(@as(u8, 0), rxp[0x10 + 0x200]);
    try std.testing.expect(rxp[0x0F] != 0xFF);

    const rop = try pageContent(&h.prov, root, IMAGE_LO + 2 * PAGE);
    try std.testing.expectEqual(@as(u8, 0), rop[0]);
    try std.testing.expectEqual(@as(u8, 0x42), rop[0x20]);
    try std.testing.expectEqual(@as(u8, 0), rop[0x20 + 0x100]);

    const rwp = try pageContent(&h.prov, root, IMAGE_LO + 3 * PAGE);
    try std.testing.expectEqual(@as(u8, 0), rwp[0]);
    try std.testing.expectEqual(@as(u8, 0x55), rwp[0x30]);
    try std.testing.expectEqual(@as(u8, 0), rwp[0x30 + 0x50]);
    try std.testing.expectEqual(@as(u8, 0), rwp[0x30 + 0x1FF]);

    var s: u64 = vm.STACK_LO;
    while (s < vm.STACK_TOP) : (s += PAGE) {
        const st = try walk(&h.prov, root, s);
        try std.testing.expect(st.present and st.u and st.w and st.nx and !st.huge);
        const sp = try pageContent(&h.prov, root, s);
        var z: usize = 0;
        while (z < PAGE) : (z += 1) try std.testing.expectEqual(@as(u8, 0), sp[z]);
    }
    try expectAbsent(&h.prov, root, vm.STACK_GUARD);
    try expectAbsent(&h.prov, root, vm.STACK_TOP);
    try expectAbsent(&h.prov, root, IMAGE_LO + 4 * PAGE);

    const k0 = try walk(&h.prov, root, 0);
    try std.testing.expect(k0.present and k0.huge and !k0.u);
    const kcode = try walk(&h.prov, root, 0x200000);
    try std.testing.expect(kcode.present and !kcode.u and !kcode.huge);
    const kcode2 = try walk(&h.prov, root, 0x201000);
    try std.testing.expect(kcode2.present and !kcode2.u);
    const kstack = try walk(&h.prov, root, 0x500000);
    try std.testing.expect(kstack.present and kstack.huge and !kstack.u);
    const kdata = try walk(&h.prov, root, 0x800000);
    try std.testing.expect(kdata.present and kdata.huge and !kdata.u);

    const pml4p = h.prov.peek(root) orelse return error.PageAccess;
    var i: usize = 1;
    while (i < 512) : (i += 1) try std.testing.expectEqual(@as(u64, 0), loadU64(pml4p, i));
    const e4 = loadU64(pml4p, 0);
    try std.testing.expect(e4 & U != 0);
    try std.testing.expect(e4 & NX == 0);
    const pdpt = e4 & ADDR;
    const pdptp = h.prov.peek(pdpt) orelse return error.PageAccess;
    try std.testing.expectEqual(h.tmpl.pdpt0_entry, loadU64(pdptp, 0));
    try std.testing.expect(loadU64(pdptp, 0) & U == 0);
    var pi: usize = 2;
    while (pi < 512) : (pi += 1) try std.testing.expectEqual(@as(u64, 0), loadU64(pdptp, pi));

    _ = img;
    try h.kernelUnchanged();
}

test "tiny RX/RO/RW+BSS unaligned slack hole stack and kernel U=0" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try checkTiny(&h, img);
    try vm.destroy(&h.prov, &h.space, .inactive);
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    try h.kernelUnchanged();
}

test "image 2MiB boundary uses independent PTs and unique frames" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x800]u8 = undefined;
    const img = boundaryImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try std.testing.expectEqual(@as(u32, 2), h.space.image_pages);
    try std.testing.expectEqual(@as(u32, 2), h.space.image_pts);
    try std.testing.expectEqual(@as(u32, 1), h.space.stack_pts);
    try std.testing.expectEqual(
        @as(usize, 2 + 16 + 3 + 2 + 1),
        h.space.ownedCount(),
    );
    try std.testing.expect(unique(h.journal.frames[0..h.journal.count]));
    const a = try walk(&h.prov, h.space.root_phys, IMAGE_LO + HUGE - PAGE);
    const b = try walk(&h.prov, h.space.root_phys, IMAGE_LO + HUGE);
    try std.testing.expect(a.present and a.u and !a.w and !a.nx);
    try std.testing.expect(b.present and b.u and b.w and b.nx);
    try std.testing.expect(a.phys != b.phys);
    try vm.destroy(&h.prov, &h.space, .inactive);
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
}

test "page-crossing file bytes stay in declared overlap" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x2000]u8 = undefined;
    const img = crossingImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    const p0 = try pageContent(&h.prov, h.space.root_phys, IMAGE_LO);
    const p1 = try pageContent(&h.prov, h.space.root_phys, IMAGE_LO + PAGE);
    var i: usize = 0;
    while (i < 0xFF0) : (i += 1) try std.testing.expectEqual(@as(u8, 0), p0[i]);
    i = 0;
    while (i < 0x10) : (i += 1) try std.testing.expectEqual(@as(u8, @truncate(0xA0 + i)), p0[0xFF0 + i]);
    i = 0;
    while (i < 0x10) : (i += 1) try std.testing.expectEqual(@as(u8, @truncate(0xB0 + i)), p1[i]);
    i = 0x10;
    while (i < PAGE) : (i += 1) try std.testing.expectEqual(@as(u8, 0), p1[i]);
    try vm.destroy(&h.prov, &h.space, .inactive);
}

test "sparse 32MiB span two pages independent PTs under budget" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x800]u8 = undefined;
    const img = sparseSpanImage(&buf);
    const plan = try elf.plan(img);
    try std.testing.expectEqual(elf.MAX_IMAGE_SPAN, plan.segments[1].map_end - plan.segments[0].map_start);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try std.testing.expectEqual(@as(u32, 2), h.space.image_pages);
    try std.testing.expectEqual(@as(u32, 2), h.space.image_pts);
    try std.testing.expect(h.space.table_pages <= vm.MAX_TABLE_FRAMES);
    try std.testing.expect(h.space.ownedCount() <= vm.MAX_OWNED_FRAMES);
    try vm.destroy(&h.prov, &h.space, .inactive);
}

test "every allocation failure of the tiny fixture fully unwinds" {
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    var h0 = try Harness.init(48, 64);
    defer h0.deinit();
    h0.arm();
    try vm.construct(&h0.prov, img, h0.tmpl, &h0.space);
    const n_alloc = h0.prov.alloc_n;
    try vm.destroy(&h0.prov, &h0.space, .inactive);
    try std.testing.expect(n_alloc >= 24);

    var i: usize = 0;
    while (i < n_alloc) : (i += 1) {
        var h = try Harness.init(48, 64);
        defer h.deinit();
        h.arm();
        var base: [64]u64 = undefined;
        const nb = h.prov.liveSnap(&base);
        h.prov.fail_alloc_at = i;
        try std.testing.expectError(error.OutOfMemory, vm.construct(&h.prov, img, h.tmpl, &h.space));
        try std.testing.expectEqual(vm.State.empty, h.space.state);
        var after: [64]u64 = undefined;
        const na = h.prov.liveSnap(&after);
        try std.testing.expect(snapEq(base[0..nb], nb, after[0..na], na));
        try h.kernelUnchanged();
    }
}

test "every page-access failure of the tiny fixture fully unwinds" {
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    var h0 = try Harness.init(48, 64);
    defer h0.deinit();
    h0.arm();
    try vm.construct(&h0.prov, img, h0.tmpl, &h0.space);
    const n_acc = h0.prov.access_n;
    try vm.destroy(&h0.prov, &h0.space, .inactive);
    try std.testing.expect(n_acc > 10);

    var i: usize = 0;
    while (i < n_acc) : (i += 1) {
        var h = try Harness.init(48, 64);
        defer h.deinit();
        h.arm();
        var base: [64]u64 = undefined;
        const nb = h.prov.liveSnap(&base);
        h.prov.fail_access_at = i;
        const result = vm.construct(&h.prov, img, h.tmpl, &h.space);
        if (result) |_| {
            try std.testing.expect(i == n_acc);
            try vm.destroy(&h.prov, &h.space, .inactive);
        } else |err| {
            try std.testing.expect(err == error.PageAccess or err == error.CopyFailed);
            try std.testing.expectEqual(vm.State.empty, h.space.state);
            var after: [64]u64 = undefined;
            const na = h.prov.liveSnap(&after);
            try std.testing.expect(snapEq(base[0..nb], nb, after[0..na], na));
            try h.kernelUnchanged();
        }
    }
}

test "two build/destroy cycles with poisoned recycled frames" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try checkTiny(&h, img);
    try vm.destroy(&h.prov, &h.space, .inactive);
    try vm.reset(&h.space);
    var s: usize = 0;
    while (s < h.prov.slots) : (s += 1) {
        try std.testing.expect(!h.prov.used[s]);
        try std.testing.expectEqual(@as(u8, 0xA5), h.prov.pages[s][0]);
    }
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try checkTiny(&h, img);
    try vm.destroy(&h.prov, &h.space, .inactive);
}

test "active-root and duplicate destroy refuse to free" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    const live = h.prov.liveCount();
    const root = h.space.root_phys;
    try std.testing.expectError(error.ActiveRoot, vm.destroy(&h.prov, &h.space, .{ .cr3 = root }));
    try std.testing.expectEqual(vm.State.ready, h.space.state);
    try std.testing.expectEqual(live, h.prov.liveCount());
    try vm.destroy(&h.prov, &h.space, .inactive);
    try std.testing.expectError(error.DuplicateDestroy, vm.destroy(&h.prov, &h.space, .inactive));
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
}

test "journal capacity loss unwinds" {
    var h = try Harness.init(48, 4);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    var base: [64]u64 = undefined;
    const nb = h.prov.liveSnap(&base);
    try std.testing.expectError(error.JournalFull, vm.construct(&h.prov, img, h.tmpl, &h.space));
    var after: [64]u64 = undefined;
    const na = h.prov.liveSnap(&after);
    try std.testing.expect(snapEq(base[0..nb], nb, after[0..na], na));
    try std.testing.expectEqual(vm.State.empty, h.space.state);
}

test "provider release failure is explicit and not a restored baseline" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    const owned = h.space.ownedCount();
    try std.testing.expect(owned > 0);
    h.prov.fail_free = true;
    try std.testing.expectError(error.ReleaseFailed, vm.destroy(&h.prov, &h.space, .inactive));
    try std.testing.expectEqual(vm.State.destroyed, h.space.state);
    try std.testing.expectEqual(owned, h.space.ownedCount());
    try std.testing.expectEqual(owned, h.prov.liveCount());
    try std.testing.expect(h.space.failed_release_frame != 0);
    try std.testing.expectError(error.InvalidState, vm.reset(&h.space));
    try std.testing.expectError(error.InvalidState, vm.construct(&h.prov, img, h.tmpl, &h.space));
}

test "wrong template U/PS/presence/domain/align/zero rejected" {
    var h = try Harness.init(16, 16);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    const cases = [_]vm.KernelTemplate{
        .{ .root_phys = K_ROOT, .pdpt0_entry = K_PD | W },
        .{ .root_phys = K_ROOT, .pdpt0_entry = K_PD | P | W | U },
        .{ .root_phys = K_ROOT, .pdpt0_entry = K_PD | P | W | PS },
        .{ .root_phys = K_ROOT, .pdpt0_entry = 0x3001 | P | W },
        .{ .root_phys = K_ROOT, .pdpt0_entry = P | W },
        .{ .root_phys = K_ROOT, .pdpt0_entry = vm.PHYS_TOP | P | W },
        .{ .root_phys = 0, .pdpt0_entry = K_PD | P | W },
        .{ .root_phys = 1, .pdpt0_entry = K_PD | P | W },
        .{ .root_phys = vm.PHYS_TOP, .pdpt0_entry = K_PD | P | W },
        .{ .root_phys = K_PD, .pdpt0_entry = K_PD | P | W },
    };
    for (cases) |t| {
        var base: [16]u64 = undefined;
        const nb = h.prov.liveSnap(&base);
        if (vm.construct(&h.prov, img, t, &h.space)) |_| {
            try std.testing.expect(false);
        } else |_| {}
        var after: [16]u64 = undefined;
        const na = h.prov.liveSnap(&after);
        try std.testing.expect(snapEq(base[0..nb], nb, after[0..na], na));
        try std.testing.expectEqual(vm.State.empty, h.space.state);
    }
}

test "zero unaligned high duplicate and reserved provider frames" {
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);

    {
        var h = try Harness.init(48, 64);
        defer h.deinit();
        h.arm();
        h.prov.return_zero = true;
        try std.testing.expectError(error.PhysicalZero, vm.construct(&h.prov, img, h.tmpl, &h.space));
        try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    }
    {
        var h = try Harness.init(48, 64);
        defer h.deinit();
        h.arm();
        h.prov.return_unaligned = true;
        try std.testing.expectError(error.FrameUnaligned, vm.construct(&h.prov, img, h.tmpl, &h.space));
        try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    }
    {
        var h = try Harness.init(48, 64);
        defer h.deinit();
        h.arm();
        h.prov.return_high = true;
        try std.testing.expectError(error.FrameOutOfDomain, vm.construct(&h.prov, img, h.tmpl, &h.space));
        try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    }
    {
        var h = try Harness.init(48, 64);
        defer h.deinit();
        h.arm();
        h.prov.return_reserved = K_PD;
        try std.testing.expectError(error.ReservedFrame, vm.construct(&h.prov, img, h.tmpl, &h.space));
        try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
        try h.kernelUnchanged();
    }
    {
        var h = try Harness.init(48, 64);
        defer h.deinit();
        h.arm();
        h.prov.dup_at = 1;
        try std.testing.expectError(error.DuplicateFrame, vm.construct(&h.prov, img, h.tmpl, &h.space));
        try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    }
}

test "preexisting target is a mapping conflict and unwinds" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    h.prov.scribble_huge = true;
    var base: [64]u64 = undefined;
    const nb = h.prov.liveSnap(&base);
    try std.testing.expectError(error.MappingConflict, vm.construct(&h.prov, img, h.tmpl, &h.space));
    var after: [64]u64 = undefined;
    const na = h.prov.liveSnap(&after);
    try std.testing.expect(snapEq(base[0..nb], nb, after[0..na], na));
    try h.kernelUnchanged();
}

test "forged plan is rejected; constructor reparses ELF" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    var claimed = try elf.plan(img);
    claimed.segments[0].flags = elf.PF_R | elf.PF_W | elf.PF_X;
    try std.testing.expectError(error.PlanMismatch, vm.constructClaimedPlan(&h.prov, img, claimed, h.tmpl, &h.space));
    claimed = try elf.plan(img);
    claimed.segments[0].map_start = IMAGE_LO + PAGE;
    try std.testing.expectError(error.PlanMismatch, vm.constructClaimedPlan(&h.prov, img, claimed, h.tmpl, &h.space));
    claimed = try elf.plan(img);
    try vm.constructClaimedPlan(&h.prov, img, claimed, h.tmpl, &h.space);
    try checkTiny(&h, img);
    try vm.destroy(&h.prov, &h.space, .inactive);
}

test "bad ELF is a parser error with no allocations" {
    var h = try Harness.init(16, 16);
    defer h.deinit();
    h.arm();
    try std.testing.expectError(error.Truncated, vm.construct(&h.prov, &[_]u8{ 0x7f, 'E' }, h.tmpl, &h.space));
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
}

test "empty destroy is invalid; reuse requires reset" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    try std.testing.expectError(error.InvalidState, vm.destroy(&h.prov, &h.space, .inactive));
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try vm.destroy(&h.prov, &h.space, .inactive);
    try std.testing.expectError(error.InvalidState, vm.construct(&h.prov, img, h.tmpl, &h.space));
    try vm.reset(&h.space);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try vm.destroy(&h.prov, &h.space, .inactive);
}

test "tinyImage meets accepted ELF alignment contract" {
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    const plan = try elf.plan(img);
    try std.testing.expectEqual(@as(u8, 3), plan.segment_count);
    try std.testing.expectEqual(IMAGE_LO + 0x10, plan.entry);
}

test "CR3 PWT and PCD observations refuse destroy and keep live sets" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try checkTiny(&h, img);
    const live = h.prov.liveCount();
    const owned = h.space.ownedCount();
    const root = h.space.root_phys;
    var before: [64]u64 = undefined;
    const nb = h.prov.liveSnap(&before);

    try std.testing.expectError(error.ActiveRoot, vm.destroy(&h.prov, &h.space, .{ .cr3 = root | vm.CR3_PWT }));
    try std.testing.expectError(error.ActiveRoot, vm.destroy(&h.prov, &h.space, .{ .cr3 = root | vm.CR3_PCD }));
    try std.testing.expectError(error.ActiveRoot, vm.destroy(&h.prov, &h.space, .{ .cr3 = root | vm.CR3_PWT | vm.CR3_PCD }));
    try std.testing.expectEqual(vm.State.ready, h.space.state);
    try std.testing.expectEqual(live, h.prov.liveCount());
    try std.testing.expectEqual(owned, h.space.ownedCount());
    var after: [64]u64 = undefined;
    const na = h.prov.liveSnap(&after);
    try std.testing.expect(snapEq(before[0..nb], nb, after[0..na], na));
    try checkTiny(&h, img);

    const other = root + PAGE;
    try vm.destroy(&h.prov, &h.space, .{ .cr3 = other | vm.CR3_PWT });
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    try std.testing.expectEqual(@as(usize, 0), h.space.ownedCount());
}

test "release refusal retains every unreleased frame; reset refused; retry does not double-free" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    const owned = h.space.ownedCount();
    const refuse = h.journal.frames[0];
    h.prov.fail_free_phys = refuse;
    try std.testing.expectError(error.ReleaseFailed, vm.destroy(&h.prov, &h.space, .inactive));
    try std.testing.expectEqual(vm.State.destroyed, h.space.state);
    try std.testing.expectEqual(@as(usize, 1), h.space.ownedCount());
    try std.testing.expectEqual(@as(usize, 1), h.prov.liveCount());
    try std.testing.expectEqual(refuse, h.space.failed_release_frame);
    try std.testing.expectEqual(refuse, h.journal.frames[0]);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);
    try std.testing.expectError(error.InvalidState, vm.reset(&h.space));
    try std.testing.expectError(error.DuplicateDestroy, vm.destroy(&h.prov, &h.space, .inactive));
    try std.testing.expectEqual(@as(usize, 1), h.space.ownedCount());

    const calls_before_retry = h.prov.free_calls;
    try std.testing.expectError(error.ReleaseFailed, vm.retryRelease(&h.prov, &h.space));
    try std.testing.expectEqual(calls_before_retry + 1, h.prov.free_calls);
    try std.testing.expectEqual(@as(usize, 1), h.space.ownedCount());
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);

    h.prov.fail_free_phys = null;
    try vm.retryRelease(&h.prov, &h.space);
    try std.testing.expectEqual(@as(usize, 0), h.space.ownedCount());
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);
    try vm.reset(&h.space);
    try std.testing.expectEqual(vm.State.empty, h.space.state);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try std.testing.expectEqual(owned, h.space.ownedCount());
    try vm.destroy(&h.prov, &h.space, .inactive);
}

test "construction unwind retains ownership when provider refuses release" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    h.prov.fail_alloc_at = 5;
    h.prov.fail_free = true;
    try std.testing.expectError(error.ReleaseFailed, vm.construct(&h.prov, img, h.tmpl, &h.space));
    try std.testing.expectEqual(vm.State.destroyed, h.space.state);
    try std.testing.expect(h.space.ownedCount() > 0);
    try std.testing.expectEqual(h.space.ownedCount(), h.prov.liveCount());
    try std.testing.expectError(error.InvalidState, vm.reset(&h.space));
    var i: usize = 0;
    while (i < h.space.ownedCount()) : (i += 1) {
        try std.testing.expect(h.prov.lookup(h.journal.frames[i]) != null);
    }

    h.prov.fail_free = false;
    try vm.retryRelease(&h.prov, &h.space);
    try std.testing.expectEqual(@as(usize, 0), h.space.ownedCount());
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    try vm.reset(&h.space);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try vm.destroy(&h.prov, &h.space, .inactive);
}

test "construction unwind preserves original error when release succeeds" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    var base: [64]u64 = undefined;
    const nb = h.prov.liveSnap(&base);
    h.prov.fail_alloc_at = 5;
    try std.testing.expectError(error.OutOfMemory, vm.construct(&h.prov, img, h.tmpl, &h.space));
    try std.testing.expectEqual(vm.State.empty, h.space.state);
    try std.testing.expectEqual(@as(usize, 0), h.space.ownedCount());
    var after: [64]u64 = undefined;
    const na = h.prov.liveSnap(&after);
    try std.testing.expect(snapEq(base[0..nb], nb, after[0..na], na));
}

test "multiple release refusals retain all identities" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    var snap: [64]u64 = undefined;
    const n = h.prov.liveSnap(&snap);
    try std.testing.expectEqual(n, h.space.ownedCount());
    h.prov.fail_free = true;
    try std.testing.expectError(error.ReleaseFailed, vm.destroy(&h.prov, &h.space, .inactive));
    try std.testing.expectEqual(n, h.space.ownedCount());
    try std.testing.expectEqual(n, h.prov.liveCount());
    try std.testing.expect(unique(h.journal.frames[0..h.space.ownedCount()]));
    var after: [64]u64 = undefined;
    const na = h.prov.liveSnap(&after);
    try std.testing.expect(snapEq(snap[0..n], n, after[0..na], na));
    try std.testing.expect(h.journal.contains(h.space.failed_release_frame));
    try std.testing.expectError(error.InvalidState, vm.reset(&h.space));
}

test "scrub access failure still frees owned frames" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try checkTiny(&h, img);
    h.prov.fail_scrub = true;
    try vm.destroy(&h.prov, &h.space, .inactive);
    try std.testing.expectEqual(@as(usize, 0), h.space.ownedCount());
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    try std.testing.expectEqual(vm.State.destroyed, h.space.state);
    try h.kernelUnchanged();
}

test "owned physical zero release refusal retains ownership and forbids reuse" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    h.prov.always_zero = true;
    h.prov.fail_free_phys = 0;

    try std.testing.expectError(error.ReleaseFailed, vm.construct(&h.prov, img, h.tmpl, &h.space));
    try std.testing.expectEqual(vm.State.destroyed, h.space.state);
    try std.testing.expect(h.space.owns_zero);
    try std.testing.expectEqual(@as(usize, 1), h.space.ownedCount());
    try std.testing.expectEqual(@as(usize, 0), h.journal.count);
    try std.testing.expectEqual(@as(u64, 0), h.space.failed_release_frame);
    try std.testing.expectEqual(@as(usize, 1), h.prov.alloc_n);
    try std.testing.expectEqual(@as(usize, 1), h.prov.liveCount());
    try std.testing.expect(h.prov.zero_live);
    try std.testing.expectEqual(@as(usize, 0), h.prov.zero_accesses);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);
    try std.testing.expectError(error.InvalidState, vm.reset(&h.space));

    const allocs_mid = h.prov.alloc_n;
    try std.testing.expectError(error.InvalidState, vm.construct(&h.prov, img, h.tmpl, &h.space));
    try std.testing.expectEqual(allocs_mid, h.prov.alloc_n);
    try std.testing.expectEqual(vm.State.destroyed, h.space.state);
    try std.testing.expect(h.space.owns_zero);
    try std.testing.expectEqual(@as(usize, 1), h.space.ownedCount());

    const frees_before = h.prov.free_calls;
    try std.testing.expectError(error.ReleaseFailed, vm.retryRelease(&h.prov, &h.space));
    try std.testing.expectEqual(frees_before + 1, h.prov.free_calls);
    try std.testing.expect(h.space.owns_zero);
    try std.testing.expectEqual(@as(usize, 1), h.space.ownedCount());
    try std.testing.expectEqual(@as(u64, 0), h.space.failed_release_frame);
    try std.testing.expectEqual(@as(usize, 0), h.prov.zero_accesses);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);

    h.prov.fail_free_phys = null;
    try vm.retryRelease(&h.prov, &h.space);
    try std.testing.expectEqual(@as(usize, 0), h.space.ownedCount());
    try std.testing.expect(!h.space.owns_zero);
    try std.testing.expectEqual(@as(u64, 0), h.space.failed_release_frame);
    try std.testing.expect(!h.prov.zero_live);
    try std.testing.expectEqual(@as(usize, 0), h.prov.zero_accesses);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);
    try vm.reset(&h.space);
    try std.testing.expectEqual(vm.State.empty, h.space.state);

    h.prov.always_zero = false;
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try std.testing.expect(h.space.ownedCount() > 0);
    try vm.destroy(&h.prov, &h.space, .inactive);
    try std.testing.expectEqual(@as(usize, 0), h.space.ownedCount());
}

test "physical zero after journaled frames refuses only zero and does not double-free others" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    h.prov.return_zero_at = 3;
    h.prov.fail_free_phys = 0;

    try std.testing.expectError(error.ReleaseFailed, vm.construct(&h.prov, img, h.tmpl, &h.space));
    try std.testing.expectEqual(vm.State.destroyed, h.space.state);
    try std.testing.expect(h.space.owns_zero);
    try std.testing.expectEqual(@as(usize, 1), h.space.ownedCount());
    try std.testing.expectEqual(@as(usize, 0), h.journal.count);
    try std.testing.expectEqual(@as(u64, 0), h.space.failed_release_frame);
    try std.testing.expectEqual(@as(usize, 4), h.prov.alloc_n);
    try std.testing.expectEqual(@as(usize, 1), h.prov.liveCount());
    try std.testing.expect(h.prov.zero_live);
    try std.testing.expectEqual(@as(usize, 0), h.prov.zero_accesses);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);
    try std.testing.expectError(error.InvalidState, vm.reset(&h.space));

    const allocs_mid = h.prov.alloc_n;
    try std.testing.expectError(error.InvalidState, vm.construct(&h.prov, img, h.tmpl, &h.space));
    try std.testing.expectEqual(allocs_mid, h.prov.alloc_n);

    const frees_before = h.prov.free_calls;
    try std.testing.expectError(error.ReleaseFailed, vm.retryRelease(&h.prov, &h.space));
    try std.testing.expectEqual(frees_before + 1, h.prov.free_calls);
    try std.testing.expectEqual(@as(usize, 1), h.space.ownedCount());
    try std.testing.expect(h.space.owns_zero);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);

    h.prov.fail_free_phys = null;
    try vm.retryRelease(&h.prov, &h.space);
    try std.testing.expectEqual(@as(usize, 0), h.space.ownedCount());
    try std.testing.expect(!h.space.owns_zero);
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    try std.testing.expectEqual(@as(usize, 0), h.prov.zero_accesses);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);
    try vm.reset(&h.space);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try std.testing.expect(h.space.ownedCount() > 1);
    try vm.destroy(&h.prov, &h.space, .inactive);
}

test "physical zero with prior frames retains every identity across repeated refusal" {
    var h = try Harness.init(48, 64);
    defer h.deinit();
    h.arm();
    var buf: [0x4000]u8 = undefined;
    const img = tinyImage(&buf);
    h.prov.return_zero_at = 4;
    h.prov.fail_free = true;

    try std.testing.expectError(error.ReleaseFailed, vm.construct(&h.prov, img, h.tmpl, &h.space));
    try std.testing.expectEqual(vm.State.destroyed, h.space.state);
    try std.testing.expect(h.space.owns_zero);
    try std.testing.expectEqual(@as(usize, 5), h.space.ownedCount());
    try std.testing.expectEqual(@as(usize, 4), h.journal.count);
    try std.testing.expect(unique(h.journal.frames[0..h.journal.count]));
    try std.testing.expect(h.space.failed_release_frame != 0);
    try std.testing.expect(h.journal.contains(h.space.failed_release_frame));
    try std.testing.expectEqual(@as(usize, 5), h.prov.liveCount());
    try std.testing.expectEqual(h.space.ownedCount(), h.prov.liveCount());
    var i: usize = 0;
    while (i < h.journal.count) : (i += 1) {
        try std.testing.expect(h.prov.lookup(h.journal.frames[i]) != null);
    }
    try std.testing.expectEqual(@as(usize, 0), h.prov.zero_accesses);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);
    try std.testing.expectError(error.InvalidState, vm.reset(&h.space));

    const allocs_mid = h.prov.alloc_n;
    try std.testing.expectError(error.InvalidState, vm.construct(&h.prov, img, h.tmpl, &h.space));
    try std.testing.expectEqual(allocs_mid, h.prov.alloc_n);

    const frees_before = h.prov.free_calls;
    try std.testing.expectError(error.ReleaseFailed, vm.retryRelease(&h.prov, &h.space));
    try std.testing.expectEqual(frees_before + 5, h.prov.free_calls);
    try std.testing.expectEqual(@as(usize, 5), h.space.ownedCount());
    try std.testing.expectEqual(@as(usize, 4), h.journal.count);
    try std.testing.expect(h.space.owns_zero);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);

    h.prov.fail_free = false;
    try vm.retryRelease(&h.prov, &h.space);
    try std.testing.expectEqual(@as(usize, 0), h.space.ownedCount());
    try std.testing.expect(!h.space.owns_zero);
    try std.testing.expectEqual(@as(usize, 0), h.prov.liveCount());
    try std.testing.expectEqual(@as(usize, 0), h.prov.zero_accesses);
    try std.testing.expectEqual(@as(usize, 0), h.prov.unexpected_free);
    try vm.reset(&h.space);
    try vm.construct(&h.prov, img, h.tmpl, &h.space);
    try vm.destroy(&h.prov, &h.space, .inactive);
}
