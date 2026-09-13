// tools/mkesp — minimal FAT16 ESP image builder (KWP2).
// Layout: \EFI\BOOT\BOOTX64.EFI, \ZK\KERNEL.ELF, \ZK\INITRD.BIN.
// Enough FAT16 for OVMF's driver: BPB boot sector, two FATs, fixed root
// directory, contiguous cluster chains. No boot code — the image is loaded
// via the firmware fallback path, never as a legacy boot sector.
// Usage: mkesp --out esp.img --size-mb 64 --bootx64 <f> --kernel <f> --initramfs <f>

const std = @import("std");

const SECTOR: usize = 512;
const SPC: u8 = 4; // sectors per cluster
const CLUSTER: usize = SECTOR * SPC;
const RESERVED: u16 = 1;
const NFATS: u8 = 2;
const ROOT_ENTRIES: u16 = 512;
const ROOT_SECTORS: usize = ROOT_ENTRIES * 32 / SECTOR;
const MAX_CLUSTERS: usize = 65525;

const File = struct {
    name: [11]u8, // 8.3, space padded
    data: []const u8,
    first_cluster: u16 = 0,
};

pub const NameError = error{
    EmptyName,
    BaseTooLong,
    ExtMissing,
    ExtTooLong,
    TooManyDots,
    BadCharacter,
};

fn isShortNameChar(c: u8) bool {
    if (c >= 'A' and c <= 'Z') return true;
    if (c >= '0' and c <= '9') return true;
    return switch (c) {
        '$', '%', '\'', '-', '_', '@', '~', '`', '!', '(', ')', '{', '}', '^', '#', '&' => true,
        else => false,
    };
}

/// Strict 8.3 short-name encoding (N8). Illegal names are rejected instead
/// of silently truncated: at most one dot, base 1..8 chars, extension 1..3
/// chars when present, restricted charset. "." and ".." dot entries pass
/// through. Lowercase ASCII is uppercased; anything else outside the FAT
/// short-name set fails.
pub fn name83(s: []const u8) NameError![11]u8 {
    var out = [_]u8{' '} ** 11;
    if (std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) {
        @memcpy(out[0..s.len], s);
        return out;
    }
    var dots: usize = 0;
    for (s) |c| {
        if (c == '.') dots += 1;
    }
    if (dots > 1) return error.TooManyDots;
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const base = if (dot) |d| s[0..d] else s;
    const ext: []const u8 = if (dot) |d| s[d + 1 ..] else "";
    if (base.len == 0) return error.EmptyName;
    if (base.len > 8) return error.BaseTooLong;
    if (dot != null and ext.len == 0) return error.ExtMissing;
    if (ext.len > 3) return error.ExtTooLong;
    for (base, 0..) |c, i| {
        const u = std.ascii.toUpper(c);
        if (!isShortNameChar(u)) return error.BadCharacter;
        out[i] = u;
    }
    for (ext, 0..) |c, i| {
        const u = std.ascii.toUpper(c);
        if (!isShortNameChar(u)) return error.BadCharacter;
        out[8 + i] = u;
    }
    return out;
}

