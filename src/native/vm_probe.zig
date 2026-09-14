// src/native/vm_probe — CPL0 private-VM mapping qualification.
// Two PMM-backed cycles: real CR3 switch, user-VA load/store/fetch, exact
// site-bound faults, full root restore, then destroy. Hosted tests may use
// the pure walker/validators; they must not call run() or CR3 helpers.

const builtin = @import("builtin");
const serial = @import("serial");
const gdt = @import("gdt");
const idt = @import("idt");
const paging = @import("paging");
const pmm = @import("pmm");
const boot_info = @import("boot_info");
const user_vm = @import("user_vm");
const user_vm_pmm = @import("user_vm_pmm");
const fixture = @import("vm_probe_fixture");
const vm_cr3 = @import("vm_cr3");

const probes = idt.probes;

const DEBUG_EXIT_PORT: u16 = 0xF4;
const EXIT_VM: u32 = 0x17;
const ADDR: u64 = user_vm.PTE_ADDR;
const PAGE: u64 = user_vm.PAGE;

pub const WalkResult = struct {
    present: bool = false,
    huge: bool = false,
    phys: u64 = 0,
    u: bool = false,
    w: bool = false,
    nx: bool = false,
    g: bool = false,
    raw: u64 = 0,
    pt_phys: u64 = 0,
    pt_index: u64 = 0,
};

const TABLE_ENTS: usize = 512;

const LowSnap = struct {
    pml4_phys: u64 = 0,
    pdpt_phys: u64 = 0,
    pd_phys: u64 = 0,
    kpt_phys: u64 = 0,
    pml4_0: u64 = 0,
    pdpt_0: u64 = 0,
    pd_ents: [TABLE_ENTS]u64 = [_]u64{0} ** TABLE_ENTS,
    kpt_ents: [TABLE_ENTS]u64 = [_]u64{0} ** TABLE_ENTS,
};

const Identity = struct {
    fn load(_: @This(), phys: u64) u64 {
        const p: *const volatile u64 = @ptrFromInt(@as(usize, @intCast(phys)));
        return p.*;
    }
};

var journal_frames: [user_vm.MAX_OWNED_FRAMES]u64 = [_]u64{0} ** user_vm.MAX_OWNED_FRAMES;
var adapter_owned: [user_vm.MAX_OWNED_FRAMES]u64 = [_]u64{0} ** user_vm.MAX_OWNED_FRAMES;
var journal: user_vm.Journal = undefined;
var space: user_vm.AddressSpace = undefined;
var adapter: user_vm_pmm.Adapter = undefined;
var snap: LowSnap = .{};

const Run = struct {
    orig_cr3: u64 = 0,
    orig_root: u64 = 0,
    baseline: pmm.Stats = .{ .total = 0, .free = 0, .used = 0, .unmanaged = 0, .excluded = 0 },
    cycle: u8 = 0,
    private_active: bool = false,
    constructed: bool = false,
    info: *boot_info.BootInfo = undefined,
};
var run_state: Run = .{};

comptime {
    if (@sizeOf(user_vm.AddressSpace) > 256)
        @compileError("AddressSpace must stay a small pointer-based record");
    if (@sizeOf(user_vm.Journal) > 64)
        @compileError("Journal must stay a slice header, not a frame table");
}

