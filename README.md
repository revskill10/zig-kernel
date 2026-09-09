# Zig Linux Kernel — Minimal Complete (hosted simulation)

Monolithic + LKMs in **Zig 0.16.0**, correct Linux architecture, Clean Architecture layers enforced. Hosted native exe simulates bare-metal paging/DMA/IRQs so `zig build` works on Windows without QEMU.

Built as sibling to `@12-factor-agents/linux-kernel-architecture.md` — same 6 subsystems, same DIP vtables, same production-ready lenses.

## Quick start

```sh
cd zig-kernel

# Hosted simulation (Windows/Linux native, no QEMU needed)
zig build run    # boot → VFS 33B → e1000 loopback 72B → sched 6 ticks → MM slab
zig build test   # 7 tests (KUnit analog — per-push, break build)
zig build        # just compile zig-out/bin/zig-kernel.exe
```

Expected `zig build run` tail:
```
VFS: read /hello.txt via syscall read → 'Hello from Zig Linux VFS (ramfs)' (33B)
net: recv() ← 72B 'HELLO from Zig Linux net stack ...' (loopback via descriptor ring)
 eth0: tx 1 pkts 72B  rx 0 pkts 0B  mac 52:54:00:12:34:56
```

## QEMU Verification

For bare-metal verification, see `docs/qemu-verification-guide.md`.

**Linux/macOS users with QEMU:**
```bash
# Cross-compile for x86_64
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall
# Output: zig-out/bin/kernel

# Run in QEMU
qemu-system-x86_64 \
  -machine q35,accel=tcg \
  -cpu qemu64 \
  -smp 1 \
  -m 512M \
  -kernel zig-out/bin/kernel \
  -append "console=ttyS0 loglevel=7" \
  -nographic
```

## Layout (matches real kernel + Clean Architecture)

```
src/
  arch/x86_64/boot.zig    Framework/HW  (boot banner, GDT/IDT note)
  arch/x86_64/entry.zig   Delivery      (SYSCALL_MAX=32 table, dispatch Ring3→Ring0)
  syscall.zig             Controller    (9 handlers: open/read/write/close/socket/bind/send/recv/ioctl, fd table, -Exxx)
  mm/mm.zig               Entities      (Page id/in_use, Slab(T,cap) generic, VmArea, MAX_PAGES=256 1MiB)
  sched/sched.zig         Entities+UseCase (Task pid/name/state, SchedClass vtable {pick_next,enqueue,dequeue}, cfs)
  vfs/vfs.zig             Adapters      (Inode/Dentry/File, FileOps vtable, ramfs_ops → analog ext4)
  drivers/driver.zig      Framework     (BusType pci/platform/usb, Driver vtable probe, Device mmio_base/irq)
  drivers/net/net_device.zig Adapter    (NetDevice, NetOps {open,stop,xmit=ndo_start_xmit})
  drivers/net/e1000.zig   Adapter       ★ end-to-end hardware driver (see below)
  net/skbuff.zig          Entity        (SkBuff pool 64×2048, put/push/slice)
  net/net_core.zig        UseCase       (netif_rx → RX_QUEUE 32, recvFromQueue)
  net/socket.zig          UseCase       (AF_INET/SOCK_*, socketCreate/bind/send/recv via netdev)
  security/caps.zig       Policy        (Cap net_raw/sys_admin, checkPermission LSM hook)
  lib/printk.zig          Infra         (printk Level emerg..debug → stdout)
  main.zig                Composition Root (init order + demos + 7 tests)
```

### Clean mapping

| Layer | Kernel analog | Zig location |
|-------|---------------|--------------|
| Entities | `task_struct`, `inode`, `mm_struct`, `sk_buff` | `sched.Task`, `vfs.Inode/Dentry`, `mm.Page/VmArea`, `skbuff.SkBuff` |
| Use Cases | `do_open`, `__schedule`, `handle_mm_fault`, `sock_sendmsg` | `syscall.sys_*`, `sched.schedule`, `socket.send/recv`, `net_core.netifRx` |
| Interface Adapters | `file_operations`, `sched_class`, `net_device_ops` | `vfs.FileOps`, `sched.SchedClass`, `net_device.NetOps` (comptime vtables) |
| Frameworks/Drivers | `arch/x86_64`, `drivers/net/e1000` | `arch/x86_64/*`, `drivers/*`, `e1000.E1000Regs/TxDesc/RxDesc` |

