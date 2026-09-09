// drivers/net/net_device — net_device + net_device_ops (Analog: include/linux/netdevice.h)
// Clean: Interface Adapter — NetOps vtable is DIP; stack depends on interface, not e1000.
const std = @import("std");
const printk = @import("../../lib/printk.zig");
const skbuff = @import("../../net/skbuff.zig");

pub const NetOps = struct {
    open: *const fn (*NetDevice) anyerror!void,
    stop: *const fn (*NetDevice) void,
    xmit: *const fn (*NetDevice, *skbuff.SkBuff) anyerror!void, // ndo_start_xmit
};

pub const NetDevice = struct {
    name: []const u8,
    mac: [6]u8 = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 },
    mtu: u16 = 1500,
    ops: *const NetOps,
    priv: ?*anyopaque = null,
    tx_packets: u64 = 0,
    rx_packets: u64 = 0,
    tx_bytes: u64 = 0,
    rx_bytes: u64 = 0,
};

const MAX_NETDEV: usize = 8;
var devs: [MAX_NETDEV]?*NetDevice = [_]?*NetDevice{null} ** MAX_NETDEV;
var dev_count: usize = 0;
var dev_storage: [MAX_NETDEV]NetDevice = undefined;

pub fn register(alloc_dev: NetDevice) !*NetDevice {
    if (dev_count >= MAX_NETDEV) return error.NoMem;
    dev_storage[dev_count] = alloc_dev;
    const dev = &dev_storage[dev_count];
    devs[dev_count] = dev;
    dev_count += 1;
    printk.printk(.info, "net_device: registered '{s}' mac={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} mtu={d}", .{ dev.name, dev.mac[0], dev.mac[1], dev.mac[2], dev.mac[3], dev.mac[4], dev.mac[5], dev.mtu });
    try dev.ops.open(dev);
    return dev;
}

pub fn find(name: []const u8) ?*NetDevice {
    for (devs[0..dev_count]) |d_opt| if (d_opt) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}
pub fn first() ?*NetDevice {
    if (dev_count == 0) return null;
    return devs[0].?;
}
pub fn count() usize { return dev_count; }

pub fn init() void {
    for (&devs) |*d| d.* = null;
    for (&dev_storage) |*d| d.* = .{ .name = "", .ops = undefined };
    dev_count = 0;
}

pub fn transmit(dev: *NetDevice, skb: *skbuff.SkBuff) !void {
    try dev.ops.xmit(dev, skb);
    dev.tx_packets += 1;
    dev.tx_bytes += skb.len;
}
