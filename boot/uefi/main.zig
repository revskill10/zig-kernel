// boot/uefi/main — PE32+ EFI loader for the native Zig kernel (KWP2).
// Contract (frozen by KWP1, see profiles/native/x86_64-qemu-ovmf.json):
//   1. Read \zk\kernel.elf and \zk\initrd.bin from the ESP of the device
//      this image was loaded from (LoadedImage -> SimpleFileSystem).
//   2. Validate the ELF64 payload (boot/uefi/elf64.zig) and the initramfs
//      header; place both, an owned stack and the BootInfo below 64 MiB so
//      the kernel's first owned page tables cover every handoff object.
//   3. Acquire the final memory map BEFORE the first ExitBootServices
//      (count-to-byte sizing, bounded BufferTooSmall growth, allocate/free
//      legal only in this phase). Normalize into BootInfo, then EBS.
//      After any EBS attempt only GetMemoryMap into the retained buffer is
//      legal; stale-key InvalidParameter retries that path. Unexpected EBS
//      errors and post-boundary BufferTooSmall halt via COM1; they never
//      return to firmware or free/allocate through boot services.
//   4. Hand off explicitly: cli, owned stack, rdi = BootInfo, jmp entry.
//      After ExitBootServices no boot service, pool allocator or firmware
//      console is touched; COM1 port I/O is the only log channel.
//
// Stage markers: ZKL: start / kernel-loaded / initramfs-loaded / map-frozen /
// ebs-ok / fail-<reason>. The qualifier requires their order.

const std = @import("std");
const uefi = std.os.uefi;
const elf64 = @import("elf64.zig");
const ebs_retry = @import("ebs_retry.zig");
const boot_info = @import("boot_info");
const memmap = @import("memmap");
const initramfs = @import("initramfs");
const serial = @import("serial");

const KERNEL_BASE: u64 = 0x200000; // 2 MiB, matches linker/native-x86_64.ld
const MAP_TOP: u64 = 64 * 1024 * 1024; // every handoff object below this
const STACK_PAGES: usize = 16; // 64 KiB owned kernel stack
const BOOTINFO_BYTES: usize = boot_info.HEADER_SIZE + boot_info.MAX_RANGES * @sizeOf(boot_info.Range);
const MAX_KERNEL_BYTES: usize = 16 * 1024 * 1024;
const MAX_INITRAMFS_BYTES: usize = 32 * 1024 * 1024;
const EBS_RETRIES: u32 = 3;
const MAP_GROWTHS: u32 = 3; // bounded BufferTooSmall doublings of map headroom
const MAP_HEADROOM_DESCS: usize = 8; // initial growth headroom past the queried count
const MAX_FIRMWARE_DESCS: usize = 256; // bounded materialization of the final map

comptime {
    // getMemoryMap writes through an align(8) pool buffer; the firmware
    // descriptor layout must not demand more alignment than that.
    if (@alignOf(uefi.tables.MemoryDescriptor) > 8) @compileError("EFI map buffer underaligned");
}

const KERNEL_PATH = std.unicode.utf8ToUtf16LeStringLiteral("\\zk\\kernel.elf");
const INITRAMFS_PATH = std.unicode.utf8ToUtf16LeStringLiteral("\\zk\\initrd.bin");

fn fatal(comptime stage: []const u8, err: anyerror) uefi.Error {
    serial.print("ZKL: fail stage=" ++ stage ++ " reason={s}\n", .{@errorName(err)});
    return error.LoadError;
}

/// Post-ExitBootServices-attempt termination. Port I/O only; never returns
/// to firmware (pool allocators, boot services and the EFI console are
/// illegal after the first EBS attempt, successful or not).
fn haltFatal(comptime stage: []const u8, err: anyerror) noreturn {
    serial.print("ZKL: fail stage=" ++ stage ++ " reason={s}\n", .{@errorName(err)});
    while (true) {
        asm volatile ("cli; hlt"
            :
            :
            : .{ .memory = true }
        );
    }
}

