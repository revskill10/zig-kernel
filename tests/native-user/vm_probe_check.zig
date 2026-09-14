// tests/native-user/vm_probe_check.zig — hosted fixture/planner/walker and
// CR3 masking checks. Not guest execution and not a call of privileged
// switch helpers.

const std = @import("std");
const elf = @import("user_elf");
const vm = @import("user_vm");
const fixture = @import("vm_probe_fixture");
const vm_cr3 = @import("vm_cr3");
const probe = @import("vm_probe");

const PAGE: u64 = vm.PAGE;
const P: u64 = vm.PTE_P;
const W: u64 = vm.PTE_W;
const U: u64 = vm.PTE_U;
const NX: u64 = vm.PTE_NX;
const ADDR: u64 = vm.PTE_ADDR;

const K_ROOT: u64 = 0x00200000;
const K_PD: u64 = 0x00300000;

const TestProvider = struct {
    pages: [][PAGE]u8,
    phys: []u64,
    used: []bool,
    slots: usize,
    next_phys: u64 = 0x01000000,

    pub fn allocPage(self: *TestProvider) vm.AllocError!u64 {
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (!self.used[i]) {
                self.used[i] = true;
                const p = self.next_phys;
                self.next_phys += PAGE;
                self.phys[i] = p;
                @memset(&self.pages[i], 0);
                return p;
            }
        }
        return error.OutOfMemory;
    }

    pub fn pageBytes(self: *TestProvider, phys: u64) vm.AccessError!*[PAGE]u8 {
        if (phys == 0) return error.PhysicalZero;
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (self.used[i] and self.phys[i] == phys) return &self.pages[i];
        }
        return error.NotOwnedFrame;
    }

    pub fn freePage(self: *TestProvider, phys: u64) bool {
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (self.used[i] and self.phys[i] == phys) {
                self.used[i] = false;
                @memset(&self.pages[i], 0xA5);
                return true;
            }
        }
        return false;
    }

    fn peek(self: *const TestProvider, phys: u64) ?*[PAGE]u8 {
        var i: usize = 0;
        while (i < self.slots) : (i += 1) {
            if (self.used[i] and self.phys[i] == phys) return @constCast(&self.pages[i]);
        }
        return null;
    }
};

const Reader = struct {
    prov: *const TestProvider,
    pub fn load(self: @This(), phys: u64) u64 {
        const page_phys = phys & ~@as(u64, PAGE - 1);
        const off: usize = @intCast(phys & (PAGE - 1));
        const page = self.prov.peek(page_phys) orelse return 0;
        var tmp: [8]u8 = undefined;
        @memcpy(&tmp, page[off..][0..8]);
        return std.mem.readInt(u64, &tmp, .little);
    }
};

const BufStore = struct {
    pages: [][PAGE]u8,
    ids: []u64,
    n: usize = 0,

    fn add(self: *BufStore, phys: u64) *[PAGE]u8 {
        const i = self.n;
        self.n += 1;
        self.ids[i] = phys;
        @memset(&self.pages[i], 0);
        return &self.pages[i];
    }

    fn load(self: *const BufStore, phys: u64) u64 {
        const page_phys = phys & ~@as(u64, PAGE - 1);
        const off: usize = @intCast(phys & (PAGE - 1));
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.ids[i] == page_phys) {
                var tmp: [8]u8 = undefined;
                @memcpy(&tmp, self.pages[i][off..][0..8]);
                return std.mem.readInt(u64, &tmp, .little);
            }
        }
        return 0;
    }
};

const BufReader = struct {
    store: *const BufStore,
    pub fn load(self: @This(), phys: u64) u64 {
        return self.store.load(phys);
    }
};

fn storeU64(page: *[PAGE]u8, index: usize, value: u64) void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, value, .little);
    @memcpy(page[index * 8 ..][0..8], &tmp);
}

test "fixture plans as three nonoverlapping RX/RO/RW loads" {
    const p1 = try elf.plan(fixture.bytes(1));
    const p2 = try elf.plan(fixture.bytes(2));
    try std.testing.expectEqual(@as(u8, 3), p1.segment_count);
    try std.testing.expectEqual(p1.segment_count, p2.segment_count);
    try std.testing.expectEqual(fixture.ENTRY, p1.entry);
    try std.testing.expectEqual(elf.PF_R | elf.PF_X, p1.segments[0].flags);
    try std.testing.expectEqual(elf.PF_R, p1.segments[1].flags);
    try std.testing.expectEqual(elf.PF_R | elf.PF_W, p1.segments[2].flags);
    try std.testing.expectEqual(fixture.RX_VADDR, p1.segments[0].vaddr);
    try std.testing.expectEqual(fixture.RO_VADDR, p1.segments[1].vaddr);
    try std.testing.expectEqual(fixture.RW_VADDR, p1.segments[2].vaddr);
    try std.testing.expect(p1.segments[0].vaddr % PAGE != 0);
    try std.testing.expect(p1.segments[1].vaddr % PAGE != 0);
    try std.testing.expect(p1.segments[0].map_start < 0x40200000);
    try std.testing.expect(p1.segments[0].map_end > 0x40200000);
    try std.testing.expectEqual(@as(u8, fixture.RET), fixture.bytes(1)[fixture.RX_FILE_OFF]);
    try std.testing.expectEqual(@as(u8, fixture.RET), fixture.bytes(1)[fixture.RW_FILE_OFF]);
    try std.testing.expect(fixture.bytes(1)[fixture.RO_FILE_OFF] != fixture.bytes(2)[fixture.RO_FILE_OFF]);
}