DIP in action: `net_core` + `socket` depend on `NetOps` interface, not `e1000`. Adding `virtio-net` = new `NetOps` impl, no core change — same as adding `btrfs` without touching VFS.

### Production-ready (kernel as Tier-0)

- **Testing** — pyramid: `mm`/`skbuff` unit → `vfs`/`sched` integration → `e1000 xmit→netif_rx` E2E → `syscall dispatch` — 7 tests, fail breaks build (`zig build test`)
- **Observability** — `printk` 8 levels, dmesg analog, `netif_rx` debug + `irq_count` counters (ftrace/eBPF analog: add ring buffer)
- **Reliability** — per-CPU `rq` simulated, `SchedClass` extension point mirrors `sched_ext` BPF; `net_core` drops on queue full (backpressure)
- **Deploy** — `zig build` is CI; LTS gate = `zig build test`; bare-metal = extend `boot.zig` (+GDT/IDT/paging) + `linker.ld`

## End-to-end hardware driver — Intel e1000 (82540EM)

**File: `src/drivers/net/e1000.zig` (165 lines)** — see `docs/driver-guide.md` for annotated walk.

1. **PCI probe** — `driver.registerDriver({name="e1000", bus=.pci, probe=e1000_probe})` + `registerDevice({name="0000:00:03.0", bus=.pci, irq=11})` → bus binds `probe` → `try netdev.register({name="eth0", mac=52:54:..., ops=&e1000_ops})` (analog `alloc_etherdev` + `register_netdev` + `request_irq`)
2. **BAR/MMIO** — simulated `E1000Regs {ctrl,status,tctl,rctl,tdbal,tdlen,tdh,tdt,...,ims,icr}` at `mmio_mem[4096]`; `dev.mmio_base = @intFromPtr(&mmio_mem)` (real: `ioremap(BAR0)`)
3. **Open** — `e1000_open` programs `ctrl RST | tctl enable | rctl enable | tdbal/tdlen/rdlen | ims 0xFF`, fills RX ring with `skbuff.alloc()` (DMA `addr=@intFromPtr(skb)`)
4. **Xmit** — `e1000_xmit(dev, skb)` places `TxDesc{addr=@intFromPtr(skb.data), length, cmd=EOP|IFCS|RS}` at `tx_ring[tdt]`, bumps `tdt`, sets `status DD + icr TXDW`, irqs `irq_count++`; loopback clones to `rx_skb → net_core.netifRx` (real HW: wire→RX ring→IRQ→`napi_gro_receive`)
5. **IRQ/RX** — `e1000_open` pre-fills RX descriptors; xmit's loopback fills `rx_ring[idx].status=DD`, `icr RXO`; `netifRx` queues to `RX_QUEUE 32` for `socket.recv()`

Socket demo proves loop: `socket(AF_INET,SOCK_DGRAM) → bind → send("HELLO…") → e1000_xmit → DMA→DD→netif_rx → recv() → 72B back`.

Bare-metal extensions: replace `mmio_mem` with volatile `*E1000Regs @intFromPtr(BAR0)`, DMA with `std.os.linux` `mmap(MAP_LOCKED)`, IRQs with `IDT[32+vect]` + `request_irq` via APIC, rings with `dma_alloc_coherent`.

## Verifying architecture correctness

- Correct: monolithic+LKMs verified via `linux-kernel-architecture.md` (DeepWiki gregkh/linux 1.1, kernel.org/doc); 6 subsystems enumerated; syscall ~450 → here 9 distilled; `file_operations`/`sched_class` vtables preserved via Zig comptime structs.
- Trade-off documented: hosted simulates `PAGE_SIZE 4096`, `MAX_PAGES 256`, loopback instead of wire; bare-metal delta is ~80 lines (GDT/IDT/paging/APIC) — left as exercise with hints in `docs/architecture.md`.

## See also

- `docs/architecture.md` — layered diagram (ASCII), data-flow VFS↔MM, syscall sequence
- `docs/driver-guide.md` — e1000 line-by-line + add-your-own-virtio checklist
- `docs/qemu-verification-guide.md` — QEMU setup and bare-metal verification
- `docs/comparison-vinix-omarchy.md` — Feature matrix vs vinix and Omarchy
- `../linux-kernel-architecture.md` + `../linux-kernel-diagrams.html` — production analysis that drove this impl