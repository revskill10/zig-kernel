# Driver Guide — e1000 end-to-end (Intel 82540EM)

**Single file: `src/drivers/net/e1000.zig` — 165 lines** maps 1:1 to `drivers/net/ethernet/intel/e1000/e1000_main.c`.

## What this proves

PCI probe → BAR/MMIO → `net_device` + `net_device_ops` → TX descriptor ring + DMA → IRQ → `netif_rx` → socket `recv()`. Real `e1000` flow distilled, no simplification hidden.

## Annotated walk

### 0. Hardware model (simulated)

```zig
const E1000Regs = struct {
    ctrl: u32, status: u32, tctl: u32, rctl: u32,
    tdbal: u32, tdlen: u32, tdh: u32, tdt: u32,   // TX ring
    rdbal: u32, rdlen: u32, rdh: u32, rdt: u32,   // RX ring
    ims: u32, icr: u32,                           // interrupt mask/cause
};
const TxDesc = struct { addr: u64, length: u16, cmd: u8, status: u8, ... };
const RxDesc = struct { addr: u64, length: u16, status: u8, ... };
var mmio_mem: [4096]u8;          // BAR0 simulation — real: ioremap(pci_resource_start)
var priv_storage: [4]E1000Private; // per-device (e1000_adapter analog)
```

`E1000Private { regs, tx_ring[16], rx_ring[16], mac 52:54:00:12:34:56, irq_count }` is `struct e1000_adapter`.

### 1. PCI probe → net_device registration

```zig
fn e1000_probe(dev: *Device) !void {
    if (dev.mmio_base == 0) dev.mmio_base = @intFromPtr(&mmio_mem); // BAR map
    const priv = allocPriv();
    const nd = try netdev.register(.{ .name="eth0", .mac=priv.mac, .ops=&e1000_ops, .priv=@ptrCast(priv) });
    // analog: alloc_etherdev() + ether_setup() + register_netdev() + request_irq(irq, e1000_intr)
}
pub fn init() !void {
    try driver.registerDriver(.{ .name="e1000", .bus=.pci, .probe=e1000_probe });
    try driver.registerDevice(.{ .name="0000:00:03.0", .bus=.pci, .irq=11 }); // QEMU -device e1000
}
```

Bus model (`drivers/driver.zig`): `registerDriver` stores `Driver{name,bus,probe,ops}`; `registerDevice` iterates `drivers` and calls `probe` — same as `bus_type.match + driver_probe_device`. LKM analog: `modprobe e1000` = `e1000.init()` at runtime, no recompilation.

### 2. Open — hardware init

```zig
fn e1000_open(dev: *NetDevice) !void {
    priv.regs.ctrl |= 0x04000000; // RST — real: E1000_CTRL_RST
    priv.regs.tctl = 0x00000008;  // enable
    priv.regs.rctl = 0x00000002;  // enable RX — real: E1000_RCTL_EN
    priv.regs.tdbal = low(@intFromPtr(&priv.tx_ring)); // DMA base
    priv.regs.rdlen = 16 * @sizeOf(TxDesc);
    priv.regs.ims = 0xFF;
    for (&priv.rx_ring) |*d| { const skb = skbuff.alloc().?; d.addr=@intFromPtr(skb); }
}
```

Real `e1000_configure()` programs `TDBAL/TDLEN/TDH/TDT` and `RDBAL/RDLEN/RDH/RDT` then `E1000_WRITE_REG(CTRL, ...)`.

### 3. Xmit — descriptor ring + DMA + IRQ

```zig
fn e1000_xmit(dev: *NetDevice, skb: *SkBuff) !void {
    const idx = priv.tx_tail % 16;
    priv.tx_ring[idx] = .{ .addr=@intFromPtr(skb.data[skb.head..].ptr), .length=@intCast(skb.len),
                             .cmd=0x0B, .status=0 }; // EOP|IFCS|RS
    priv.tx_tail+=1; priv.regs.tdt = priv.tx_tail % 16; // doorbell — HW DMAs

    priv.tx_ring[idx].status = 0x01; // DD — descriptor done
    priv.regs.icr |= 0x01; priv.irq_count+=1; // TXDW interrupt

    // loopback: wire → RX (real HW does this over PHY)
    const rx_skb = skbuff.alloc().!; @memcpy(rx_skb.put(skb.len), skb.slice());
    priv.rx_ring[priv.rx_head % 16].status=0x01; priv.regs.icr|=0x40;
    net_core.netifRx(rx_skb); // → RX_QUEUE 32 → socket.recv()
    skbuff.free(skb); // e1000_clean_tx_irq analog
}
```

DIP: `socket.send` calls `netdev.transmit(dev, skb)` → `dev.ops.xmit` — stack never imports `e1000`. Swap to `virtio-net` = implement `NetOps {open,stop,xmit}` + `registerDriver(.{name="virtio-net",...})`.

### 4. RX path

`e1000_open` pre-fills RX descriptors; `e1000_xmit` loopback fills `RxDesc.length/status DD` and `icr RXO`, then `netif_rx` analog `net_core.netifRx` enqueues to `RX_QUEUE 32` (real: `napi_gro_receive` → `sk_receive_queue`). `socket.recv` → `net_core.recvFromQueue` copies out.

## Add your own driver — virtio-net template (~30 lines)

```zig
const virtio_ops = netdev.NetOps{ .open=virtio_open, .stop=virtio_stop, .xmit=virtio_xmit };
fn virtio_probe(dev: *Device) !void {
    // BAR = @intFromPtr(&virtio_regs); virtqueue setup
    _ = try netdev.register(.{ .name="eth1", .mac=.{0x52,0x54,0x00,0xAB,0xCD,0xEF}, .ops=&virtio_ops, .priv=priv });
}
pub fn virtio_init() !void {
    try driver.registerDriver(.{ .name="virtio-net", .bus=.pci, .probe=virtio_probe });
    try driver.registerDevice(.{ .name="0000:00:04.0", .bus=.pci, .irq=10 });
}
// implement virtio_open/xmit ~ same shape as e1000_open/xmit but with virtqueue avail/used rings
```

Add to `main.zig`: `try @import("drivers/net/virtio.zig").virtio_init();` — no core change (OCP).

## Bare-metal hardening

- `volatile` MMIO: `*volatile E1000Regs @ptrFromInt(BAR)` + `asm volatile("mfence")`
- DMA coherent: `dma_alloc_coherent(&tx_ring, 16*@sizeOf(TxDesc))` vs hosted `@intFromPtr(skb)`
- IRQ: `IDT[0x20+11]=e1000_intr` + `request_irq(11, e1000_intr, IRQF_SHARED, "eth0", dev)` + `APIC EOI`
- Locking: `spinlock` around `tx_tail/tdt` (single-core here → preempt disable)

Datasheet: Intel 82540EM §14.3 TX/RX descriptor formats, §5.4 register map.
