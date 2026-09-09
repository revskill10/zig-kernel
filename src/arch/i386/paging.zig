// Identity paging for x86 32-bit: maps low 64 MiB (16 x 4 MiB) as 4 KiB pages.
var page_directory: [1024]u32 align(4096) = [_]u32{0} ** 1024;
var page_tables: [16][1024]u32 align(4096) = [_][1024]u32{[_]u32{0} ** 1024} ** 16;

pub fn paging_init() void {
    for (0..16) |pt_idx| {
        for (0..1024) |i| {
            const frame: u32 = @as(u32, @intCast(pt_idx * 1024 + i));
            page_tables[pt_idx][i] = (frame * 4096) | 0x3; // P | R/W
        }
    }
    for (0..1024) |i| {
        if (i < 16) {
            page_directory[i] = (@intFromPtr(&page_tables[i][0]) & 0xFFFFF000) | 0x3;
        } else {
            page_directory[i] = 0;
        }
    }
    const pdir: u32 = @intFromPtr(&page_directory[0]);
    asm volatile ("mov %[p], %%cr3" : : [p] "r" (pdir) : .{ .memory = true });
    var cr0: u32 = asm volatile ("mov %%cr0, %[r]" : [r] "=r" (-> u32));
    cr0 |= 0x80000000;
    asm volatile ("mov %[v], %%cr0" : : [v] "r" (cr0) : .{ .memory = true });
}
