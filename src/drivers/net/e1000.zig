// drivers/net/e1000 — Intel e1000 (82540EM) NIC driver — end-to-end hardware example
// Analog: drivers/net/ethernet/intel/e1000/e1000_main.c
// Demonstrates: PCI probe (ID table), BAR/MMIO, descriptor rings, DMA, interrupts, net_device_ops
const std = @import("std");
const printk = @import("../../lib/printk.zig");
const driver_mod = @import("../driver.zig");
const netdev = @import("net_device.zig");
const skbuff = @import("../../net/skbuff.zig");
const net_core = @import("../../net/net_core.zig");

// ── Simulated hardware registers (analog to e1000_hw) ──
const E1000Regs = struct {
    ctrl: u32 = 0,
    status: u32 = 0x80000000, // link up
    tctl: u32 = 0,
    rctl: u32 = 0,
    tdbal: u32 = 0,
    tdbah: u32 = 0,
    tdlen: u32 = 0,
    tdh: u32 = 0,
    tdt: u32 = 0,
    rdbal: u32 = 0,
    rdbah: u32 = 0,
    rdlen: u32 = 0,
    rdh: u32 = 0,
    rdt: u32 = 0,
    ims: u32 = 0, // interrupt mask set
    icr: u32 = 0, // interrupt cause read
};

const TX_RING: usize = 16;
const RX_RING: usize = 16;

const TxDesc = struct { addr: u64 = 0, length: u16 = 0, cso: u8 = 0, cmd: u8 = 0, status: u8 = 0, css: u8 = 0, special: u16 = 0 };
const RxDesc = struct { addr: u64 = 0, length: u16 = 0, csum: u16 = 0, status: u8 = 0, errors: u8 = 0, special: u16 = 0 };

// Per-device private data (analog to struct e1000_adapter)
const E1000Private = struct {
    regs: E1000Regs = .{},
    tx_ring: [TX_RING]TxDesc = [_]TxDesc{.{}} ** TX_RING,
    rx_ring: [RX_RING]RxDesc = [_]RxDesc{.{}} ** RX_RING,
    tx_head: usize = 0,
    tx_tail: usize = 0,
    rx_head: usize = 0,
    rx_tail: usize = 0,
    mac: [6]u8 = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 },
    irq_count: u64 = 0,
};

var priv_storage: [4]E1000Private = [_]E1000Private{.{}} ** 4;
var priv_count: usize = 0;
var mmio_mem: [4096]u8 = [_]u8{0} ** 4096; // simulated BAR0

fn allocPriv() *E1000Private {
    const p = &priv_storage[priv_count];
    priv_count += 1;
    return p;
}

// ── net_device_ops implementations ──
fn e1000_open(dev: *netdev.NetDevice) anyerror!void {
    const priv: *E1000Private = @ptrCast(@alignCast(dev.priv orelse return error.NotFound));
    // Hardware init sequence (analog to e1000_configure)
    priv.regs.ctrl |= 0x04000000; // RST
    priv.regs.tctl = 0x00000008; // enable
    priv.regs.rctl = 0x00000002; // enable RX
    priv.regs.tdbal = @intCast(@intFromPtr(&priv.tx_ring) & 0xFFFFFFFF);
    priv.regs.rdbal = @intCast(@intFromPtr(&priv.rx_ring) & 0xFFFFFFFF);
    priv.regs.tdlen = TX_RING * @sizeOf(TxDesc);
    priv.regs.rdlen = RX_RING * @sizeOf(RxDesc);
    priv.regs.ims = 0xFF; // enable all interrupts
    // Program RX descriptors with empty buffers (DMA setup)
    for (&priv.rx_ring) |*desc| {
        const skb = skbuff.alloc() orelse continue;
        desc.addr = @intFromPtr(skb);
        desc.status = 0;
    }
    printk.printk(.info, "e1000: '{s}' opened — regs ctrl=0x{x} tctl=0x{x} rctl=0x{x} tx_ring={d} rx_ring={d}", .{ dev.name, priv.regs.ctrl, priv.regs.tctl, priv.regs.rctl, TX_RING, RX_RING });
}

