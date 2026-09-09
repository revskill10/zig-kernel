// drivers/net/virtio_net — Virtio network driver (paravirtual)
// Analog: drivers/net/virtio_net.c + drivers/virtio/virtio_mmio.c (Linux)
// Demonstrates: Virtio MMIO probe, virtqueue avail/used rings, net_device_ops

const std = @import("std");
const printk = @import("../../lib/printk.zig");
const driver_mod = @import("../driver.zig");
const netdev = @import("net_device.zig");
const skbuff = @import("../../net/skbuff.zig");
const net_core = @import("../../net/net_core.zig");

// ── Simulated virtio MMIO registers (subset of virtio_mmio spec) ──
const VirtioRegs = struct {
    magic: u32 = 0x74726976, // 'virt'
    version: u32 = 2,
    device_id: u32 = 1, // net = 1
    vendor_id: u32 = 0x1AF4,
    device_features: u32 = (1 << 5), // VIRTIO_NET_F_MAC
    device_features_sel: u32 = 0,
    driver_features: u32 = 0,
    driver_features_sel: u32 = 0,
    queue_sel: u32 = 0,
    queue_num_max: u32 = 16,
    queue_num: u32 = 16,
    queue_ready: u32 = 0,
    queue_notify: u32 = 0,
    interrupt_status: u32 = 0,
    interrupt_ack: u32 = 0,
    status: u32 = 0,
    queue_desc_low: u32 = 0,
    queue_desc_high: u32 = 0,
    queue_driver_low: u32 = 0,
    queue_driver_high: u32 = 0,
    queue_device_low: u32 = 0,
    queue_device_high: u32 = 0,
    config_generation: u32 = 0,
};

const VirtioNetConfig = struct {
    mac: [6]u8 = [_]u8{ 0x52, 0x54, 0x00, 0xAB, 0xCD, 0xEF },
    status: u16 = 1, // VIRTIO_NET_S_LINK_UP
    max_virtqueue_pairs: u16 = 1,
    mtu: u16 = 1500,
};

const Desc = struct {
    addr: u64 = 0,
    len: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};

// Status bits — matches Linux include/uapi/linux/virtio_config.h
const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;

const VirtioNetPrivate = struct {
    regs: VirtioRegs = .{},
    config: VirtioNetConfig = .{},
    tx_ring: [16]Desc = [_]Desc{.{}} ** 16,
    rx_ring: [16]Desc = [_]Desc{.{}} ** 16,
    tx_avail_idx: u16 = 0,
    tx_used_idx: u16 = 0,
    rx_avail_idx: u16 = 0,
    rx_used_idx: u16 = 0,
    mac: [6]u8 = [_]u8{ 0x52, 0x54, 0x00, 0xAB, 0xCD, 0xEF },
    irq_count: u64 = 0,
};

var priv_storage: [4]VirtioNetPrivate = [_]VirtioNetPrivate{.{}} ** 4;
var priv_count: usize = 0;
var mmio_mem: [4096]u8 = [_]u8{0} ** 4096;

fn allocPriv() *VirtioNetPrivate {
    const p = &priv_storage[priv_count];
    priv_count += 1;
    return p;
}

fn virtio_init_device(priv: *VirtioNetPrivate) void {
    priv.regs.status = 0;
    priv.regs.status |= STATUS_ACKNOWLEDGE;
    priv.regs.status |= STATUS_DRIVER;
    // Negotiate features: we accept MAC
    priv.regs.driver_features = (1 << 5);
    priv.regs.status |= STATUS_FEATURES_OK;
    // Queue setup: 16 entries each
    priv.regs.queue_sel = 0;
    priv.regs.queue_num = 16;
    priv.regs.queue_ready = 1;
    priv.regs.queue_sel = 1;
    priv.regs.queue_num = 16;
    priv.regs.queue_ready = 1;
    // Read MAC from config space
    priv.config.mac = [_]u8{ 0x52, 0x54, 0x00, 0xAB, 0xCD, 0xEF };
    priv.mac = priv.config.mac;
    priv.regs.status |= STATUS_DRIVER_OK;
}

// ── net_device_ops implementations ──