fn dirEntry(name: [11]u8, attr: u8, cluster: u16, size: u32) [32]u8 {
    var e = [_]u8{0} ** 32;
    @memcpy(e[0..11], &name);
    e[11] = attr;
    std.mem.writeInt(u16, e[26..28], cluster, .little);
    std.mem.writeInt(u32, e[28..32], size, .little);
    return e;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator(); // one-shot tool: process-lifetime arena, no leak noise

    var out_path: ?[]const u8 = null;
    var size_mb: u64 = 64;
    var bootx64: ?[]const u8 = null;
    var kernel: ?[]const u8 = null;
    var initramfs: ?[]const u8 = null;
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    defer it.deinit();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            out_path = it.next();
        } else if (std.mem.eql(u8, arg, "--size-mb")) {
            const v = it.next() orelse return error.Args;
            size_mb = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--bootx64")) {
            bootx64 = it.next();
        } else if (std.mem.eql(u8, arg, "--kernel")) {
            kernel = it.next();
        } else if (std.mem.eql(u8, arg, "--initramfs")) {
            initramfs = it.next();
        }
    }
    const out = out_path orelse return error.MissingArg;
    const cwd = std.Io.Dir.cwd();
    const fx64 = try cwd.readFileAlloc(io, bootx64 orelse return error.MissingArg, a, .limited(1 << 26));
    const fkernel = try cwd.readFileAlloc(io, kernel orelse return error.MissingArg, a, .limited(1 << 26));
    const finit = try cwd.readFileAlloc(io, initramfs orelse return error.MissingArg, a, .limited(1 << 26));

    const total_sectors = size_mb * 1024 * 1024 / SECTOR;
    // FAT size iteration: clusters depend on FAT sectors and vice versa.
    var fat_sectors: usize = 1;
    var clusters: usize = 0;
    for (0..8) |_| {
        const data_sectors = total_sectors - RESERVED - NFATS * fat_sectors - ROOT_SECTORS;
        clusters = data_sectors / SPC;
        const need = ((clusters + 2) * 2 + SECTOR - 1) / SECTOR;
        if (need == fat_sectors) break;
        fat_sectors = need;
    }
    if (clusters < 4085 or clusters >= MAX_CLUSTERS) return error.BadGeometry;

    var files = [_]File{
        .{ .name = try name83("BOOTX64.EFI"), .data = fx64 },
        .{ .name = try name83("KERNEL.ELF"), .data = fkernel },
        .{ .name = try name83("INITRD.BIN"), .data = finit },
    };
    // Directory clusters: 2 = EFI, 3 = EFI/BOOT, 4 = ZK. Files follow.
    var next_cluster: u16 = 5;
    for (&files) |*f| {
        f.first_cluster = next_cluster;
        next_cluster += @intCast((f.data.len + CLUSTER - 1) / CLUSTER);
    }
    if (next_cluster - 2 > clusters) return error.ImageTooSmall;

    var img = try a.alloc(u8, total_sectors * SECTOR);
    @memset(img, 0);

    // --- boot sector / BPB ---
    const bs = img[0..SECTOR];
    bs[0] = 0xEB;
    bs[1] = 0x3C;
    bs[2] = 0x90;
    @memcpy(bs[3..11], "ZKNATIVE");
    std.mem.writeInt(u16, bs[11..13], SECTOR, .little);
    bs[13] = SPC;
    std.mem.writeInt(u16, bs[14..16], RESERVED, .little);
    bs[16] = NFATS;
    std.mem.writeInt(u16, bs[17..19], ROOT_ENTRIES, .little);
    if (total_sectors < 65536) {
        std.mem.writeInt(u16, bs[19..21], @intCast(total_sectors), .little);
    } else {
        std.mem.writeInt(u32, bs[32..36], @intCast(total_sectors), .little);
    }
    bs[21] = 0xF8; // fixed disk
    std.mem.writeInt(u16, bs[22..24], @intCast(fat_sectors), .little);
    std.mem.writeInt(u16, bs[24..26], 32, .little); // sectors/track
    std.mem.writeInt(u16, bs[26..28], 2, .little); // heads
    bs[36] = 0x80; // drive
    bs[38] = 0x29; // extended boot signature
    std.mem.writeInt(u32, bs[39..43], 0x5A4B0001, .little); // volume id "ZK"
    @memcpy(bs[43..54], "ZKNATIVE   ");
    @memcpy(bs[54..62], "FAT16   ");
    bs[510] = 0x55;
    bs[511] = 0xAA;

    // --- FATs ---
    const fat_bytes = fat_sectors * SECTOR;
    var fat = try a.alloc(u8, fat_bytes);
    defer a.free(fat);
    @memset(fat, 0);
    std.mem.writeInt(u16, fat[0..2], 0xFFF8, .little); // media + EOC marker
    std.mem.writeInt(u16, fat[2..4], 0xFFFF, .little);
    const EOC: u16 = 0xFFFF;
    // Directory clusters 2,3,4 are single.
    for (2..5) |c| std.mem.writeInt(u16, fat[c * 2 ..][0..2], EOC, .little);
    for (&files) |*f| {
        const n = (f.data.len + CLUSTER - 1) / CLUSTER;
        for (0..n) |i| {
            const c: u16 = f.first_cluster + @as(u16, @intCast(i));
            const link: u16 = if (i + 1 == n) EOC else c + 1;
            std.mem.writeInt(u16, fat[c * 2 ..][0..2], link, .little);
        }
    }
    for (0..NFATS) |i| {
        @memcpy(img[(RESERVED + i * fat_sectors) * SECTOR ..][0..fat_bytes], fat);
    }

    // --- root directory: EFI + ZK ---
    const root_off = (RESERVED + NFATS * fat_sectors) * SECTOR;
    @memcpy(img[root_off..][0..32], &dirEntry(try name83("EFI"), 0x10, 2, 0));
    @memcpy(img[root_off + 32 ..][0..32], &dirEntry(try name83("ZK"), 0x10, 4, 0));

    const data_off = root_off + ROOT_SECTORS * SECTOR;
    const clusterOff = struct {
        fn f(doff: usize, c: u16) usize {
            return doff + (@as(usize, c) - 2) * CLUSTER;
        }
    }.f;

    // EFI dir: . .. BOOT (dir, cluster 3)
    const efi_off = clusterOff(data_off, 2);
    @memcpy(img[efi_off..][0..32], &dirEntry(try name83("."), 0x10, 2, 0));
    @memcpy(img[efi_off + 32 ..][0..32], &dirEntry(try name83(".."), 0x10, 0, 0));
    @memcpy(img[efi_off + 64 ..][0..32], &dirEntry(try name83("BOOT"), 0x10, 3, 0));
    // EFI/BOOT dir: . .. BOOTX64.EFI
    const boot_off = clusterOff(data_off, 3);
    @memcpy(img[boot_off..][0..32], &dirEntry(try name83("."), 0x10, 3, 0));
    @memcpy(img[boot_off + 32 ..][0..32], &dirEntry(try name83(".."), 0x10, 2, 0));
    @memcpy(img[boot_off + 64 ..][0..32], &dirEntry(files[0].name, 0x20, files[0].first_cluster, @intCast(files[0].data.len)));
    // ZK dir: . .. KERNEL.ELF INITRD.BIN
    const zk_off = clusterOff(data_off, 4);
    @memcpy(img[zk_off..][0..32], &dirEntry(try name83("."), 0x10, 4, 0));
    @memcpy(img[zk_off + 32 ..][0..32], &dirEntry(try name83(".."), 0x10, 0, 0));
    @memcpy(img[zk_off + 64 ..][0..32], &dirEntry(files[1].name, 0x20, files[1].first_cluster, @intCast(files[1].data.len)));
    @memcpy(img[zk_off + 96 ..][0..32], &dirEntry(files[2].name, 0x20, files[2].first_cluster, @intCast(files[2].data.len)));

    // --- file data ---
    for (&files) |*f| {
        const off = clusterOff(data_off, f.first_cluster);
        @memcpy(img[off..][0..f.data.len], f.data);
    }

    if (std.fs.path.dirname(out)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = out, .data = img });
    std.debug.print("mkesp: {s} sectors={d} clusters={d} fat_sectors={d}\n", .{
        out, total_sectors, clusters, fat_sectors,
    });
}

