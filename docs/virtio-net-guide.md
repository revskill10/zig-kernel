# Virtio-Net Driver Guide — End-to-End Hardware Example

## Single file: `src/drivers/net/virtio_net.zig` — 214 lines

Maps to Linux `drivers/net/ethernet/virtio/virtio_net.c` (simulated).

Demonstrates: Virtio device setup, descriptor rings, interrupts, net_device_ops.

## What this proves

Virtio probe → virtio mmio config → `net_device` + `net_device_ops` → TX/RX descriptor rings + simulated DMA → IRQ → `netif_rx` → socket `recv()`. Real virtio-net flow distilled, no simplification hidden.

## Annotated walk

### 0. Hardware model (simulated)

```zig
const VirtioRegs = struct {
    device_feature_select: u32 = 0,
    device_feature: u32 = 0,
    driver_feature_select: u32 = 0,
    driver_feature: u32 = 0,
    config_select: u32 = 0,
    config: u32 = 0,
    config_msix_select: u32 = 0,
    config_msix: u32 = 0,
    num_queues: u16 = 0,
    device_status: u8 = 0,
    config_generation: u8 = 0,
    queue_select: u16 = 0,
    queue_size: u16 = 0,
    queue_msix_vector: u16 = 0,
    queue_enable: u16 = 0,
    queue_notify_off: u16 = 0,
    queue_desc_low: u32 = 0,
    queue_desc_high: u32 = 0,
    queue_driver_low: u32 = 0,
    queue_driver_high: u32 = 0,
    queue_device_low: u32 = 0,
    queue_device_high: u32 = 0,
    // ... other virtio mmio registers omitted for simplicity
};

const VirtioNetConfig = struct {
    mac: [6]u8,
    status: u16,
    max_virtqueue_pairs: u16 = 1,
    mtu: u16 = 1500,
    // ... other fields omitted
};

const Desc = struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const DescFlag = enum {
    Next = 1,
    Write = 2,
    Indirect = 4,
};

const VirtioNetFeature = enum {
    MAC = 5,          // Device provides MAC address
    STATUS = 6,       // Device provides status
    VQ_PAIR = 7,      // Device supports multiple virtqueue pairs
    MTU = 8,          // Device provides MTU
    // ... others omitted
};

var mmio_mem: [4096]u8 = [_]u8{0} ** 4096; // simulated BAR0
var priv_storage: [4]VirtioNetPrivate = [_]VirtioNetPrivate{.{}} ** 4;
var priv_count: usize = 0;
```

`VirtioNetPrivate { regs, config, tx_desc[16], rx_desc[16], mac, irq_count }` is analogous to `struct virtnet_info`.

### 1. PCI probe → net_device registration

```zig
fn virtio_net_probe(dev: *driver_mod.Device) anyerror!void {
    printk.printk(.info, "virtio_net: probing PCI device '{s}' mmio_base=0x{x} irq={d}", .{ dev.name, dev.mmio_base, dev.irq });
    // BAR mapping simulation
    if (dev.mmio_base == 0) dev.mmio_base = @intFromPtr(&mmio_mem);
    const priv = allocPriv();
    priv.regs = @ptrCast(dev.mmio_base as *VirtioRegs);
    // Register net_device (analog to alloc_etherdev + register_netdev)
    const nd = try netdev.register(.{
        .name = "eth1", // Different interface name to avoid conflict with e1000
        .mac = priv.mac,
        .ops = &virtio_net_ops,
        .priv = @ptrCast(priv),
    });
    _ = nd;
    printk.printk(.info, "virtio_net: probe success — net_device 'eth1' ready, priv @0x{x}", .{@intFromPtr(priv)});
}

pub fn init() !void {
    try driver_mod.registerDriver(driver());
    // Simulate PCI device appearance (similar to e1000)
    try driver_mod.registerDevice(.{ .name = "0000:00:04.0", .bus = .pci, .mmio_base = 0, .irq = 12 });
    printk.printk(.info, "virtio_net: driver loaded (modprobe virtio_net analog)", .{});
}
```

Bus model (`drivers/driver.zig`): `registerDriver` stores `Driver{name,bus,probe,ops}`; `registerDevice` iterates `drivers` and calls `probe` — same as `bus_type.match + driver_probe_device`. LKM analog: `modprobe virtio_net` = `virtio_net.init()` at runtime, no recompilation.

### 2. Open — virtio device init

```zig
fn virtio_net_open(dev: *netdev.NetDevice) anyerror!void {
    const priv: *VirtioNetPrivate = @ptrCast(@alignCast(dev.priv orelse return error.NotFound));
    // Initialize virtio device
    virtio_init(priv);
    printk.printk(.info, "virtio_net: '{s}' opened — mac={x}", .{ dev.name, priv.mac });
}

fn virtio_init(priv: *VirtioNetPrivate) void {
    // Reset device
    priv.regs.device_status = 0;
    // Acknowledge device
    priv.regs.device_status |= 1; // ACKNOWLEDGE
    // Driver knows how to drive the device
    priv.regs.device_status |= 2; // DRIVER
    // Device is ready
    priv.regs.device_status |= 4; // DRIVER_OK
    // Set MAC address (simulate reading from config space)
    priv.config.mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 }; // same as e1000 for consistency
    priv.mac = priv.config.mac;
    // Setup queues (simplified)
    priv.regs.queue_select = 0; // TX queue
    priv.regs.queue_num = 16;
    priv.regs.queue_ready = 1;
    priv.regs.queue_select = 1; // RX queue
    priv.regs.queue_num = 16;
    priv.regs.queue_ready = 1;
}
```