pub fn walkVa(reader: anytype, root: u64, va: u64) WalkResult {
    if (!vm_cr3.validateFrame(root)) return .{};
    const e4 = reader.load(root + 8 * pml4Index(va));
    if (e4 & user_vm.PTE_P == 0) return .{};
    if (e4 & user_vm.PTE_PS != 0) return .{ .present = true, .huge = true, .raw = e4 };
    var user = e4 & user_vm.PTE_U != 0;
    var wr = e4 & user_vm.PTE_W != 0;
    var nx = e4 & user_vm.PTE_NX != 0;
    var g = e4 & user_vm.PTE_G != 0;
    const pdpt = e4 & ADDR;
    if (!vm_cr3.validateFrame(pdpt)) return .{};

    const e3 = reader.load(pdpt + 8 * pdptIndex(va));
    if (e3 & user_vm.PTE_P == 0) return .{};
    user = user and (e3 & user_vm.PTE_U != 0);
    wr = wr and (e3 & user_vm.PTE_W != 0);
    nx = nx or (e3 & user_vm.PTE_NX != 0);
    g = g or (e3 & user_vm.PTE_G != 0);
    if (e3 & user_vm.PTE_PS != 0) {
        // Bits 51:30 for a 1GiB PDPT leaf. Not a 1GiB-page support claim:
        // the accepted profile rejects huge user mappings.
        return .{
            .present = true,
            .huge = true,
            .phys = e3 & 0x000F_FFFF_C000_0000,
            .u = user,
            .w = wr,
            .nx = nx,
            .g = g,
            .raw = e3,
        };
    }
    const pd = e3 & ADDR;
    if (!vm_cr3.validateFrame(pd)) return .{};

    const e2 = reader.load(pd + 8 * pdIndex(va));
    if (e2 & user_vm.PTE_P == 0) return .{};
    user = user and (e2 & user_vm.PTE_U != 0);
    wr = wr and (e2 & user_vm.PTE_W != 0);
    nx = nx or (e2 & user_vm.PTE_NX != 0);
    g = g or (e2 & user_vm.PTE_G != 0);
    if (e2 & user_vm.PTE_PS != 0) {
        return .{
            .present = true,
            .huge = true,
            .phys = e2 & 0x000F_FFFF_FFE0_0000,
            .u = user,
            .w = wr,
            .nx = nx,
            .g = g,
            .raw = e2,
        };
    }
    const pt = e2 & ADDR;
    if (!vm_cr3.validateFrame(pt)) return .{};
    const idx = ptIndex(va);
    const e1 = reader.load(pt + 8 * idx);
    if (e1 & user_vm.PTE_P == 0) {
        return .{ .pt_phys = pt, .pt_index = idx, .raw = e1 };
    }
    user = user and (e1 & user_vm.PTE_U != 0);
    wr = wr and (e1 & user_vm.PTE_W != 0);
    nx = nx or (e1 & user_vm.PTE_NX != 0);
    g = g or (e1 & user_vm.PTE_G != 0);
    return .{
        .present = true,
        .huge = false,
        .phys = e1 & ADDR,
        .u = user,
        .w = wr,
        .nx = nx,
        .g = g,
        .raw = e1,
        .pt_phys = pt,
        .pt_index = idx,
    };
}

pub fn rxLeafOk(w: WalkResult) bool {
    return w.present and !w.huge and w.u and !w.w and !w.nx and !w.g and vm_cr3.validateFrame(w.phys);
}

pub fn roLeafOk(w: WalkResult) bool {
    return w.present and !w.huge and w.u and !w.w and w.nx and !w.g and vm_cr3.validateFrame(w.phys);
}

pub fn rwLeafOk(w: WalkResult) bool {
    return w.present and !w.huge and w.u and w.w and w.nx and !w.g and vm_cr3.validateFrame(w.phys);
}

pub fn pml4Index(va: u64) u64 {
    return (va >> 39) & 0x1FF;
}
pub fn pdptIndex(va: u64) u64 {
    return (va >> 30) & 0x1FF;
}
pub fn pdIndex(va: u64) u64 {
    return (va >> 21) & 0x1FF;
}
pub fn ptIndex(va: u64) u64 {
    return (va >> 12) & 0x1FF;
}

fn skipSwitch() bool {
    const root = @import("root");
    return @hasDecl(root, "ZK_VM_SKIP_SWITCH") and root.ZK_VM_SKIP_SWITCH;
}

fn writableRo() bool {
    const root = @import("root");
    return @hasDecl(root, "ZK_VM_WRITABLE_RO") and root.ZK_VM_WRITABLE_RO;
}

