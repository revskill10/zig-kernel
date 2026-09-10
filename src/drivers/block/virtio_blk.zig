// drivers/block/virtio_blk — virtio-blk sector device over a static RAM disk.
// Analog: drivers/block/virtio_blk.c (Linux). Bring-up model: fixed 64x512B
// image, no virtqueue/DMA yet. Freestanding-safe: no imports, no heap.
// ponytail: no PCI registry binding (static ready flag), no virtqueue, no
// writeback cache. ceiling: driver.zig probe + virtqueue avail/used rings.
pub const SECTOR_SIZE: usize = 512;
pub const SECTOR_COUNT: usize = 64;
pub const PCI_ADDRESS = "0000:00:05.0";

var disk_image: [SECTOR_COUNT][SECTOR_SIZE]u8 = image: {
    var sectors = [_][SECTOR_SIZE]u8{[_]u8{0} ** SECTOR_SIZE} ** SECTOR_COUNT;
    // Sector 0 keeps the requested fixture; the actual ext4 superblock is in sector 2.
    sectors[0][56] = 0x53;
    sectors[0][57] = 0xEF;
    sectors[2][56] = 0x53;
    sectors[2][57] = 0xEF;
    // Sector 4 holds the single-file fixture consumed by src/fs/ext4.zig
    // (first 33 bytes of "Hello from Zig Linux VFS (ramfs)\n").
    const hello = "Hello from Zig Linux VFS (ramfs)\n";
    for (hello, 0..) |c, i| sectors[4][i] = c;
    break :image sectors;
};
var ready: bool = false;

pub fn init() !void {
    ready = true;
}

pub fn read_sector(lba: u32, out: *[512]u8) !void {
    if (!ready) return error.NotReady;
    if (lba >= SECTOR_COUNT) return error.OutOfRange;
    out.* = disk_image[@as(usize, @intCast(lba))];
}

pub fn write_sector(lba: u32, data: *const [512]u8) !void {
    if (!ready) return error.NotReady;
    if (lba >= SECTOR_COUNT) return error.OutOfRange;
    disk_image[@as(usize, @intCast(lba))] = data.*;
}

/// The fixed capacity is available even before initialization.
pub fn capacity_sectors() usize {
    return SECTOR_COUNT;
}
