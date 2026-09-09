// net/skbuff — sk_buff entity (Entity layer, pure)
// Analog: include/linux/skbuff.h — packet buffer, headroom/tailroom, clone
const std = @import("std");
const printk = @import("../lib/printk.zig");

pub const MAX_SKB: usize = 64;
pub const SKB_BUF_SIZE: usize = 2048;

pub const SkBuff = struct {
    data: [SKB_BUF_SIZE]u8 = [_]u8{0} ** SKB_BUF_SIZE,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    dev: ?[]const u8 = null,
    protocol: u16 = 0, // ETH_P_IP etc.

    pub fn reset(self: *SkBuff) void { self.head = 0; self.tail = 0; self.len = 0; }
    pub fn put(self: *SkBuff, n: usize) []u8 {
        const off = self.tail;
        self.tail += n; self.len += n;
        return self.data[off..off + n];
    }
    pub fn push(self: *SkBuff, n: usize) []u8 {
        self.head += n; self.len += n;
        return self.data[self.head - n .. self.head];
    }
    pub fn slice(self: *const SkBuff) []const u8 { return self.data[self.head .. self.head + self.len]; }
    pub fn mutableSlice(self: *SkBuff) []u8 { return self.data[self.head .. self.head + self.len]; }
};

var pool: [MAX_SKB]SkBuff = [_]SkBuff{.{}} ** MAX_SKB;
var used: [MAX_SKB]bool = [_]bool{false} ** MAX_SKB;

pub fn alloc() ?*SkBuff {
    for (&used, 0..) |*u, i| if (!u.*) { u.* = true; pool[i].reset(); return &pool[i]; };
    printk.printk(.warn, "skbuff: pool exhausted", .{});
    return null;
}
pub fn free(skb: *SkBuff) void {
    const idx = (@intFromPtr(skb) - @intFromPtr(&pool[0])) / @sizeOf(SkBuff);
    used[idx] = false;
}
pub fn init() void { for (&used) |*u| u.* = false; for (&pool) |*skb| skb.reset(); printk.printk(.info, "net: skbuff pool {d} x {d} B ready", .{ MAX_SKB, SKB_BUF_SIZE }); }