fn modeName() []const u8 {
    if (skipSwitch()) return "skip-switch";
    if (writableRo()) return "writable-ro";
    return "positive";
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

fn fail(stage: []const u8, reason: []const u8) noreturn {
    if (run_state.private_active) {
        vm_cr3.restore(run_state.orig_cr3);
        const now = vm_cr3.readCr3();
        if (now != run_state.orig_cr3) {
            serial.print("ZKN: vm-fail cycle={d} stage={s} reason=restore-unverified\n", .{
                run_state.cycle, stage,
            });
            nativeExit(EXIT_VM);
        }
        run_state.private_active = false;
    }
    if (run_state.constructed) {
        const obs = user_vm.RootObservation{ .cr3 = vm_cr3.readCr3() };
        user_vm.destroy(&adapter, &space, obs) catch {
            serial.print("ZKN: vm-fail cycle={d} stage={s} reason=destroy\n", .{
                run_state.cycle, stage,
            });
            nativeExit(EXIT_VM);
        };
        run_state.constructed = false;
    }
    serial.print("ZKN: vm-fail cycle={d} stage={s} reason={s}\n", .{
        run_state.cycle, stage, reason,
    });
    nativeExit(EXIT_VM);
}

fn loadU8(phys: u64) u8 {
    const p: *const volatile u8 = @ptrFromInt(@as(usize, @intCast(phys)));
    return p.*;
}

fn storePhysU8(phys: u64, value: u8) void {
    const p: *volatile u8 = @ptrFromInt(@as(usize, @intCast(phys)));
    p.* = value;
}

fn loadVaU8(va: u64) u8 {
    const p: *const volatile u8 = @ptrFromInt(@as(usize, @intCast(va)));
    return p.*;
}

fn storeVaU8(va: u64, value: u8) void {
    const p: *volatile u8 = @ptrFromInt(@as(usize, @intCast(va)));
    p.* = value;
}

fn loadPhysU64(phys: u64) u64 {
    return (Identity{}).load(phys);
}

fn storePhysU64(phys: u64, value: u64) void {
    const p: *volatile u64 = @ptrFromInt(@as(usize, @intCast(phys)));
    p.* = value;
}

fn takeSnap(dst: *LowSnap, template: user_vm.KernelTemplate, kernel_base: u64) void {
    const pml4 = template.root_phys;
    const pml4_0 = loadPhysU64(pml4);
    const pdpt = pml4_0 & ADDR;
    const pdpt_0 = loadPhysU64(pdpt);
    const pd = pdpt_0 & ADDR;
    const k_idx = kernel_base / paging.HUGE;
    const pd_k = loadPhysU64(pd + k_idx * 8);
    const kpt = pd_k & ADDR;
    dst.pml4_phys = pml4;
    dst.pdpt_phys = pdpt;
    dst.pd_phys = pd;
    dst.kpt_phys = kpt;
    dst.pml4_0 = pml4_0;
    dst.pdpt_0 = pdpt_0;
    var i: usize = 0;
    while (i < TABLE_ENTS) : (i += 1) {
        dst.pd_ents[i] = loadPhysU64(pd + i * 8);
        dst.kpt_ents[i] = loadPhysU64(kpt + i * 8);
    }
}

fn snapMatchesLive(s: *const LowSnap) bool {
    if (paging.addrPerm(loadPhysU64(s.pml4_phys)) != paging.addrPerm(s.pml4_0)) return false;
    if (paging.addrPerm(loadPhysU64(s.pdpt_phys)) != paging.addrPerm(s.pdpt_0)) return false;
    var i: usize = 0;
    while (i < TABLE_ENTS) : (i += 1) {
        const live_pd = loadPhysU64(s.pd_phys + i * 8);
        if (paging.addrPerm(live_pd) != paging.addrPerm(s.pd_ents[i])) return false;
        const live_kpt = loadPhysU64(s.kpt_phys + i * 8);
        if (paging.addrPerm(live_kpt) != paging.addrPerm(s.kpt_ents[i])) return false;
    }
    return true;
}

fn expectSupervisor(root: u64, va: u64) void {
    const w = walkVa(Identity{}, root, va);
    if (!w.present) fail("walk", "supervisor-missing");
    if (w.u) fail("walk", "supervisor-user");
}

fn pmmStatsEqual(a: pmm.Stats, b: pmm.Stats) bool {
    return a.total == b.total and a.free == b.free and a.used == b.used and
        a.unmanaged == b.unmanaged and a.excluded == b.excluded;
}

fn pmmAccountingOk(st: pmm.Stats) bool {
    return st.total == st.free + st.used;
}

fn uniqueOwned() bool {
    var i: usize = 0;
    while (i < journal.count) : (i += 1) {
        var j = i + 1;
        while (j < journal.count) : (j += 1) {
            if (journal.frames[i] == journal.frames[j]) return false;
        }
    }
    return true;
}

fn ownedOk(template: user_vm.KernelTemplate, bytes: []const u8) bool {
    const borrowed = template.pdpt0_entry & ADDR;
    const fixture_phys = @intFromPtr(bytes.ptr) & ADDR;
    if (journal.count != space.ownedCount()) return false;
    if (adapter.ownedCount() != journal.count) return false;
    if (space.image_pages + space.stack_pages + space.table_pages != journal.count)
        return false;
    var i: usize = 0;
    while (i < journal.count) : (i += 1) {
        const p = journal.frames[i];
        if (p == 0 or p % PAGE != 0) return false;
        if (!pmm.inManagedDomain(p) or !pmm.isAllocatable(p)) return false;
        if (!adapter.owns(p) or !journal.contains(p)) return false;
        if (p == template.root_phys or p == borrowed) return false;
        if (p == fixture_phys) return false;
        if (p == snap.pml4_phys or p == snap.pdpt_phys or p == snap.pd_phys or p == snap.kpt_phys)
            return false;
    }
    return uniqueOwned();
}

fn checkPageFile(
    root: u64,
    bytes: []const u8,
    va_page: u64,
    seg_vaddr: u64,
    file_off: u64,
    filesz: u64,
    memsz: u64,
) void {
    const w = walkVa(Identity{}, root, va_page);
    if (!w.present or w.huge) fail("content", "leaf");
    var off: u64 = 0;
    while (off < PAGE) : (off += 1) {
        const va = va_page + off;
        const via_va = loadVaU8(va);
        const via_phys = loadU8(w.phys + off);
        if (via_va != via_phys) fail("content", "va-phys");
        const in_file = va >= seg_vaddr and (va - seg_vaddr) < filesz;
        const in_mem = va >= seg_vaddr and (va - seg_vaddr) < memsz;
        _ = in_mem; // BSS region is zeroed by takeFrame; same check as slack
        if (in_file) {
            const want = fixture.fileByte(bytes, va, seg_vaddr, file_off, filesz) orelse
                fail("content", "file-byte");
            if (via_va != want) fail("content", "file-mismatch");
        } else if (via_va != 0) {
            fail("content", "slack");
        }
    }
}

fn expectUserLeaf(root: u64, va: u64, kind: enum { rx, ro, rw }, seen_phys: *[20]u64, seen_n: *usize) void {
    const w = walkVa(Identity{}, root, va);
    const ok = switch (kind) {
        .rx => rxLeafOk(w),
        .ro => roLeafOk(w),
        .rw => rwLeafOk(w),
    };
    if (!ok) fail("walk", "perms");
    if (!adapter.owns(w.phys) or !journal.contains(w.phys)) fail("walk", "leaf-unowned");
    var i: usize = 0;
    while (i < seen_n.*) : (i += 1) {
        if (seen_phys[i] == w.phys) fail("walk", "alias");
    }
    if (seen_n.* >= seen_phys.len) fail("walk", "leaf-count");
    seen_phys[seen_n.*] = w.phys;
    seen_n.* += 1;
}

fn checkPrivateMap(root: u64) void {
    var i: u64 = 1;
    while (i < 512) : (i += 1) {
        if (loadPhysU64(root + 8 * i) & user_vm.PTE_P != 0) fail("walk", "extra-pml4");
    }
    const e4 = loadPhysU64(root);
    if (e4 & user_vm.PTE_P == 0) fail("walk", "pml4-0");
    if (e4 & user_vm.PTE_PS != 0) fail("walk", "pml4-huge");
    const pdpt = e4 & ADDR;
    if (!adapter.owns(pdpt) or !vm_cr3.validateFrame(pdpt)) fail("walk", "pdpt-unowned");

    const e3_0 = loadPhysU64(pdpt);
    if (paging.addrPerm(e3_0) != paging.addrPerm(snap.pdpt_0)) fail("walk", "borrowed-pdpt0");
    if (e3_0 & user_vm.PTE_U != 0) fail("walk", "pdpt0-user");

    i = 2;
    while (i < 512) : (i += 1) {
        if (loadPhysU64(pdpt + 8 * i) & user_vm.PTE_P != 0) fail("walk", "extra-pdpt");
    }
    const user_pd_e = loadPhysU64(pdpt + 8 * 1);
    if (user_pd_e & user_vm.PTE_P == 0) fail("walk", "pdpt-1");
    if (user_pd_e & user_vm.PTE_U == 0) fail("walk", "pdpt-1-user");
    if (user_pd_e & user_vm.PTE_PS != 0) fail("walk", "user-huge");
    const pd = user_pd_e & ADDR;
    if (!adapter.owns(pd) or !vm_cr3.validateFrame(pd)) fail("walk", "pd-unowned");

    const want_pd0 = pdIndex(fixture.rxPage0());
    const want_pd1 = pdIndex(fixture.rxPage1());
    const want_stack_pd = pdIndex(user_vm.STACK_LO);
    var idx: u64 = 0;
    var image_pts: u32 = 0;
    var stack_pts: u32 = 0;
    while (idx < 512) : (idx += 1) {
        const pde = loadPhysU64(pd + 8 * idx);
        if (pde & user_vm.PTE_P == 0) {
            if (idx == want_pd0 or idx == want_pd1 or idx == want_stack_pd)
                fail("walk", "missing-pt");
            continue;
        }
        if (idx != want_pd0 and idx != want_pd1 and idx != want_stack_pd)
            fail("walk", "extra-pd");
        if (pde & user_vm.PTE_PS != 0) fail("walk", "user-huge");
        if (pde & user_vm.PTE_G != 0) fail("walk", "user-global");
        const pt = pde & ADDR;
        if (!adapter.owns(pt) or !vm_cr3.validateFrame(pt)) fail("walk", "pt-unowned");
        if (idx == want_stack_pd) {
            stack_pts += 1;
        } else {
            image_pts += 1;
        }
        var pti: u64 = 0;
        while (pti < 512) : (pti += 1) {
            const pte = loadPhysU64(pt + 8 * pti);
            if (pte & user_vm.PTE_P == 0) continue;
            const va = (1 << 30) + (idx << 21) + (pti << 12);
            const want_rx0 = fixture.rxPage0();
            const want_rx1 = fixture.rxPage1();
            const want_ro = fixture.roPage();
            const want_rw = fixture.rwPage();
            const in_stack = va >= user_vm.STACK_LO and va < user_vm.STACK_TOP;
            const in_image = va == want_rx0 or va == want_rx1 or va == want_ro or va == want_rw;
            if (!in_stack and !in_image) fail("walk", "extra-leaf");
        }
    }
    if (image_pts != fixture.EXPECT_IMAGE_PTS or stack_pts != fixture.EXPECT_STACK_PTS)
        fail("walk", "pt-count");

    var seen_phys: [20]u64 = [_]u64{0} ** 20;
    var seen_n: usize = 0;
    expectUserLeaf(root, fixture.rxPage0(), .rx, &seen_phys, &seen_n);
    expectUserLeaf(root, fixture.rxPage1(), .rx, &seen_phys, &seen_n);
    expectUserLeaf(root, fixture.roPage(), .ro, &seen_phys, &seen_n);
    expectUserLeaf(root, fixture.rwPage(), .rw, &seen_phys, &seen_n);
    var spa: u64 = user_vm.STACK_LO;
    while (spa < user_vm.STACK_TOP) : (spa += PAGE) {
        expectUserLeaf(root, spa, .rw, &seen_phys, &seen_n);
    }
    if (seen_n != fixture.EXPECT_IMAGE_PAGES + fixture.EXPECT_STACK_PAGES)
        fail("walk", "leaf-count");
    if (walkVa(Identity{}, root, user_vm.STACK_GUARD).present) fail("walk", "guard");
    if (walkVa(Identity{}, root, user_vm.STACK_TOP).present) fail("walk", "stack-top");
}

fn checkFault(
    stage: []const u8,
    vector: u8,
    fault_rip: u64,
    cr2: u64,
    err: u64,
    helper: u64,
    armed_gen: u64,
) void {
    if (helper != 1) fail(stage, "expected-pf");
    const rec = idt.takeRecord() orelse fail(stage, "expected-pf");
    if (rec.vector != vector or rec.rip != fault_rip or rec.cr2 != cr2 or
        rec.error_code != err or rec.generation != armed_gen)
        fail(stage, "record");
    serial.print(
        "ZKN: vm-cycle cycle={d} stage={s} vector=14 pfec={x} cr2={x:0>16} rip={x:0>16} gen={d}\n",
        .{ run_state.cycle, stage, rec.error_code, rec.cr2, rec.rip, rec.generation },
    );
}

pub fn run(info_ptr: *anyopaque) void {
    if (comptime builtin.os.tag != .freestanding) {
        @compileError("vm_probe.run is native-only; hosted tests may use walker helpers only");
    }
    const info: *boot_info.BootInfo = @ptrCast(@alignCast(info_ptr));
    journal = user_vm.Journal.init(journal_frames[0..]);
    space = user_vm.AddressSpace.init(&journal);
    adapter = user_vm_pmm.Adapter.init(adapter_owned[0..]);
    run_state = .{
        .info = info,
        .cycle = 0,
    };

    serial.print("ZKN: vm-start profile=native-vm-probe-v1 mode={s}\n", .{modeName()});
    const st0 = pmm.stats();
    if (!pmmAccountingOk(st0)) fail("control", "pmm-accounting");
    run_state.baseline = st0;

    runCycle(1);
    runCycle(2);

    const stf = pmm.stats();
    if (!pmmStatsEqual(stf, run_state.baseline)) fail("destroy", "baseline");
    if (adapter.ownedCount() != 0 or journal.count != 0)
        fail("destroy", "live");
    serial.print("ZKN: vm-complete cycles=2\n", .{});
}

fn runCycle(cycle: u8) void {
    run_state.cycle = cycle;
    const bytes = fixture.bytes(cycle);
    const digest = fixture.sha256Hex(bytes);
    serial.print("ZKN: vm-fixture cycle={d} len={d} sha256={s}\n", .{
        cycle, bytes.len, digest,
    });
    if (bytes.len != fixture.FIXTURE_LEN) fail("construct", "fixture-len");
    const want_digest: []const u8 = if (cycle == 1) fixture.CYCLE1_SHA256_HEX else fixture.CYCLE2_SHA256_HEX;
    if (want_digest.len != 64) fail("construct", "fixture-pin");
    var di: usize = 0;
    while (di < 64) : (di += 1) {
        if (digest[di] != want_digest[di]) fail("construct", "fixture-pin");
    }

    const rflags = vm_cr3.readRflags();
    if (!vm_cr3.interruptsMasked(rflags)) fail("control", "if");
    vm_cr3.cli();
    const cr3 = vm_cr3.readCr3();
    const cr0 = vm_cr3.readCr0();
    const cr4 = vm_cr3.readCr4();
    const efer = vm_cr3.readEfer();
    if (!vm_cr3.writeProtectEnabled(cr0) or !vm_cr3.nxeEnabled(efer))
        fail("control", "wp-nxe");
    if (!vm_cr3.boundedProfileOk(cr4)) fail("control", "profile");
    const st = pmm.stats();
    if (!pmmAccountingOk(st) or !pmmStatsEqual(st, run_state.baseline))
        fail("control", "pmm-accounting");
    serial.print(
        "ZKN: vm-cycle cycle={d} stage=control cr3={x:0>16} rflags={x:0>16} cr0={x:0>16} cr4={x:0>16} efer={x:0>16} pmm-total={d} pmm-free={d} pmm-used={d} pmm-unmanaged={d} pmm-excluded={d}\n",
        .{ cycle, cr3, rflags, cr0, cr4, efer, st.total, st.free, st.used, st.unmanaged, st.excluded },
    );

    const raw = paging.kernelTemplate() catch fail("template", "template");
    if (raw.root_phys != vm_cr3.cr3Addr(cr3)) fail("template", "root-mismatch");
    const tmpl = user_vm.KernelTemplate{
        .root_phys = raw.root_phys,
        .pdpt0_entry = raw.pdpt0_entry,
    };
    serial.print("ZKN: vm-cycle cycle={d} stage=template root={x:0>16} pdpt0={x:0>16}\n", .{
        cycle, tmpl.root_phys, tmpl.pdpt0_entry,
    });

    run_state.orig_cr3 = cr3;
    run_state.orig_root = tmpl.root_phys;
    takeSnap(&snap, tmpl, run_state.info.kernel_base);
    observeSupervisor(tmpl.root_phys);

    if (user_vm_pmm.page_bytes_resolver != null) fail("construct", "hosted-resolver");
    user_vm.construct(&adapter, bytes, tmpl, &space) catch fail("construct", "construct");
    run_state.constructed = true;
    if (space.image_pages != fixture.EXPECT_IMAGE_PAGES or
        space.stack_pages != fixture.EXPECT_STACK_PAGES or
        space.table_pages != fixture.EXPECT_TABLE_PAGES or
        space.image_pts != fixture.EXPECT_IMAGE_PTS or
        space.stack_pts != fixture.EXPECT_STACK_PTS or
        space.ownedCount() != fixture.EXPECT_OWNED)
        fail("construct", "counts");
    if (!ownedOk(tmpl, bytes)) fail("construct", "owned");
    if (space.root_phys == 0 or space.root_phys == tmpl.root_phys)
        fail("construct", "private-root");
    serial.print(
        "ZKN: vm-cycle cycle={d} stage=construct owned={d} image={d} stack={d} tables={d} root={x:0>16}\n",
        .{
            cycle,
            space.ownedCount(),
            space.image_pages,
            space.stack_pages,
            space.table_pages,
            space.root_phys,
        },
    );

    const rx_w = walkVa(Identity{}, space.root_phys, fixture.RX_VADDR);
    const rx1_w = walkVa(Identity{}, space.root_phys, fixture.rxPage1());
    const ro_w = walkVa(Identity{}, space.root_phys, fixture.RO_VADDR);
    const rw_w = walkVa(Identity{}, space.root_phys, fixture.RW_VADDR);
    checkPrivateMap(space.root_phys);
    observeSupervisor(space.root_phys);
    expectSupervisor(space.root_phys, space.root_phys);
    expectSupervisor(space.root_phys, rx_w.phys);
    serial.print(
        "ZKN: vm-cycle cycle={d} stage=walk image-pts={d} stack-pts={d} rx={x:0>16} rx1={x:0>16} ro={x:0>16} rw={x:0>16}\n",
        .{ cycle, space.image_pts, space.stack_pts, rx_w.phys, rx1_w.phys, ro_w.phys, rw_w.phys },
    );

    if (!skipSwitch()) {
        vm_cr3.cli();
        vm_cr3.switchTo(space.root_phys);
        run_state.private_active = true;
    }
    const observed = vm_cr3.readCr3();
    serial.print("ZKN: vm-cycle cycle={d} stage=switch expected={x:0>16} observed={x:0>16}\n", .{
        cycle, space.root_phys, vm_cr3.cr3Addr(observed),
    });
    if (vm_cr3.cr3Addr(observed) != space.root_phys) fail("switch", "cr3-readback");

    if (!vm_cr3.writeProtectEnabled(vm_cr3.readCr0()) or !vm_cr3.nxeEnabled(vm_cr3.readEfer()))
        fail("content", "wp-nxe");

    checkPageFile(space.root_phys, bytes, fixture.rxPage0(), fixture.RX_VADDR, fixture.RX_FILE_OFF, fixture.RX_FILESZ, fixture.RX_MEMSZ);
    checkPageFile(space.root_phys, bytes, fixture.rxPage1(), fixture.RX_VADDR, fixture.RX_FILE_OFF, fixture.RX_FILESZ, fixture.RX_MEMSZ);
    checkPageFile(space.root_phys, bytes, fixture.roPage(), fixture.RO_VADDR, fixture.RO_FILE_OFF, fixture.RO_FILESZ, fixture.RO_MEMSZ);
    checkPageFile(space.root_phys, bytes, fixture.rwPage(), fixture.RW_VADDR, fixture.RW_FILE_OFF, fixture.RW_FILESZ, fixture.RW_MEMSZ);

    var spa: u64 = user_vm.STACK_LO;
    while (spa < user_vm.STACK_TOP) : (spa += PAGE) {
        const sw = walkVa(Identity{}, space.root_phys, spa);
        if (!rwLeafOk(sw)) fail("content", "stack-leaf");
        var so: u64 = 0;
        while (so < PAGE) : (so += 1) {
            if (loadVaU8(spa + so) != 0 or loadU8(sw.phys + so) != 0)
                fail("content", "stack-zero");
        }
    }

    const pat = fixture.cyclePattern(cycle);
    const pat_va = fixture.RW_VADDR + fixture.RW_FILESZ;
    const pat_w = walkVa(Identity{}, space.root_phys, pat_va);
    storeVaU8(pat_va, pat);
    if (loadVaU8(pat_va) != pat) fail("content", "store-va");
    if (loadU8(pat_w.phys + (pat_va & (PAGE - 1))) != pat) fail("content", "store-phys");
    if (bytes[fixture.RW_FILE_OFF] != fixture.RET) fail("content", "source");
    if (bytes[fixture.RO_FILE_OFF] != fixture.cycleRo(cycle)) fail("content", "source");

    if (probes.probeNxJump(fixture.ENTRY) != 0) fail("content", "fetch");
    serial.print("ZKN: vm-cycle cycle={d} stage=content fetch=0\n", .{cycle});

    if (writableRo()) {
        if (!adapter.owns(ro_w.pt_phys)) fail("fault-ro", "pt-unowned");
        const pte_addr = ro_w.pt_phys + ro_w.pt_index * 8;
        storePhysU64(pte_addr, loadPhysU64(pte_addr) | user_vm.PTE_W);
        vm_cr3.invlpg(fixture.RO_VADDR);
    }

    const ro_before = loadVaU8(fixture.RO_VADDR);
    const gen_ro = idt.arm(.{
        .vector = idt.VEC_PF,
        .fault_rip = probes.roFaultRip(),
        .resume_rip = probes.roContRip(),
        .cr2 = fixture.RO_VADDR,
        .match_cr2 = true,
        .error_code = idt.ERR_PF_RO_WRITE,
    });
    const ro_rc = probes.probeRoWrite(fixture.RO_VADDR);
    checkFault("fault-ro", idt.VEC_PF, probes.roFaultRip(), fixture.RO_VADDR, idt.ERR_PF_RO_WRITE, ro_rc, gen_ro);
    if (loadVaU8(fixture.RO_VADDR) != ro_before) fail("fault-ro", "ro-mutated");

    const gen_nx = idt.arm(.{
        .vector = idt.VEC_PF,
        .fault_rip = fixture.NX_VADDR,
        .resume_rip = probes.nxContRip(),
        .cr2 = fixture.NX_VADDR,
        .match_cr2 = true,
        .error_code = idt.ERR_PF_NX_FETCH,
    });
    const nx_rc = probes.probeNxJump(fixture.NX_VADDR);
    checkFault("fault-nx", idt.VEC_PF, fixture.NX_VADDR, fixture.NX_VADDR, idt.ERR_PF_NX_FETCH, nx_rc, gen_nx);

    const gen_g = idt.arm(.{
        .vector = idt.VEC_PF,
        .fault_rip = probes.unmappedFaultRip(),
        .resume_rip = probes.unmappedContRip(),
        .cr2 = user_vm.STACK_GUARD,
        .match_cr2 = true,
        .error_code = idt.ERR_PF_NOTPRESENT_READ,
    });
    const g_rc = probes.probeUnmapped(user_vm.STACK_GUARD);
    checkFault("fault-guard", idt.VEC_PF, probes.unmappedFaultRip(), user_vm.STACK_GUARD, idt.ERR_PF_NOTPRESENT_READ, g_rc, gen_g);

    const gen_t = idt.arm(.{
        .vector = idt.VEC_PF,
        .fault_rip = probes.unmappedFaultRip(),
        .resume_rip = probes.unmappedContRip(),
        .cr2 = user_vm.STACK_TOP,
        .match_cr2 = true,
        .error_code = idt.ERR_PF_NOTPRESENT_READ,
    });
    const t_rc = probes.probeUnmapped(user_vm.STACK_TOP);
    checkFault("fault-top", idt.VEC_PF, probes.unmappedFaultRip(), user_vm.STACK_TOP, idt.ERR_PF_NOTPRESENT_READ, t_rc, gen_t);

    vm_cr3.restore(run_state.orig_cr3);
    const restored = vm_cr3.readCr3();
    serial.print("ZKN: vm-cycle cycle={d} stage=restore expected={x:0>16} observed={x:0>16}\n", .{
        cycle, run_state.orig_cr3, restored,
    });
    if (restored != run_state.orig_cr3) fail("restore", "cr3-readback");
    run_state.private_active = false;
    if (!snapMatchesLive(&snap)) fail("restore", "low-map");
    observeSupervisor(run_state.orig_root);

    if (walkVa(Identity{}, run_state.orig_root, fixture.RX_VADDR).present)
        fail("absent", "structural");
    const gen_a = idt.arm(.{
        .vector = idt.VEC_PF,
        .fault_rip = probes.unmappedFaultRip(),
        .resume_rip = probes.unmappedContRip(),
        .cr2 = fixture.RX_VADDR,
        .match_cr2 = true,
        .error_code = idt.ERR_PF_NOTPRESENT_READ,
    });
    const a_rc = probes.probeUnmapped(fixture.RX_VADDR);
    checkFault("absent", idt.VEC_PF, probes.unmappedFaultRip(), fixture.RX_VADDR, idt.ERR_PF_NOTPRESENT_READ, a_rc, gen_a);

    const obs = user_vm.RootObservation{ .cr3 = vm_cr3.readCr3() };
    user_vm.destroy(&adapter, &space, obs) catch |err| {
        if (err == error.ReleaseFailed) fail("destroy", "release-failed");
        fail("destroy", "destroy");
    };
    run_state.constructed = false;
    if (space.failed_release_frame != 0 or space.owns_zero) fail("destroy", "release-failed");
    if (journal.count != 0 or adapter.ownedCount() != 0) fail("destroy", "live");
    const st1 = pmm.stats();
    if (!pmmAccountingOk(st1) or !pmmStatsEqual(st1, run_state.baseline))
        fail("destroy", "baseline");
    user_vm.reset(&space) catch fail("destroy", "reset");
    serial.print(
        "ZKN: vm-cycle cycle={d} stage=destroy owned=0 adapter=0 pmm-total={d} pmm-free={d} pmm-used={d} pmm-unmanaged={d} pmm-excluded={d}\n",
        .{ cycle, st1.total, st1.free, st1.used, st1.unmanaged, st1.excluded },
    );
}

fn observeSupervisor(root: u64) void {
    expectSupervisor(root, @intFromPtr(&runCycle));
    expectSupervisor(root, vm_cr3.readRsp());
    expectSupervisor(root, run_state.info.stack_base);
    expectSupervisor(root, vm_cr3.readGdtrBase());
    expectSupervisor(root, vm_cr3.readIdtrBase());
    expectSupervisor(root, @intFromPtr(&gdt.tss));
    expectSupervisor(root, @intFromPtr(&serial.write));
    expectSupervisor(root, @intFromPtr(&pmm.stats));
    expectSupervisor(root, @intFromPtr(&idt.takeRecord));
    expectSupervisor(root, @intFromPtr(&journal_frames));
    expectSupervisor(root, @intFromPtr(&adapter_owned));
    expectSupervisor(root, @intFromPtr(&snap));
    expectSupervisor(root, snap.pml4_phys);
    expectSupervisor(root, snap.pdpt_phys);
    expectSupervisor(root, snap.pd_phys);
    expectSupervisor(root, snap.kpt_phys);
}
