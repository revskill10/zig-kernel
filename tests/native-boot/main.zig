// tests/native-boot — hosted integration for the KWP2 native boot path.
// These prove validation/normalization logic only; they are not runtime
// boot, trap, or isolation evidence (that comes from scripts/qualify-native
// and the coordinator's QEMU runs). N5: every test below executes real
// assertions — no expect(true) placeholder.

const std = @import("std");
const boot_info = @import("boot_info");
const memmap = @import("memmap");
const initramfs = @import("initramfs");
const ebs_retry = @import("ebs_retry");

test "native-boot: shared memmap path populates a validating BootInfo" {
    // Mirrors the UEFI loader sequence: zero storage, write the header,
    // normalize firmware-like descriptors plus owned handoff spans into
    // construction capacity, publish the count, checksum, validate.
    var raw: [8192]u8 align(4096) = undefined;
    @memset(&raw, 0);
    const info: *boot_info.BootInfo = @ptrCast(@alignCast(&raw));
    const self_page = @intFromPtr(info) & ~@as(u64, 4095);
    info.* = .{
        .total_size = 8192,
        .range_count = 0,
        .efi_desc_size = 48,
        .efi_desc_version = 1,
        .kernel_base = 0x200000,
        .kernel_size = 0x1000,
        .kernel_entry = 0x200000,
        .initramfs_base = 0x300000,
        .initramfs_size = 0x1000,
        .stack_base = 0x400000,
        .stack_size = 0x1000,
    };
    const descs = [_]memmap.Desc{
        .{ .start = 0x0, .pages = 0x500, .kind = .conventional },
        .{ .start = self_page, .pages = 2, .kind = .conventional },
    };
    const owned = [_]memmap.Span{
        .{ .base = 0x200000, .size = 0x1000, .kind = .kernel },
        .{ .base = 0x300000, .size = 0x1000, .kind = .initramfs },
        .{ .base = 0x400000, .size = 0x1000, .kind = .kernel_stack },
        .{ .base = self_page, .size = 8192, .kind = .boot_info },
    };
    const storage = info.rangesStorage();
    const n = try memmap.normalize(&descs, &owned, storage);
    try std.testing.expect(n > 0);
    try std.testing.expect(n <= storage.len);
    try std.testing.expect(!boot_info.rangesOverlap(info.rangesStorage()[0..n]));
    info.range_count = n;
    info.checksum = info.computeChecksum();
    try info.validate();
}

test "native-boot: zero published ranges fail coverage, never hand off" {
    // Documents the publish-only-after-success rule: a count of zero (the
    // old N1 loader behavior) must fail validation, not boot.
    var raw: [8192]u8 align(4096) = undefined;
    @memset(&raw, 0);
    const info: *boot_info.BootInfo = @ptrCast(@alignCast(&raw));
    info.* = .{
        .total_size = 8192,
        .range_count = 0,
        .efi_desc_size = 48,
        .efi_desc_version = 1,
        .kernel_base = 0x200000,
        .kernel_size = 0x1000,
        .kernel_entry = 0x200000,
        .initramfs_base = 0x300000,
        .initramfs_size = 0x1000,
        .stack_base = 0x400000,
        .stack_size = 0x1000,
    };
    info.checksum = info.computeChecksum();
    try std.testing.expectError(error.KernelNotCovered, info.validate());
}

test "native-boot: storage exhaustion surfaces before publish" {
    // Capacity overflow is an error from normalize; the caller never
    // publishes a truncated count.
    var storage: [1]boot_info.Range = undefined;
    const descs = [_]memmap.Desc{
        .{ .start = 0x0, .pages = 0x10, .kind = .conventional },
        .{ .start = 0x10000, .pages = 0x10, .kind = .conventional },
    };
    try std.testing.expectError(error.Capacity, memmap.normalize(&descs, &.{}, &storage));
}

test "native-boot: initramfs blob validates through the shared module" {
    const payload = "native-boot integration payload";
    var blob: [initramfs.HEADER_SIZE + 64]u8 = undefined;
    @memset(&blob, 0);
    var h = initramfs.Header{
        .payload_size = payload.len,
        .payload_checksum = initramfs.checksumPayload(payload),
    };
    @memcpy(blob[0..initramfs.HEADER_SIZE], std.mem.asBytes(&h));
    @memcpy(blob[initramfs.HEADER_SIZE..][0..payload.len], payload);
    const got = try initramfs.validate(blob[0 .. initramfs.HEADER_SIZE + payload.len]);
    try std.testing.expectEqual(@as(u64, payload.len), got.payload_size);
}