fn e1000_stop(dev: *netdev.NetDevice) void {
    const priv: *E1000Private = @ptrCast(@alignCast(dev.priv.?));
    priv.regs.tctl = 0;
    priv.regs.rctl = 0;
    printk.printk(.info, "e1000: '{s}' stopped", .{dev.name});
}

fn e1000_xmit(dev: *netdev.NetDevice, skb: *skbuff.SkBuff) anyerror!void {
    const priv: *E1000Private = @ptrCast(@alignCast(dev.priv.?));
    // 1. DMA mapping (simulated): place descriptor
    const idx = priv.tx_tail % TX_RING;
    var desc = &priv.tx_ring[idx];
    desc.addr = @intFromPtr(skb.data[skb.head..].ptr);
    desc.length = @intCast(skb.len);
    desc.cmd = 0x0B; // EOP | IFCS | RS
    desc.status = 0;
    priv.tx_tail += 1;
    priv.regs.tdt = @intCast(priv.tx_tail % TX_RING);

    printk.printk(.debug, "e1000: xmit '{s}' idx={d} len={d} addr=0x{x}", .{ dev.name, idx, skb.len, desc.addr });

    // 2. Hardware would DMA now — simulate immediate completion + interrupt
    desc.status = 0x01; // DD (descriptor done)
    priv.regs.icr |= 0x01; // TXDW
    priv.irq_count += 1;

    // 3. Loopback to RX path for hosted demo (real HW: wire → RX ring → interrupt)
    const rx_skb = skbuff.alloc() orelse return error.NoMem;
    const payload = skb.slice();
    const dst = rx_skb.put(payload.len);
    @memcpy(dst, payload);
    rx_skb.dev = dev.name;
    rx_skb.protocol = 0x0800; // ETH_P_IP
    const rx_idx = priv.rx_head % RX_RING;
    priv.rx_ring[rx_idx].length = @intCast(payload.len);
    priv.rx_ring[rx_idx].status = 0x01; // DD
    priv.rx_head += 1;
    priv.regs.icr |= 0x40; // RXO
    net_core.netifRx(rx_skb);

    skbuff.free(skb);
    printk.printk(.info, "e1000: TX complete irq#{d} → loopback RX {d}B to net_core", .{ priv.irq_count, payload.len });
}

const e1000_ops = netdev.NetOps{ .open = e1000_open, .stop = e1000_stop, .xmit = e1000_xmit };

// ── PCI driver probe (analog to e1000_probe + pci_device_id table) ──
fn e1000_probe(dev: *driver_mod.Device) anyerror!void {
    // PCI ID filter — only claim 82540EM device 0000:00:03.0
    // Analog: static const struct pci_device_id e1000_pci_tbl[] + MODULE_DEVICE_TABLE
    if (!std.mem.eql(u8, dev.name, "0000:00:03.0")) return error.WrongDevice;
    printk.printk(.info, "e1000: probing PCI device '{s}' mmio_base=0x{x} irq={d}", .{ dev.name, dev.mmio_base, dev.irq });
    if (dev.mmio_base == 0) dev.mmio_base = @intFromPtr(&mmio_mem);
    const priv = allocPriv();
    const nd = try netdev.register(.{
        .name = "eth0",
        .mac = priv.mac,
        .ops = &e1000_ops,
        .priv = @ptrCast(priv),
    });
    _ = nd;
    printk.printk(.info, "e1000: probe success — net_device 'eth0' ready, priv @0x{x}", .{@intFromPtr(priv)});
}

pub fn driver() driver_mod.Driver {
    return .{ .name = "e1000", .bus = .pci, .probe = e1000_probe };
}

pub fn init() !void {
    try driver_mod.registerDriver(driver());
    try driver_mod.registerDevice(.{ .name = "0000:00:03.0", .bus = .pci, .mmio_base = 0, .irq = 11 });
    printk.printk(.info, "e1000: driver loaded (modprobe e1000 analog)", .{});
}