test "cycle fixtures have distinct SHA256 and fixed length" {
    const h1 = fixture.sha256Hex(fixture.bytes(1));
    const h2 = fixture.sha256Hex(fixture.bytes(2));
    try std.testing.expectEqual(@as(usize, fixture.FIXTURE_LEN), fixture.bytes(1).len);
    try std.testing.expectEqual(@as(usize, 5120), fixture.bytes(1).len);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
    try std.testing.expectEqualStrings(fixture.CYCLE1_SHA256_HEX, &h1);
    try std.testing.expectEqualStrings(fixture.CYCLE2_SHA256_HEX, &h2);
    for (h1) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}

test "control-register address masking and frame validation" {
    const raw: u64 = 0x0000000000300000 | vm_cr3.CR3_PWT | vm_cr3.CR3_PCD | 0x7;
    try std.testing.expectEqual(@as(u64, 0x300000), vm_cr3.cr3Addr(raw));
    try std.testing.expectEqual(vm_cr3.CR3_PWT | vm_cr3.CR3_PCD, vm_cr3.cr3CacheFlags(raw));
    try std.testing.expect(vm_cr3.validateFrame(0x300000));
    try std.testing.expect(!vm_cr3.validateFrame(0));
    try std.testing.expect(!vm_cr3.validateFrame(0x300001));
    try std.testing.expect(!vm_cr3.validateFrame(vm_cr3.PHYS_TOP));
    try std.testing.expect(vm_cr3.interruptsMasked(0x2));
    try std.testing.expect(!vm_cr3.interruptsMasked(vm_cr3.RFLAGS_IF));
    try std.testing.expect(vm_cr3.writeProtectEnabled(vm_cr3.CR0_WP));
    try std.testing.expect(vm_cr3.nxeEnabled(vm_cr3.EFER_NXE));
    try std.testing.expect(vm_cr3.boundedProfileOk(0x600));
    try std.testing.expect(!vm_cr3.boundedProfileOk(vm_cr3.CR4_PCIDE));
    try std.testing.expect(!vm_cr3.boundedProfileOk(vm_cr3.CR4_SMEP | vm_cr3.CR4_SMAP));
}

test "independent walker combines P/U/W/NX and rejects missing leaves" {
    var pages: [4][PAGE]u8 = undefined;
    var ids: [4]u64 = undefined;
    var store = BufStore{ .pages = pages[0..], .ids = ids[0..] };
    const pml4_p: u64 = 0x10000;
    const pdpt_p: u64 = 0x11000;
    const pd_p: u64 = 0x12000;
    const pt_p: u64 = 0x13000;
    const leaf: u64 = 0x14000;
    const pml4 = store.add(pml4_p);
    const pdpt = store.add(pdpt_p);
    const pd = store.add(pd_p);
    const pt = store.add(pt_p);
    const va: u64 = 0x40000000;
    storeU64(pml4, @intCast(probe.pml4Index(va)), pdpt_p | P | W | U);
    storeU64(pdpt, @intCast(probe.pdptIndex(va)), pd_p | P | W | U);
    storeU64(pd, @intCast(probe.pdIndex(va)), pt_p | P | W | U);
    storeU64(pt, @intCast(probe.ptIndex(va)), leaf | P | U | NX);
    const reader = BufReader{ .store = &store };
    const ro = probe.walkVa(reader, pml4_p, va);
    try std.testing.expect(probe.roLeafOk(ro));
    try std.testing.expectEqual(leaf, ro.phys);
    try std.testing.expectEqual(pt_p, ro.pt_phys);
    const absent = probe.walkVa(reader, pml4_p, va + PAGE);
    try std.testing.expect(!absent.present);
    storeU64(pt, @intCast(probe.ptIndex(va)), leaf | P | U | W | NX);
    const rw = probe.walkVa(reader, pml4_p, va);
    try std.testing.expect(probe.rwLeafOk(rw));
    storeU64(pt, @intCast(probe.ptIndex(va)), leaf | P | U);
    const rx = probe.walkVa(reader, pml4_p, va);
    try std.testing.expect(probe.rxLeafOk(rx));
}