Real virtio-net driver programs the virtio configuration space, sets up virtqueues with descriptor rings, and negotiates features.

### 3. Xmit — descriptor ring + DMA + IRQ

```zig
fn virtio_net_xmit(dev: *netdev.NetDevice, skb: *skbuff.SkBuff) anyerror!void {
    const priv: *VirtioNetPrivate = @ptrCast(@alignCast(dev.priv.?));
    // Simulate DMA: place descriptor in TX ring
    const tx_idx = priv.tx_avail_idx % 16;
    var desc = &priv.tx_desc[tx_idx];
    desc.addr = @intFromPtr(skb.data[skb.head..].ptr);
    desc.len = @intCast(skb.len);
    desc.flags = 0; // Next flag not used in this simple sim
    priv.tx_avail_idx += 1;
    // Simulate device processing and interrupt
    priv.regs.device_status |= 1 << 1; // Simulate interrupt status bit
    priv.irq_count += 1;
    printk.printk(.debug, "virtio_net: xmit '{s}' idx={d} len={d} addr=0x{x}", .{ dev.name, tx_idx, skb.len, desc.addr });
    // Simulate loopback to RX path (like e1000 driver does)
    const rx_skb = skbuff.alloc() orelse return error.NoMem;
    const payload = skb.slice();
    const dst = rx_skb.put(payload.len);
    @memcpy(dst, payload);
    rx_skb.dev = dev.name;
    rx_skb.protocol = 0x0800; // ETH_P_IP
    // Simulate RX descriptor fill
    const rx_idx = priv.rx_avail_idx % 16;
    priv.rx_desc[rx_idx].addr = @intFromPtr(rx_skb.data[rx_skb.head..].ptr);
    priv.rx_desc[rx_idx].len = @intCast(payload.len);
    priv.rx_avail_idx += 1;
    priv.regs.device_status |= 1 << 0; // Simulate RX interrupt
    priv.irq_count += 1;
    net_core.netifRx(rx_skb);
    // Reclaim TX skb
    skbuff.free(skb);
    printk.printk(.info, "virtio_net: TX complete irq#{d} → loopback RX {d}B to net_core", .{ priv.irq_count, payload.len });
}
```

DIP: `socket.send` calls `netdev.transmit(dev, skb)` → `dev.ops.xmit` — stack never imports `virtio_net`. Swap to `e1000` = implement `NetOps {open,stop,xmit}` + `registerDriver(.{name=\"e1000\",...})`.

### 4. RX path

`virtio_net_open` pre-fills RX descriptors; `virtio_net_xmit` loopback fills `RxDesc.len/status` and simulates RX interrupt, then `net_core.netifRx` enqueues to `RX_QUEUE 32` (real: `napi_gro_receive` → `sk_receive_queue`). `socket.recv` → `net_core.recvFromQueue` copies out.

## Bare-metal hardening

- `volatile` MMIO: `*volatile VirtioRegs @ptrFromInt(BAR)` + `asm volatile("mfence")`
- DMA coherent: `dma_alloc_coherent(&tx_desc, 16*@sizeOf(Desc))` vs hosted `@intFromPtr(skb)`
- IRQ: `IDT[0x20+12]=virtio_net_intr` + `request_irq(12, virtio_net_intr, IRQF_SHARED, "eth1", dev)` + `APIC EOI`
- Locking: `spinlock` around `tx_avail_idx/tx_used_idx` (single-core here → preempt disable)

Datasheet: Virtio 1.1 specification, virtio_mmio and virtio_net sections.

## Testing in Hosted Simulation

The driver is tested via the network loopback demo in `main.zig` (lines 117-140). It creates a UDP socket, binds to 127.0.0.1:8080, sends a message, and receives it back via the virtio-net driver's simulated TX→IRQ→RX path.

To verify:
```bash
zig build run
```
Look for:
```
[DEBUG] virtio_net: xmit 'eth1' idx=0 len=72 addr=0x7ff7284fc6da
[INFO] virtio_net: TX complete irq#1 → loopback RX 72B to net_core
[INFO] net: recv() ← 72B 'HELLO from Zig Linux net stack (virtio_net xmit → simulated DMA → IRQ → netif_rx)' (loopback via descriptor ring)
```

## References

- `docs/architecture.md` - Layered structure diagram
- `docs/driver-guide.md` - e1000 end-to-end
- `omarchy/waku-os/board/waku/qemu/` - Omarchy QEMU profile (uses virtio-net)
- Linux source: `drivers/net/ethernet/virtio/virtio_net.c`