test "mkesp name83: valid ESP entries encode exactly" {
    const initrd = try name83("INITRD.BIN");
    try std.testing.expectEqualSlices(u8, "INITRD  BIN", &initrd);
    const boot = try name83("BOOTX64.EFI");
    try std.testing.expectEqualSlices(u8, "BOOTX64 EFI", &boot);
    const kernel = try name83("KERNEL.ELF");
    try std.testing.expectEqualSlices(u8, "KERNEL  ELF", &kernel);
    // Lowercase normalizes; dot entries pass through.
    const lower = try name83("bootx64.efi");
    try std.testing.expectEqualSlices(u8, "BOOTX64 EFI", &lower);
    try std.testing.expectEqualSlices(u8, ".          ", &(try name83(".")));
    try std.testing.expectEqualSlices(u8, "..         ", &(try name83("..")));
}

test "mkesp name83: illegal names rejected, never truncated" {
    // N8 regression: INITRAMFS.BIN (9-char base) must fail, not truncate.
    try std.testing.expectError(error.BaseTooLong, name83("INITRAMFS.BIN"));
    try std.testing.expectError(error.BaseTooLong, name83("TOOLONGNAME.EFI"));
    try std.testing.expectError(error.ExtTooLong, name83("INITRD.BINN"));
    try std.testing.expectError(error.EmptyName, name83(".BIN"));
    try std.testing.expectError(error.ExtMissing, name83("INITRD."));
    try std.testing.expectError(error.TooManyDots, name83("A.B.C"));
    try std.testing.expectError(error.BadCharacter, name83("INIT RD.BIN"));
    try std.testing.expectError(error.BadCharacter, name83("INIT*.BIN"));
}