test "PDPT huge-page address uses the 1GiB mask not the 2MiB mask" {
    // Mask regression only. The accepted profile still rejects huge user
    // mappings and does not claim 1GiB translation support.
    var pages: [2][PAGE]u8 = undefined;
    var ids: [2]u64 = undefined;
    var store = BufStore{ .pages = pages[0..], .ids = ids[0..] };
    const pml4_p: u64 = 0x10000;
    const pdpt_p: u64 = 0x11000;
    const pml4 = store.add(pml4_p);
    const pdpt = store.add(pdpt_p);
    const gig: u64 = 0x40000000;
    const two_mib_field: u64 = 0x00200000; // bit 21, ignored by a 1GiB leaf
    storeU64(pml4, 0, pdpt_p | P | W);
    storeU64(pdpt, 0, gig | P | W | vm.PTE_PS | two_mib_field);
    const reader = BufReader{ .store = &store };
    const walked = probe.walkVa(reader, pml4_p, 0);
    try std.testing.expect(walked.present);
    try std.testing.expect(walked.huge);
    try std.testing.expectEqual(gig, walked.phys);
    try std.testing.expect(walked.phys & two_mib_field == 0);
}

test "hosted construct of the probe fixture uses two image PTs" {
    var page_store: [64][PAGE]u8 = undefined;
    var phys_store: [64]u64 = [_]u64{0} ** 64;
    var used_store: [64]bool = [_]bool{false} ** 64;
    var prov = TestProvider{
        .pages = page_store[0..],
        .phys = phys_store[0..],
        .used = used_store[0..],
        .slots = 64,
    };
    var frames: [vm.MAX_OWNED_FRAMES]u64 = [_]u64{0} ** vm.MAX_OWNED_FRAMES;
    var journal = vm.Journal.init(frames[0..]);
    var space = vm.AddressSpace.init(&journal);
    const tmpl = vm.KernelTemplate{
        .root_phys = K_ROOT,
        .pdpt0_entry = K_PD | P | W,
    };
    try vm.construct(&prov, fixture.bytes(1), tmpl, &space);
    try std.testing.expectEqual(fixture.EXPECT_IMAGE_PAGES, space.image_pages);
    try std.testing.expectEqual(fixture.EXPECT_IMAGE_PTS, space.image_pts);
    try std.testing.expectEqual(fixture.EXPECT_STACK_PAGES, space.stack_pages);
    try std.testing.expectEqual(fixture.EXPECT_STACK_PTS, space.stack_pts);
    try std.testing.expectEqual(fixture.EXPECT_TABLE_PAGES, space.table_pages);
    try std.testing.expectEqual(fixture.EXPECT_OWNED, @as(u32, @intCast(space.ownedCount())));
    const reader = Reader{ .prov = &prov };
    const rx0 = probe.walkVa(reader, space.root_phys, fixture.rxPage0());
    const rx1 = probe.walkVa(reader, space.root_phys, fixture.rxPage1());
    const ro = probe.walkVa(reader, space.root_phys, fixture.roPage());
    const rw = probe.walkVa(reader, space.root_phys, fixture.rwPage());
    try std.testing.expect(probe.rxLeafOk(rx0));
    try std.testing.expect(probe.rxLeafOk(rx1));
    try std.testing.expect(probe.roLeafOk(ro));
    try std.testing.expect(probe.rwLeafOk(rw));
    try std.testing.expect(rx0.phys != rx1.phys);
    try std.testing.expect(rx0.phys != ro.phys);
    try std.testing.expect(ro.phys != rw.phys);
    try std.testing.expect(!probe.walkVa(reader, space.root_phys, vm.STACK_GUARD).present);
    try std.testing.expect(!probe.walkVa(reader, space.root_phys, vm.STACK_TOP).present);
    var spa: u64 = vm.STACK_LO;
    while (spa < vm.STACK_TOP) : (spa += PAGE) {
        try std.testing.expect(probe.rwLeafOk(probe.walkVa(reader, space.root_phys, spa)));
    }
    var pml4_i: u64 = 1;
    while (pml4_i < 512) : (pml4_i += 1) {
        const e = reader.load(space.root_phys + 8 * pml4_i);
        try std.testing.expect(e & P == 0);
    }
    try vm.destroy(&prov, &space, .inactive);
    try vm.reset(&space);
}

test "AddressSpace and Journal stay small records" {
    try std.testing.expect(@sizeOf(vm.AddressSpace) < 256);
    try std.testing.expect(@sizeOf(vm.Journal) < 64);
}