fn readFile(root: *uefi.protocol.File, path: [*:0]const u16, max: usize) ![]align(8) u8 {
    const bs = uefi.system_table.boot_services.?;
    const f = root.open(path, .read, .{}) catch |err| {
        serial.print("ZKL: fail stage=open reason={s}\n", .{@errorName(err)});
        return error.LoadError;
    };
    defer f.close() catch {};
    const info_size = try f.getInfoSize(.file);
    const info_buf = try bs.allocatePool(.loader_data, info_size);
    defer bs.freePool(info_buf.ptr) catch {};
    const info = try f.getInfo(.file, info_buf);
    const size: usize = @intCast(info.file_size);
    if (size == 0 or size > max) return error.LoadError;
    const buf = try bs.allocatePool(.loader_data, size);
    var got: usize = 0;
    while (got < size) {
        const n = try f.read(buf[got..size]);
        if (n == 0) return error.LoadError; // short file
        got += n;
    }
    return buf;
}

fn mapKind(t: uefi.tables.MemoryType) boot_info.RangeKind {
    return switch (t) {
        .conventional_memory, .boot_services_code, .boot_services_data => .conventional,
        .loader_code, .loader_data => .loader,
        .acpi_reclaim_memory => .acpi_reclaim,
        .acpi_memory_nvs => .nvs,
        .memory_mapped_io, .memory_mapped_io_port_space, .pal_code => .mmio,
        else => .reserved,
    };
}

/// Materialize the final EFI map into bounded memmap descriptors (N1).
/// `getMemoryMapInfo` returns a descriptor COUNT, so the caller's buffer is
/// sized as (count + headroom) * descriptor_size with checked arithmetic;
/// the map itself is copied out descriptor-by-descriptor so a larger
/// firmware stride never corrupts the parse, and stale-map growth reports
/// BufferTooSmall for the bounded outer retry instead of failing outright.
fn readFinalMap(
    map: uefi.tables.MemoryMapSlice,
    out: *[MAX_FIRMWARE_DESCS]memmap.Desc,
) ![]memmap.Desc {
    var k: usize = 0;
    var it = map.iterator();
    while (it.next()) |d| {
        if (k >= out.len) return error.MapTooLarge;
        const bytes = std.math.mul(u64, d.number_of_pages, memmap.PAGE) catch
            return error.MapAddressOverflow;
        const end = std.math.add(u64, d.physical_start, bytes) catch
            return error.MapAddressOverflow;
        if (end < d.physical_start) return error.MapAddressOverflow;
        out[k] = .{ .start = d.physical_start, .pages = d.number_of_pages, .kind = mapKind(d.type) };
        k += 1;
    }
    return out[0..k];
}

/// Rebuild BootInfo bytes from the current map snapshot. Pure: no firmware
/// calls. Used both before the first EBS attempt and after a stale-key
/// GetMemoryMap into the retained buffer.
fn publishBootInfo(
    info: *boot_info.BootInfo,
    map: uefi.tables.MemoryMapSlice,
    owned: []const memmap.Span,
    kpages: usize,
    kentry: u64,
    ibase: u64,
    initrd_len: usize,
    stack_base: u64,
    bi_pages: usize,
) !usize {
    var descs_buf: [MAX_FIRMWARE_DESCS]memmap.Desc = undefined;
    const descs = try readFinalMap(map, &descs_buf);
    info.* = .{
        .total_size = @intCast(bi_pages * 4096),
        .range_count = 0,
        .efi_desc_size = @intCast(map.info.descriptor_size),
        .efi_desc_version = map.info.descriptor_version,
        .kernel_base = KERNEL_BASE,
        .kernel_size = @as(u64, kpages) * 4096,
        .kernel_entry = kentry,
        .initramfs_base = ibase,
        .initramfs_size = initrd_len,
        .stack_base = stack_base,
        .stack_size = @as(u64, STACK_PAGES) * 4096,
    };
    const storage = info.rangesStorage();
    const n = try memmap.normalize(descs, owned, storage);
    if (n == 0) return error.BadMap;
    info.range_count = @intCast(n);
    info.checksum = info.computeChecksum();
    try info.validate();
    return n;
}

