# Architecture — Zig Linux Kernel

Monolithic + LKMs. Hosted simulation of x86_64 Linux 6.x. Matches `@12-factor-agents/linux-kernel-architecture.md`.

## 1. Layered view (Clean Architecture projection)

```
┌─────────────────────────────────────────────────────────────────┐
│ User Space (Ring 3) — toCStr helpers, socket/VFS calls via      │
│ syscall() → entry.dispatch  (libc analog)                       │
├─────────────────────────────────────────────────────────────────┤
│ Controller — syscall boundary  src/syscall.zig                  │
│  table[32] dispatch + 9 handlers → translate args → use cases   │
│  open/read/write/close/socket/bind/send/recv/ioctl             │
├─────────────────────────────────────────────────────────────────┤
│ Use Cases + Entities (mixed — kernel pragmatism, not pure Clean)│
│  sched/sched.zig  Task{pid,name,state} + SchedClass vtable      │
│  mm/mm.zig        Page+VmArea + allocPage/Slab(T,cap)           │
│  net/socket.zig   socketCreate/bind/send/recv (orchestrates)    │
│  net/net_core.zig netifRx/recvFromQueue (RX_QUEUE 32)           │
│  vfs/vfs.zig      Inode/Dentry/File + FileOps vtable (ramfs)    │
│  security/caps.zig Cap enum, checkPermission LSM hook           │
├─────────────────────────────────────────────────────────────────┤
│ Adapters (DIP vtables — core depends on interface, not concrete)│
│  vfs.FileOps{open,read,write,ioctl}  → ramfs_ops (ext4 analog)  │
│  sched.SchedClass{pick_next,enqueue,dequeue} → cfs_class        │
│  net_device.NetOps{open,stop,xmit}   → e1000_ops                │
│  driver.Driver{probe}  BusType pci/platform/usb                  │
├─────────────────────────────────────────────────────────────────┤
│ Framework / HW (simulated; bare-metal adds GDT/IDT/paging)      │
│  arch/x86_64/boot.zig   earlyBoot banner                        │
│  arch/x86_64/entry.zig  SYSCALL_MAX=32, SyscallFn, dispatch     │
│  drivers/net/e1000.zig  E1000Regs, TxDesc/RxDesc rings, DMA     │
│  mm pages[256] 4096B, skbuff pool 64×2048, netdev dev_storage[8] │
└─────────────────────────────────────────────────────────────────┘
```

Dependency rule critique (kernel inverts for perf — sched touches NUMA, MM touches DMA — correct for OS; app should keep inward-only).

## 2. Data-flow — VFS ↔ MM integration

```
open("/hello.txt") → vfs.lookup linear dentry cache → Dentry{name,inode}
                   → vfs.open allocates File{dentry,inode,pos=0}
read(fd, buf)      → entry.dispatch(NR.read) → vfs.read → FileOps.read
                   → ramfs_read: inode.data[ pos .. pos+len ] → copy → pos+=n
                                        ↑
                page cache analog: address_space ops would fault → ext4_map_blocks
                here: direct data slice (hosted). Bare-metal: handle_mm_fault → buddy page
```

Per-CPU sheaves: simulated as `SchedClass` per-CPU `rq` (single slot here); NUMA migration: `sched.runNext()` round-robins tasks — real kernel migrates toward `mm_struct` locality.

## 3. Sequence — open/read + scheduler + network

```
User: fd = syscall(NR.open, cstr("/hello.txt"))
  → entry.dispatch(0, ptr,0,0) → sys_open → vfs.open → alloc Fd slot → 0
User: n = syscall(NR.read, fd, buf_ptr, 128)
  → entry.dispatch(1, fd, buf, len) → vfs.read → ramfs_read → 33B

Scheduler (tick):
  sched.runNext() → active_class.pick_next() → cfs_pick_next round-robin
                → task.entry() → ticks++ → runnable

Network (socket → driver → IRQ → netif_rx):
  syscall(NR.socket, AF_INET, SOCK_DGRAM, 0) → socketCreate → fd=100
  syscall(NR.send,  fd, msg_ptr, 72) → socket.send → netdev.transmit(eth0, skb)
      → e1000_xmit: TxDesc{addr, len, cmd=EOP|IFCS|RS} @ tdt → tdt++
                 → status DD, icr TXDW, irq_count++
                 → clone rx_skb → net_core.netifRx(rx_skb) → RX_QUEUE++
  syscall(NR.recv,  fd, buf, 256) → socket.recv → net_core.recvFromQueue → 72B
```

## 4. Bare-metal delta (≈80 lines)

Hosted simulates; add for QEMU `-kernel zig-out/bin/zig-kernel-freestanding`:

- `arch/x86_64/boot.zig`: GDT (code/data), IDT[256], enable long mode, `paging.init()` identity map
- `arch/x86_64/entry.zig`: `IDT[0x80]=syscall_entry` asm `syscall`/`sysret`, `cli/sti`
- `mm/mm.zig`: replace `pages[256]` bump with `PML4` walker + `bump + buddy over 0x100000`
- `drivers/net/e1000.zig`: `volatile *E1000Regs @intFromPtr(BAR)` + `dma_alloc_coherent` for rings
- `linker.ld` already present; add `build.zig` freestanding target (see git history — removed for brevity, re-add from template)

Refs: kernel.org/doc Documentation/x86/boot.rst, Intel 82540EM datasheet, `gregkh/linux` 1.1 tree.