fn virtio_net_open(dev: *netdev.NetDevice) anyerror!void {
    const priv: *VirtioNetPrivate = @ptrCast(@alignCast(dev.priv orelse return error.NotFound));
    virtio_init_device(priv);
    // Pre-fill RX virtqueue with empty buffers (analog to virtnet_open → try_fill_recv)
    for (&priv.rx_ring) |*desc| {
        const skb = skbuff.alloc() orelse continue;
        desc.addr = @intFromPtr(skb);
        desc.len = 2048;
        desc.flags = 2; // WRITE — device writes
        desc.next = 0;
    }
    printk.printk(.info, "virtio_net: '{s}' opened — mac {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} status=0x{x}", .{ dev.name, priv.mac[0], priv.mac[1], priv.mac[2], priv.mac[3], priv.mac[4], priv.mac[5], priv.regs.status });
}

fn virtio_net_stop(dev: *netdev.NetDevice) void {
    const priv: *VirtioNetPrivate = @ptrCast(@alignCast(dev.priv.?));
    priv.regs.status = 0;
    printk.printk(.info, "virtio_net: '{s}' stopped", .{dev.name});
}

fn virtio_net_xmit(dev: *netdev.NetDevice, skb: *skbuff.SkBuff) anyerror!void {
    const priv: *VirtioNetPrivate = @ptrCast(@alignCast(dev.priv.?));

    // 1. Place descriptor in TX virtqueue avail ring
    const tx_idx = priv.tx_avail_idx % 16;
    var desc = &priv.tx_ring[tx_idx];
    desc.addr = @intFromPtr(skb.data[skb.head..].ptr);
    desc.len = @intCast(skb.len);
    desc.flags = 0; // device reads
    priv.tx_avail_idx += 1;
    priv.regs.queue_notify = 0; // kick TX queue 0 — real: iowrite32(0, notify_addr)

    printk.printk(.debug, "virtio_net: xmit '{s}' idx={d} len={d} addr=0x{x}", .{ dev.name, tx_idx, skb.len, desc.addr });

    // 2. Simulate device completion: avail → used, interrupt
    priv.tx_used_idx += 1;
    priv.regs.interrupt_status |= 1; // TX used-buffer notification
    priv.irq_count += 1;

    // 3. Loopback to RX virtqueue for hosted demo (real HW: host delivers via RX used ring)
    const rx_skb = skbuff.alloc() orelse return error.NoMem;
    const payload = skb.slice();
    const dst = rx_skb.put(payload.len);
    @memcpy(dst, payload);
    rx_skb.dev = dev.name;
    rx_skb.protocol = 0x0800;
    const rx_idx = priv.rx_avail_idx % 16;
    priv.rx_ring[rx_idx].addr = @intFromPtr(rx_skb.data[rx_skb.head..].ptr);
    priv.rx_ring[rx_idx].len = @intCast(payload.len);
    priv.rx_ring[rx_idx].flags = 0;
    priv.rx_avail_idx += 1;
    priv.rx_used_idx += 1;
    priv.regs.interrupt_status |= 2; // RX
    net_core.netifRx(rx_skb);

    skbuff.free(skb);
    printk.printk(.info, "virtio_net: TX complete irq#{d} → loopback RX {d}B to net_core", .{ priv.irq_count, payload.len });
}

const virtio_net_ops = netdev.NetOps{ .open = virtio_net_open, .stop = virtio_net_stop, .xmit = virtio_net_xmit };

// ── PCI driver probe (analog to virtnet_probe) ──

fn virtio_net_probe(dev: *driver_mod.Device) anyerror!void {
    if (!std.mem.eql(u8, dev.name, "0000:00:04.0")) return error.WrongDevice;
    printk.printk(.info, "virtio_net: probing PCI device '{s}' mmio_base=0x{x} irq={d}", .{ dev.name, dev.mmio_base, dev.irq });
    if (dev.mmio_base == 0) dev.mmio_base = @intFromPtr(&mmio_mem);
    const priv = allocPriv();
    const nd = try netdev.register(.{
        .name = "eth1",
        .mac = priv.mac,
        .ops = &virtio_net_ops,
        .priv = @ptrCast(priv),
    });
    _ = nd;
    printk.printk(.info, "virtio_net: probe success — net_device 'eth1' ready, priv @0x{x}", .{@intFromPtr(priv)});
}

pub fn driver() driver_mod.Driver {
    return .{ .name = "virtio_net", .bus = .pci, .probe = virtio_net_probe };
}

pub fn init() !void {
    try driver_mod.registerDriver(driver());
    try driver_mod.registerDevice(.{ .name = "0000:00:04.0", .bus = .pci, .mmio_base = 0, .irq = 12 });
    printk.printk(.info, "virtio_net: driver loaded (modprobe virtio_net analog)", .{});
}