pub fn main() uefi.Error!void {
    serial.init();
    serial.print("ZKL: start\n", .{});
    const bs = uefi.system_table.boot_services.?;

    const li = bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch |err|
        return fatal("loaded-image", err);
    if (li == null or li.?.device_handle == null) return fatal("loaded-image", error.LoadFailed);
    const sfs = bs.handleProtocol(uefi.protocol.SimpleFileSystem, li.?.device_handle.?) catch |err|
        return fatal("simple-fs", err);
    if (sfs == null) return fatal("simple-fs", error.LoadFailed);
    const root = sfs.?.openVolume() catch |err| return fatal("open-volume", err);

    // --- kernel payload ---
    const kbytes = readFile(root, KERNEL_PATH, MAX_KERNEL_BYTES) catch |err|
        return fatal("kernel-read", err);
    const kplan = elf64.plan(kbytes, KERNEL_BASE) catch |err|
        return fatal("kernel-elf", err);
    const kpages: usize = @intCast((kplan.span + 4095) / 4096);
    _ = bs.allocatePages(.{ .address = @ptrFromInt(KERNEL_BASE) }, .loader_code, kpages) catch |err|
        return fatal("kernel-alloc", err);
    const kdest: [*]u8 = @ptrFromInt(KERNEL_BASE);
    elf64.execute(&kplan, kbytes, kdest[0..@intCast(kplan.span)]);
    serial.print("ZKL: kernel-loaded base={x} span={x} entry={x}\n", .{
        KERNEL_BASE, kplan.span, kplan.entry,
    });

    // --- initramfs ---
    const ibytes = readFile(root, INITRAMFS_PATH, MAX_INITRAMFS_BYTES) catch |err|
        return fatal("initramfs-read", err);
    const ihdr = initramfs.validate(ibytes) catch |err|
        return fatal("initramfs-validate", err);
    const ipages: usize = (ibytes.len + 4095) / 4096;
    const ipage_mem = bs.allocatePages(.{ .max_address = @ptrFromInt(MAP_TOP) }, .loader_data, ipages) catch |err|
        return fatal("initramfs-alloc", err);
    const ibase: u64 = @intFromPtr(ipage_mem.ptr);
    @memcpy(@as([*]u8, @ptrFromInt(ibase))[0..ibytes.len], ibytes);
    serial.print("ZKL: initramfs-loaded base={x} size={x} payload={x}\n", .{
        ibase, ibytes.len, ihdr.payload_size,
    });

    // --- owned stack + BootInfo pages ---
    const stack_mem = bs.allocatePages(.{ .max_address = @ptrFromInt(MAP_TOP) }, .loader_data, STACK_PAGES) catch |err|
        return fatal("stack-alloc", err);
    const stack_base: u64 = @intFromPtr(stack_mem.ptr);
    const bi_pages = (BOOTINFO_BYTES + 4095) / 4096;
    const bi_mem = bs.allocatePages(.{ .max_address = @ptrFromInt(MAP_TOP) }, .loader_data, bi_pages) catch |err|
        return fatal("bootinfo-alloc", err);
    const info: *boot_info.BootInfo = @ptrCast(bi_mem.ptr);

    // Owned handoff spans, typed for the shared memmap path (N1).
    const owned = [_]memmap.Span{
        .{ .base = KERNEL_BASE, .size = @as(u64, kpages) * 4096, .kind = .kernel },
        .{ .base = ibase, .size = @as(u64, ipages) * 4096, .kind = .initramfs },
        .{ .base = stack_base, .size = @as(u64, STACK_PAGES) * 4096, .kind = .kernel_stack },
        .{ .base = @intFromPtr(info), .size = @as(u64, bi_pages) * 4096, .kind = .boot_info },
    };

    // --- final memory map (PRE-EBS only: info/alloc/grow/free) ---
    // getMemoryMapInfo returns a descriptor COUNT; size the buffer as
    // (count + bounded headroom) * descriptor_size with checked arithmetic.
    // After the first ExitBootServices attempt this whole acquire path is
    // illegal — the retained buffer is reused with GetMemoryMap only.
    const mm_info = bs.getMemoryMapInfo() catch |err|
        return fatal("map-size", err);
    var extra: usize = MAP_HEADROOM_DESCS;
    var growth: u32 = 0;
    var live_map: []align(8) u8 = &.{};
    var map: uefi.tables.MemoryMapSlice = undefined;
    acquire: while (true) {
        const total_descs = std.math.add(usize, mm_info.len, extra) catch
            return fatal("map-size", error.OutOfMemory);
        const buf_len = std.math.mul(usize, total_descs, mm_info.descriptor_size) catch
            return fatal("map-size", error.OutOfMemory);
        const map_buf = bs.allocatePool(.loader_data, buf_len) catch |err|
            return fatal("map-alloc", err);
        map = bs.getMemoryMap(map_buf) catch |err| {
            bs.freePool(map_buf.ptr) catch {};
            switch (ebs_retry.onGetMemoryMapError(.pre_ebs, err, growth < MAP_GROWTHS)) {
                .grow => {
                    growth += 1;
                    extra = std.math.mul(usize, extra, 2) catch
                        return fatal("map-size", error.OutOfMemory);
                    continue :acquire;
                },
                .fail_return => return fatal("map-get", err),
                .fail_halt => haltFatal("map-get", err),
            }
        };
        live_map = map_buf;
        break;
    }

    var attempt: u32 = 0;
    var boundary: ebs_retry.Boundary = .pre_ebs;
    while (attempt < EBS_RETRIES) {
        const n = publishBootInfo(
            info,
            map,
            &owned,
            kpages,
            kplan.entry,
            ibase,
            ibytes.len,
            stack_base,
            bi_pages,
        ) catch |err| {
            if (boundary == .post_ebs) haltFatal("map-validate", err);
            return fatal("map-validate", err);
        };

        serial.print("ZKL: map-frozen attempt={d} ranges={d}\n", .{ attempt, n });
        bs.exitBootServices(uefi.handle, map.info.key) catch |err| {
            boundary = .post_ebs;
            switch (ebs_retry.onExitBootServicesError(err, attempt + 1 < EBS_RETRIES)) {
                .retry_retained => {
                    attempt += 1;
                    serial.print("ZKL: ebs-retry attempt={d}\n", .{attempt});
                    // Retained buffer only. No freePool, getMemoryMapInfo,
                    // or allocation after the EBS attempt. Post-boundary
                    // map errors consult the same policy the hosted trace
                    // tests; growth/return are illegal and halt.
                    map = bs.getMemoryMap(live_map) catch |map_err| {
                        switch (ebs_retry.onGetMemoryMapError(.post_ebs, map_err, false)) {
                            .fail_halt => haltFatal("map-get", map_err),
                            .grow, .fail_return => haltFatal("map-get", map_err),
                        }
                    };
                    continue;
                },
                .fail_halt => haltFatal("ebs", err),
            }
        };
        // Success: no boot services from here on. Port I/O only.
        serial.print("ZKL: ebs-ok attempt={d}\n", .{attempt});
        handoff(info, stack_base + @as(u64, STACK_PAGES) * 4096, kplan.entry);
    }
    haltFatal("ebs", error.LoadError);
}

/// Explicit ABI handoff: interrupts masked, owned 16-aligned stack with a
/// fake return slot (SysV entry alignment), rdi = BootInfo, jmp entry.
fn handoff(info: *boot_info.BootInfo, stack_top: u64, entry: u64) noreturn {
    asm volatile (
        \\ cli
        \\ movq %[stk], %%rsp
        \\ andq $-16, %%rsp
        \\ pushq $0
        \\ xorq %%rbp, %%rbp
        \\ movq %[inf], %%rdi
        \\ jmpq *%[ent]
        :
        : [stk] "r" (stack_top),
          [inf] "r" (@intFromPtr(info)),
          [ent] "r" (entry),
        : .{ .memory = true }
    );
    unreachable;
}