test "native-boot: owned kernel spanning two firmware descriptors validates" {
    // Production path: descriptors split at 0x201000, owned kernel
    // [0x200000, 0x202000). Normalize into BootInfo, publish, validate.
    var raw: [8192]u8 align(4096) = undefined;
    @memset(&raw, 0);
    const info: *boot_info.BootInfo = @ptrCast(@alignCast(&raw));
    const self_page = @intFromPtr(info) & ~@as(u64, 4095);
    info.* = .{
        .total_size = 8192,
        .range_count = 0,
        .efi_desc_size = 48,
        .efi_desc_version = 1,
        .kernel_base = 0x200000,
        .kernel_size = 0x2000,
        .kernel_entry = 0x200000,
        .initramfs_base = 0x300000,
        .initramfs_size = 0x1000,
        .stack_base = 0x400000,
        .stack_size = 0x1000,
    };
    const descs = [_]memmap.Desc{
        .{ .start = 0x200000, .pages = 1, .kind = .loader },
        .{ .start = 0x201000, .pages = 1, .kind = .loader },
        .{ .start = 0x300000, .pages = 1, .kind = .conventional },
        .{ .start = 0x400000, .pages = 1, .kind = .conventional },
        .{ .start = self_page, .pages = 2, .kind = .conventional },
    };
    const owned = [_]memmap.Span{
        .{ .base = 0x200000, .size = 0x2000, .kind = .kernel },
        .{ .base = 0x300000, .size = 0x1000, .kind = .initramfs },
        .{ .base = 0x400000, .size = 0x1000, .kind = .kernel_stack },
        .{ .base = self_page, .size = 8192, .kind = .boot_info },
    };
    const storage = info.rangesStorage();
    const n = try memmap.normalize(&descs, &owned, storage);
    try std.testing.expect(n > 0);
    try std.testing.expect(!boot_info.rangesOverlap(storage[0..n]));
    info.range_count = n;
    info.checksum = info.computeChecksum();
    try info.validate();
}

test "native-boot: real gap in owned kernel coverage still fails" {
    var raw: [8192]u8 align(4096) = undefined;
    @memset(&raw, 0);
    const info: *boot_info.BootInfo = @ptrCast(@alignCast(&raw));
    const self_page = @intFromPtr(info) & ~@as(u64, 4095);
    info.* = .{
        .total_size = 8192,
        .range_count = 0,
        .efi_desc_size = 48,
        .efi_desc_version = 1,
        .kernel_base = 0x200000,
        .kernel_size = 0x2000,
        .kernel_entry = 0x200000,
        .initramfs_base = 0x300000,
        .initramfs_size = 0x1000,
        .stack_base = 0x400000,
        .stack_size = 0x1000,
    };
    const descs = [_]memmap.Desc{
        .{ .start = 0x200000, .pages = 1, .kind = .loader },
        .{ .start = 0x202000, .pages = 1, .kind = .loader },
        .{ .start = 0x300000, .pages = 1, .kind = .conventional },
        .{ .start = 0x400000, .pages = 1, .kind = .conventional },
        .{ .start = self_page, .pages = 2, .kind = .conventional },
    };
    const owned = [_]memmap.Span{
        .{ .base = 0x200000, .size = 0x2000, .kind = .kernel },
        .{ .base = 0x300000, .size = 0x1000, .kind = .initramfs },
        .{ .base = 0x400000, .size = 0x1000, .kind = .kernel_stack },
        .{ .base = self_page, .size = 8192, .kind = .boot_info },
    };
    const storage = info.rangesStorage();
    const n = try memmap.normalize(&descs, &owned, storage);
    try std.testing.expect(n > 0);
    info.range_count = n;
    info.checksum = info.computeChecksum();
    try std.testing.expectError(error.KernelNotCovered, info.validate());
}

test "native-boot: production EBS retry policy never frees or allocates after EBS" {
    const ebs = [_]ebs_retry.EbsGet{ .invalid_parameter, .ok };
    const t = ebs_retry.simulate(.{ .ebs = &ebs });
    try std.testing.expect(!t.illegal);
    try std.testing.expectEqual(ebs_retry.Outcome.handoff, t.outcome);
    try std.testing.expectEqualSlices(ebs_retry.Call, &.{
        .get_memory_map_info,
        .allocate_pool,
        .get_memory_map,
        .exit_boot_services,
        .get_memory_map,
        .exit_boot_services,
    }, t.slice());
}

test "native-boot: post-EBS BufferTooSmall and unexpected EBS halt without return" {
    const stale = [_]ebs_retry.EbsGet{.invalid_parameter};
    const too_small = ebs_retry.simulate(.{ .ebs = &stale, .post_map = .buffer_too_small });
    try std.testing.expectEqual(ebs_retry.Outcome.halt, too_small.outcome);
    try std.testing.expect(!too_small.illegal);
    for (too_small.slice()) |c| {
        try std.testing.expect(c != .return_to_firmware);
        try std.testing.expect(c != .free_pool);
    }
    const unexpected = [_]ebs_retry.EbsGet{.other};
    const halt = ebs_retry.simulate(.{ .ebs = &unexpected });
    try std.testing.expectEqual(ebs_retry.Outcome.halt, halt.outcome);
    try std.testing.expectEqualSlices(ebs_retry.Call, &.{
        .get_memory_map_info,
        .allocate_pool,
        .get_memory_map,
        .exit_boot_services,
        .halt,
    }, halt.slice());
}
