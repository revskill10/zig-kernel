// tests/native-user/vm_native_compile.zig — compile-only x86_64 freestanding
// root. The exported wrapper actually initializes PMM and paging from
// runtime inputs, then calls construction and teardown with the native PMM
// adapter so lazy function bodies (including identity-map pageBytes) are
// code-generated. Not executed; not imported by the default native kernel.

const user_vm = @import("user_vm");
const user_vm_pmm = @import("user_vm_pmm");
const paging = @import("paging");
const pmm = @import("pmm");
const boot_info = @import("boot_info");

var journal_frames: [user_vm.MAX_OWNED_FRAMES]u64 = [_]u64{0} ** user_vm.MAX_OWNED_FRAMES;
var adapter_owned: [user_vm.MAX_OWNED_FRAMES]u64 = [_]u64{0} ** user_vm.MAX_OWNED_FRAMES;
var journal: user_vm.Journal = undefined;
var space: user_vm.AddressSpace = undefined;
var adapter: user_vm_pmm.Adapter = undefined;

export fn userVmConstructAndTeardown(
    info: *const boot_info.BootInfo,
    kernel_base: u64,
    elf_ptr: [*]const u8,
    elf_len: usize,
) usize {
    pmm.init(info) catch return 1;
    paging.init(kernel_base);

    journal = user_vm.Journal.init(journal_frames[0..]);
    space = user_vm.AddressSpace.init(&journal);
    adapter = user_vm_pmm.Adapter.init(adapter_owned[0..]);

    const p = adapter.allocPage() catch return 2;
    const page = adapter.pageBytes(p) catch return 3;
    const first = page[0];
    if (!adapter.freePage(p)) return 4;

    const raw = paging.kernelTemplate() catch return 11;
    const tmpl = user_vm.KernelTemplate{
        .root_phys = raw.root_phys,
        .pdpt0_entry = raw.pdpt0_entry,
    };

    user_vm.construct(&adapter, elf_ptr[0..elf_len], tmpl, &space) catch return 12;
    const root_page = adapter.pageBytes(space.root_phys) catch return 14;
    const root_byte = root_page[0];
    user_vm.destroy(&adapter, &space, .inactive) catch return 13;
    return @as(usize, first) + @as(usize, root_byte) + space.ownedCount();
}

export fn userVmAdapterPageBytes(phys: u64) usize {
    const page = adapter.pageBytes(phys) catch return 0;
    return page[0];
}

export fn userVmAdapterAllocFree() usize {
    const p = adapter.allocPage() catch return 1;
    const page = adapter.pageBytes(p) catch return 3;
    const b = page[0];
    if (!adapter.freePage(p)) return 2;
    return b;
}

export fn userVmInitOnly(info: *const boot_info.BootInfo, kernel_base: u64) usize {
    pmm.init(info) catch return 1;
    paging.init(kernel_base);
    adapter = user_vm_pmm.Adapter.init(adapter_owned[0..]);
    return 0;
}
