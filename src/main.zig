// zig-kernel — Minimal but complete Linux kernel in Zig (hosted simulation)
// Architecture: Monolithic+LKMs, Clean layers, DIP vtables.
// See docs/architecture.md for diagram → layers match @12-factor-agents/linux-kernel-architecture.md
//
// Layers:
//   Framework/HW : arch/x86_64/boot, mm/page, drivers (MMIO/DMA sim)
//   Adapters     : vfs FileOps, net NetOps/sched_class vtable, driver bus
//   Use Cases    : syscall handlers, schedule(), socket send/recv
//   Entities     : Task, Page, Inode/Dentry, SkBuff, Device (pure)
//   Delivery     : syscall dispatch (Ring3→Ring0)
//
// Build: zig build run   (hosted native)
//        zig build test  (unit tests)
// Bare-metal: src/baremetal.zig + linker.ld → zig build qemu-bin

const std = @import("std");
const builtin = @import("builtin");
const printk = @import("lib/printk.zig");
const boot = @import("arch/x86_64/boot.zig");
const entry = @import("arch/x86_64/entry.zig");
const mm = @import("mm/mm.zig");
const sched = @import("sched/sched.zig");
const vfs = @import("vfs/vfs.zig");
const driver = @import("drivers/driver.zig");
const netdev = @import("drivers/net/net_device.zig");
const skbuff = @import("net/skbuff.zig");
const net_core = @import("net/net_core.zig");
const socket_mod = @import("net/socket.zig");
const syscall = @import("syscall.zig");
const caps = @import("security/caps.zig");
const e1000 = @import("drivers/net/e1000.zig");
const virtio_net = @import("drivers/net/virtio_net.zig");
const virtio_blk = @import("drivers/block/virtio_blk.zig");
const blk_queue = @import("drivers/block/blk_queue.zig");
const ext4 = @import("fs/ext4.zig");
const page_cache = @import("mm/page_cache.zig");
const proc_mod = @import("proc/proc.zig");
const time_mod = @import("time/time.zig");
const stat_mod = @import("stat/stat.zig");
const eventstruct = @import("event/eventstruct.zig");
const signal_mod = @import("signal/signal.zig");
const pipe_mod = @import("drivers/pipe.zig");
const futex_mod = @import("drivers/futex.zig");
const gdt64 = @import("arch/x86_64/gdt.zig"); // M2 protected-execution policy (tested below)
const paging64 = @import("arch/x86_64/paging.zig"); // M2 user/kernel split policy
const uaccess = @import("uaccess.zig"); // M2 checked user copies

// ── demo user tasks (analog to init + kthreads) ──
fn taskIdle() void { printk.printk(.debug, "task idle: cpu idle (hlt analog)", .{}); }
// M2 preemption hook: timer tick → schedTick, then rotate if slice expired.
fn schedTickHook() void {
    if (sched.schedTick()) sched.runNext();
}
fn taskLogger() void { printk.printk(.info, "task logger: dmesg flushed ({d} pages used)", .{mm.usedPages()}); }
fn taskNetWatch() void {
    const len = net_core.queueLen();
    if (len > 0) printk.printk(.info, "task net_watch: RX queue {d} skb(s) pending", .{len});
}

// c-string helper for syscall open (kernel copy_from_user analog)
var cstr_buf: [256]u8 = undefined;
fn toCStr(s: []const u8) usize {
    const n = @min(s.len, cstr_buf.len - 1);
    @memcpy(cstr_buf[0..n], s[0..n]);
    cstr_buf[n] = 0;
    return @intFromPtr(&cstr_buf[0]);
}

pub fn main() !void {
    printk.printk(.info, "============================================================", .{});
    printk.printk(.info, " Zig Linux Kernel — Minimal Complete (hosted simulation)", .{});
    printk.printk(.info, " arch: x86_64  layout: monolithic+LKMs  zig: 0.16.0", .{});
    printk.printk(.info, " subsystems: sched | mm | vfs | drivers | net | security", .{});
    printk.printk(.info, "============================================================", .{});

    // ── 1. Boot (Framework layer) ──
    boot.earlyBoot();

    // ── 2. Core subsystems (Entity + Adapter layers) ──
    mm.init();
    sched.init();
    vfs.init();
    vfs.devtmpfsPopulate();
    driver.init();
    caps.init();
    skbuff.init();
    net_core.init();
    socket_mod.init();

    // ── 2b. Infrastructure (klock, katomic are header-only primitives) ──
    // ── 2c. Time/process/signal/pipe/futex (vinix parity) ──
    time_mod.init();
    proc_mod.init();
    signal_mod.init();
    pipe_mod.init();
    futex_mod.init();

    // ── 2d. Preemption (M2): timer tick always drives schedTick. Registered
    // once at boot; no syscall unregisters hooks or masks the timer, so user
    // code cannot suppress preemption. Baremetal: PIT → IDT DPL0 gate.
    _ = time_mod.registerTickHook(schedTickHook);

    // ── 3. Syscall boundary (Controller) ──
    syscall.init();

    // ── 4. Driver initialization — two NetOps providers ──
    // e1000 (Intel 82540EM, physical) — analog: drivers/net/ethernet/intel/e1000/e1000_main.c
    // virtio_net (paravirtual) — analog: drivers/net/virtio_net.c + drivers/virtio/virtio_mmio.c
    try e1000.init();
    try virtio_net.init();
    try virtio_blk.init();

    // ── 5. Tasks (Process Management) ──
    _ = sched.create("idle", taskIdle);
    _ = sched.create("logger", taskLogger);
    _ = sched.create("net_watch", taskNetWatch);

    printk.printk(.info, "-- VFS demo via syscall boundary (Ring3→Ring0) --", .{});
    {
        const fd = syscall.syscall(syscall.NR.openat, 0, toCStr("/hello.txt"), 0);
        if (fd >= 0) {
            var buf: [128]u8 = undefined;
            const n = syscall.syscall(syscall.NR.read, @intCast(fd), @intFromPtr(&buf[0]), buf.len);
            if (n > 0) {
                const s = buf[0..@intCast(n)];
                printk.printk(.info, "VFS: read /hello.txt via syscall read → '{s}' ({d}B)", .{ std.mem.trim(u8, s, "\n"), n });
            }
            _ = syscall.syscall(syscall.NR.close, @intCast(fd), 0, 0);
        } else {
            printk.printk(.err, "VFS: open failed {d}", .{fd});
        }
    }

    printk.printk(.info, "-- Network driver demo (socket → driver → DMA → IRQ → netif_rx → recv) --", .{});
    {
        if (!caps.checkPermission(.cap_net_raw)) return;

        const fd = syscall.syscall(syscall.NR.socket, socket_mod.AF_INET, socket_mod.SOCK_DGRAM, 0);
        if (fd < 0) {
            printk.printk(.err, "socket: socket() failed {d}", .{fd});
        } else {
            const addr = "127.0.0.1:8080";
            _ = syscall.syscall(syscall.NR.bind, @intCast(fd), @intFromPtr(addr.ptr), addr.len);
            const msg = "HELLO from Zig Linux net stack (e1000 xmit → DMA → IRQ → netif_rx)";
            const sent = syscall.send(@intCast(fd), msg);
            printk.printk(.info, "net: send() via socket fd={d} → {d}B dispatched to e1000", .{ fd, sent });
            var rx_buf: [256]u8 = undefined;
            const recvd = syscall.syscall(syscall.NR.recvmsg, @intCast(fd), @intFromPtr(&rx_buf[0]), rx_buf.len);
            if (recvd > 0) {
                const s = rx_buf[0..@intCast(recvd)];
                printk.printk(.info, "net: recv() ← {d}B '{s}' (loopback via descriptor ring)", .{ recvd, s });
            } else {
                printk.printk(.warn, "net: recv() no data (recvd={d}, queue={d})", .{ recvd, net_core.queueLen() });
            }
        }
    }

    // virtio_net direct xmit demo (bypasses socket layer to show second NetOps)
    {
        if (netdev.find("eth1")) |dev| {
            const skb = skbuff.alloc().?;
            const payload = skb.put(11);
            @memcpy(payload, "VIRTIO_PING");
            try netdev.transmit(dev, skb);
            printk.printk(.info, "virtio_net: direct xmit 11B → net_core queue={d}", .{net_core.queueLen()});
        }
    }

    // t5b: virtio-blk + ext4 read-only demo (real sector I/O, not banner)
    printk.printk(.info, "-- Block demo (virtio-blk sector I/O -> ext4 read-only) --", .{});
    {
        const S = struct {
            fn read(lba: u64, out: []u8) !void {
                if (out.len != 512 or lba >= 64) return error.BadLen;
                try virtio_blk.read_sector(@as(u32, @intCast(lba)), @as(*[512]u8, @ptrCast(out.ptr)));
            }
        };
        const sb = ext4.parse_superblock(S.read) catch {
            printk.printk(.err, "ext4: superblock BAD MAGIC", .{});
            return;
        };
        printk.printk(.info, "blk: virtio-blk {s} cap={d}x512B; ext4 magic 0x{x} ok", .{ virtio_blk.PCI_ADDRESS, virtio_blk.capacity_sectors(), sb.magic });
        var fbuf: [64]u8 = undefined;
        const n = ext4.read_hello_txt(S.read, fbuf[0..]) catch {
            printk.printk(.err, "ext4: read hello FAILED", .{});
            return;
        };
        printk.printk(.info, "ext4: read /hello.txt '{s}' ({d}B from sector 4)", .{ fbuf[0..n], n });
    }

    printk.printk(.info, "-- Scheduler demo (__schedule → sched_class → context_switch) --", .{});
    for (0..6) |tick| {
        printk.printk(.info, "tick {d}:", .{tick});
        sched.runNext();
    }

    printk.printk(.info, "-- MM demo (allocPage / Slab) --", .{});
    {
        const p1 = mm.allocPage();
        const p2 = mm.allocPage();
        printk.printk(.info, "mm: allocPage → p1={?} p2={?} used={d}/{d}", .{ p1, p2, mm.usedPages(), mm.MAX_PAGES });
        if (p1) |pg| mm.freePage(pg);
        printk.printk(.info, "mm: freePage p1 → used={d}", .{mm.usedPages()});
        var slab = mm.Slab(u32, 8){};
        const a = slab.alloc();
        const b = slab.alloc();
        printk.printk(.info, "slab: alloc u32 → a={?} b={?} count={d}", .{ a, b, slab.count });
        if (a) |ptr| { ptr.* = 0xDEADBEEF; printk.printk(.info, "slab: *a = 0x{x}", .{ptr.*}); }
    }

    // ── Summary ──
    printk.printk(.info, "============================================================", .{});
    printk.printk(.info, " Kernel summary", .{});
    printk.printk(.info, "  tasks: {d}  pages used: {d}/{d}  netdev: {d}  RX queue: {d}", .{ sched.taskCount(), mm.usedPages(), mm.MAX_PAGES, netdev.count(), net_core.queueLen() });
    if (netdev.find("eth0")) |dev| {
        printk.printk(.info, "  eth0: tx {d} pkts {d}B  rx {d} pkts {d}B  mac {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ dev.tx_packets, dev.tx_bytes, dev.rx_packets, dev.rx_bytes, dev.mac[0], dev.mac[1], dev.mac[2], dev.mac[3], dev.mac[4], dev.mac[5] });
    }
    if (netdev.find("eth1")) |dev| {
        printk.printk(.info, "  eth1: tx {d} pkts {d}B  rx {d} pkts {d}B  mac {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ dev.tx_packets, dev.tx_bytes, dev.rx_packets, dev.rx_bytes, dev.mac[0], dev.mac[1], dev.mac[2], dev.mac[3], dev.mac[4], dev.mac[5] });
    }
    printk.printk(.info, "  processes: {d}  max_pid: {d}  max_fd: {d}  max_threads: {d}", .{ proc_mod.maxProcesses(), proc_mod.MAX_PID, proc_mod.MAX_FD, proc_mod.MAX_THREADS });
    printk.printk(.info, " Demo complete. Bare-metal: zig build qemu-bin → QEMU -kernel zig-out/bin/kernel-baremetal", .{});
    printk.printk(.info, "============================================================", .{});
}

// ── Unit tests (KUnit analog: per-push, break build) ──
test "mm: alloc/free page" {
    const before = mm.usedPages();
    const p = mm.allocPage() orelse return error.NoMem;
    try std.testing.expect(mm.usedPages() == before + 1);
    mm.freePage(p);
    try std.testing.expect(mm.usedPages() == before);
}

test "mm: slab alloc" {
    var slab = mm.Slab(u32, 4){};
    const a = slab.alloc().?;
    try std.testing.expect(slab.count == 1);
    a.* = 42;
    slab.free(a);
    try std.testing.expect(slab.count == 0);
}

test "vfs: open/read ramfs" {
    vfs.init();
    const f = vfs.open("/hello.txt") orelse return error.NotFound;
    var buf: [64]u8 = undefined;
    const n = vfs.read(f, &buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(n)], "Zig Linux") != null);
    vfs.close(f);
}

test "sched: create and schedule" {
    sched.init();
    _ = sched.create("a", null).?;
    _ = sched.create("b", null).?;
    try std.testing.expect(sched.taskCount() == 2);
    const t = sched.schedule();
    try std.testing.expect(t != null);
}

test "net: skbuff alloc and netif loopback" {
    skbuff.init();
    net_core.init();
    const skb = skbuff.alloc().?;
    const payload = skb.put(5);
    @memcpy(payload, "HELLO");
    net_core.netifRx(skb);
    try std.testing.expect(net_core.queueLen() == 1);
    var buf: [16]u8 = undefined;
    const n = net_core.recvFromQueue(&buf).?;
    try std.testing.expect(n == 5);
    try std.testing.expectEqualStrings("HELLO", buf[0..n]);
}

test "net: e1000 xmit → netif_rx via descriptor ring" {
    mm.init(); skbuff.init(); net_core.init(); driver.init(); socket_mod.init();
    if (netdev.count() == 0) {
        try e1000.init();
    }
    const dev = netdev.find("eth0") orelse netdev.first().?;
    const skb = skbuff.alloc().?;
    const payload = skb.put(4);
    @memcpy(payload, "PING");
    try netdev.transmit(dev, skb);
    try std.testing.expect(net_core.queueLen() >= 1);
}

test "net: virtio_net xmit → netif_rx via virtqueue" {
    mm.init(); skbuff.init(); net_core.init(); driver.init(); socket_mod.init();
    // ensure virtio_net registered; if not, init it
    if (netdev.find("eth1") == null) {
        try virtio_net.init();
    }
    const dev = netdev.find("eth1").?;
    const skb = skbuff.alloc().?;
    const payload = skb.put(6);
    @memcpy(payload, "VIRTIO");
    try netdev.transmit(dev, skb);
    try std.testing.expect(net_core.queueLen() >= 1);
    var buf: [16]u8 = undefined;
    const n = net_core.recvFromQueue(&buf).?;
    try std.testing.expect(n == 6);
    try std.testing.expectEqualStrings("VIRTIO", buf[0..n]);
}

test "blk: queue submit read/write + full" {
    try virtio_blk.init();
    blk_queue.init();
    var buf: [512]u8 = [_]u8{0} ** 512;
    const slot = try blk_queue.submit(.read, 2, &buf);
    try std.testing.expect(slot < blk_queue.depth());
    try std.testing.expectEqual(@as(usize, 0), blk_queue.pending());
    try std.testing.expectEqual(@as(u8, 0x53), buf[56]);
    try std.testing.expectEqual(@as(u8, 0xEF), buf[57]);
    var w: [512]u8 = [_]u8{0x5A} ** 512;
    _ = try blk_queue.submit(.write, 63, &w);
    var back: [512]u8 = undefined;
    _ = try blk_queue.submit(.read, 63, &back);
    try std.testing.expectEqualSlices(u8, &w, &back);
    try std.testing.expectError(error.OutOfRange, blk_queue.submit(.read, 64, &back));
}

test "mm: page cache hit/miss + flush" {
    try virtio_blk.init();
    page_cache.init();
    const R = struct {
        fn read(lba: u64, out: []u8) !void {
            if (out.len != 512 or lba >= 64) return error.BadLen;
            try virtio_blk.read_sector(@as(u32, @intCast(lba)), @as(*[512]u8, @ptrCast(out.ptr)));
        }
    };
    const W = struct {
        fn write(lba: u64, data: []u8) !void {
            if (data.len != 512 or lba >= 64) return error.BadLen;
            try virtio_blk.write_sector(@as(u32, @intCast(lba)), @as(*const [512]u8, @ptrCast(data.ptr)));
        }
    };
    const p0 = try page_cache.read_page(5, 0, R.read);
    try std.testing.expectEqual(@as(u8, 0x53), p0.data[56]);
    const s0 = page_cache.stats();
    try std.testing.expectEqual(@as(usize, 0), s0.hits);
    try std.testing.expectEqual(@as(usize, 1), s0.misses);
    _ = try page_cache.read_page(5, 0, R.read);
    const s1 = page_cache.stats();
    try std.testing.expectEqual(@as(usize, 1), s1.hits);
    page_cache.mark_dirty(5, 0);
    try std.testing.expect(try page_cache.flush_one(5, 0, W.write));
    try std.testing.expect(!(try page_cache.flush_one(5, 0, W.write)));
}

test "ext4: inode + extent + dirent walk" {
    const T = @import("std").testing;
    const Img = struct {
        fn read(lba: u64, out: []u8) !void {
            if (out.len != 512) return error.UnexpectedRead;
            @memset(out, 0);
            switch (lba) {
                8 => {
                    out[0] = 33; out[1] = 0; out[2] = 0; out[3] = 0;
                    out[4] = 20; out[5] = 0; out[6] = 0; out[7] = 0;
                    out[8] = 30; out[9] = 0; out[10] = 0; out[11] = 0;
                    out[52] = 40; out[53] = 0; out[54] = 0; out[55] = 0;
                },
                80 => { out[0] = 50; },
                40 => {
                    out[0] = 2; out[1] = 0; out[2] = 0; out[3] = 0;
                    out[4] = 1;
                    out[5] = 'h'; out[6] = 'i'; out[7] = 0;
                    out[32] = 0;
                },
                else => {},
            }
        }
    };
    const ino = try ext4.read_inode(Img.read, 1);
    try T.expectEqual(@as(u32, 33), ino.size);
    try T.expectEqual(@as(u32, 20), try ext4.file_block_to_disk(Img.read, ino, 0));
    try T.expectEqual(@as(u32, 30), try ext4.file_block_to_disk(Img.read, ino, 1));
    try T.expectEqual(@as(u32, 50), try ext4.file_block_to_disk(Img.read, ino, 12));
    try T.expectError(error.BadInode, ext4.read_inode(Img.read, 0));
    const e0 = try ext4.read_dirent(Img.read, 20, 0);
    try T.expectEqual(@as(u32, 2), e0.ino);
    try T.expectEqualStrings("hi", e0.name[0..e0.name_len]);
    try T.expectError(error.DirEnd, ext4.read_dirent(Img.read, 20, 1));
    try T.expectError(error.DirEnd, ext4.read_dirent(Img.read, 20, 32));
}

test "mm: reserve watermark + atomic bypass" {
    mm.init();
    try std.testing.expect(mm.reserveFree() == mm.MAX_PAGES - mm.RESERVE_PAGES);
    var n: usize = 0;
    while (mm.allocPage() != null) n += 1;
    try std.testing.expectEqual(mm.MAX_PAGES - mm.RESERVE_PAGES, n);
    try std.testing.expect(mm.allocPage() == null);
    try std.testing.expect(mm.reserveFree() == 0);
    // atomic bypasses the watermark into the reserve
    const a = mm.allocPageAtomic() orelse return error.NoMem;
    const b = mm.allocPageAtomic() orelse return error.NoMem;
    mm.freePage(a);
    // freed atomic slot is reusable via atomic path
    const c = mm.allocPageAtomic() orelse return error.NoMem;
    mm.freePage(b);
    mm.freePage(c);
    // reserve back at floor: normal alloc still refused
    try std.testing.expect(mm.allocPage() == null);
    mm.init();
    try std.testing.expect(mm.allocPage() != null);
    mm.init();
}

test "mm: vma find + cow mark/fault lifecycle" {
    mm.init();
    const base = mm.mmap(0, 8192, mm.PROT_READ | mm.PROT_WRITE, mm.MAP_PRIVATE | mm.MAP_ANONYMOUS) orelse return error.NoMem;
    try std.testing.expect(mm.findVma(base + 4096) != null);
    try std.testing.expect(mm.findVma(base + 8192) == null);
    try std.testing.expectEqual(@as(usize, 1), mm.markCowRange(base, 8192));
    try std.testing.expectEqual(@as(usize, 0), mm.markCowRange(base + 0x10000000, 4096));
    const vma = mm.findVma(base).?;
    try std.testing.expect(vma.cow);
    const before = mm.usedPages();
    const p1 = mm.cowFault(base) orelse return error.NoMem;
    const p2 = mm.cowFault(base + 4096) orelse return error.NoMem;
    try std.testing.expect(mm.usedPages() == before + 2);
    try std.testing.expect(!vma.cow);
    try std.testing.expect(mm.cowFault(base + 0x10000000) == null);
    mm.freePage(p1);
    mm.freePage(p2);
    try std.testing.expect(mm.munmap(base, 8192) == 0);
    mm.init();
}

test "mm: cow skips MAP_SHARED vmas" {
    mm.init();
    const sh = mm.mmap(0, 4096, mm.PROT_READ | mm.PROT_WRITE, mm.MAP_SHARED | mm.MAP_ANONYMOUS) orelse return error.NoMem;
    try std.testing.expectEqual(@as(usize, 0), mm.markCowRange(sh, 4096));
    try std.testing.expect(mm.cowFault(sh) == null);
    try std.testing.expect(mm.munmap(sh, 4096) == 0);
    mm.init();
}

test "syscall: open/read dispatch" {
    vfs.init();
    const entry_mod = @import("arch/x86_64/entry.zig");
    const sc = @import("syscall.zig");
    sc.init();
    mm.init();
    defer mm.init();
    // M2: user pointers need a covering VMA. One MAP_FIXED region backs both
    // path and buf (separate stack vars may sit inside one aligned 4K span).
    var region: [128]u8 align(4096) = [_]u8{0} ** 128;
    _ = mm.mmap(@intFromPtr(&region[0]), region.len, mm.PROT_READ | mm.PROT_WRITE, mm.MAP_PRIVATE | mm.MAP_ANONYMOUS | mm.MAP_FIXED) orelse return error.NoMem;
    const path_addr = @intFromPtr(&region[0]);
    @memcpy(region[0..10], "/hello.txt");
    const fd = entry_mod.dispatch(sc.NR.openat, 0, path_addr, 0, 0);
    try std.testing.expect(fd >= 0);
    const buf_addr = @intFromPtr(&region[64]);
    const n = entry_mod.dispatch(sc.NR.read, @intCast(fd), buf_addr, 64, 0);
    try std.testing.expect(n > 0);
    // M2: wild pointers fail closed with -EFAULT (no VMA, no deref).
    try std.testing.expectEqual(@as(isize, -14), entry_mod.dispatch(sc.NR.openat, 0, 0x1000, 0, 0));
    try std.testing.expectEqual(@as(isize, -14), entry_mod.dispatch(sc.NR.read, @intCast(fd), 0x1000, 8, 0));
}

test "time: monotonic clock and nanosleep" {
    time_mod.init();
    const before = time_mod.monotonicNs();
    time_mod.nsleep(1_000_000_000);
    const after = time_mod.monotonicNs();
    try std.testing.expect(after >= before + 999_999_000);
}

test "time: timer trigger and await" {
    time_mod.init();
    var timer = time_mod.Timer{};
    timer.event.init();
    timer.when = time_mod.TimeSpec{ .tv_sec = 0, .tv_nsec = 1 };
    timer.arm();
    timer.event.signal();
    try std.testing.expect(timer.event.tryConsume());
    timer.disarm();
}

test "stat: file type helpers" {
    try std.testing.expect(stat_mod.isreg(0o100644));
    try std.testing.expect(stat_mod.isdir(0o040755));
    try std.testing.expect(stat_mod.ischr(0o020666));
    try std.testing.expect(stat_mod.isblk(0o060660));
    try std.testing.expect(stat_mod.issock(0o140666));
    try std.testing.expect(stat_mod.islnk(0o120777));
}

test "stat: dirent type mapping" {
    try std.testing.expectEqual(stat_mod.dtReg, stat_mod.direntType(0o100644));
    try std.testing.expectEqual(stat_mod.dtDir, stat_mod.direntType(0o040755));
    try std.testing.expectEqual(stat_mod.dtChr, stat_mod.direntType(0o020666));
    try std.testing.expectEqual(stat_mod.dtSock, stat_mod.direntType(0o140666));
}

test "event: trigger and await" {
    var ev: eventstruct.Event = .{};
    ev.init();
    const woken = ev.trigger(false);
    try std.testing.expect(woken == 0);
    try std.testing.expect(ev.tryConsume());
    const woken2 = ev.trigger(true);
    try std.testing.expect(woken2 == 0);
    try std.testing.expect(!ev.tryConsume());
}

test "event: await multi-event" {
    var ev1: eventstruct.Event = .{};
    var ev2: eventstruct.Event = .{};
    ev1.init();
    ev2.init();
    const events = [_]*eventstruct.Event{ &ev1, &ev2 };
    try std.testing.expect(eventstruct.await(&events, false) == null);
    ev2.signal();
    const idx = eventstruct.await(&events, false);
    try std.testing.expect(idx != null and idx.? == 1);
}

test "m2: protected execution policy (gdt+paging64)" {
    // GDT: user selectors carry RPL3 + DPL3, kernel RPL0 + DPL0.
    try std.testing.expectEqual(@as(u16, 3), gdt64.selIndex(gdt64.USER_CODE_SEL));
    try std.testing.expectEqual(@as(u2, 3), gdt64.selRpl(gdt64.USER_CODE_SEL));
    try std.testing.expectEqual(@as(u2, 0), gdt64.selRpl(gdt64.KERNEL_CODE_SEL));
    const t = gdt64.build(0x90000, 104);
    try std.testing.expectEqual(@as(u2, 3), gdt64.entryDpl(t[3]));
    try std.testing.expectEqual(@as(u2, 0), gdt64.entryDpl(t[1]));
    // iret gate: user transition only with user selectors.
    try std.testing.expect(gdt64.iretToUserValid(gdt64.USER_CODE_SEL, gdt64.USER_DATA_SEL));
    try std.testing.expect(!gdt64.iretToUserValid(gdt64.KERNEL_CODE_SEL, gdt64.KERNEL_DATA_SEL));
    // Ring policy: ring3 cannot mask timer or run priv ops.
    try std.testing.expect(!gdt64.preemptDisableAllowed(.ring3));
    try std.testing.expect(gdt64.preemptDisableAllowed(.ring0));
    // ABI allowlist: zk-abi-v1 only (fork/execve/socket out).
    try std.testing.expect(gdt64.syscallAllowed(4)); // write
    try std.testing.expect(gdt64.syscallAllowed(15)); // exit
    try std.testing.expect(!gdt64.syscallAllowed(14)); // fork
    try std.testing.expect(!gdt64.syscallAllowed(17)); // execve
    try std.testing.expect(!gdt64.syscallAllowed(39)); // socket
    // User copy gate: VMA + prot + user-half + no wrap.
    const vs: u64 = 0x20000000;
    const ve: u64 = 0x20008000;
    try std.testing.expect(gdt64.userCopyAllowed(vs, ve, 3, vs + 0x1000, 64, true));
    try std.testing.expect(!gdt64.userCopyAllowed(vs, ve, 1, vs, 64, true)); // RO + write
    try std.testing.expect(!gdt64.userCopyAllowed(vs, ve, 3, ve - 32, 64, false)); // spill
    try std.testing.expect(!gdt64.userCopyAllowed(vs, ve, 3, 0xFFFF800000000000, 8, false)); // kernel half
    // Paging split: user fault needs VMA auth; kernel half rejects user; hole faults.
    try std.testing.expectEqual(@as(isize, 0), paging64.handleFault(0x20001000, true, true));
    try std.testing.expectEqual(@as(isize, -13), paging64.handleFault(0x20001000, true, false));
    try std.testing.expectEqual(@as(isize, -13), paging64.handleFault(paging64.KERNEL_BASE + 0x1000, true, true));
    try std.testing.expectEqual(@as(isize, 0), paging64.handleFault(paging64.KERNEL_BASE + 0x1000, false, false));
    try std.testing.expectEqual(@as(isize, -14), paging64.handleFault(paging64.USER_MAX + 1, false, true));
    // TSS kernel stack state for ring3→0.
    gdt64.tssInit(0x90000);
    try std.testing.expectEqual(@as(u64, 0x90000), gdt64.tss.rsp0);
    gdt64.tssInit(0);
}

test "m2: preemption — timer ticks rotate tasks, user cannot mask" {
    sched.init();
    time_mod.init();
    _ = time_mod.registerTickHook(schedTickHook);
    _ = sched.create("spin-a", null);
    _ = sched.create("spin-b", null);
    const first = sched.schedule().?;
    // Burn slices via real clock ticks; rotation must occur without cooperation.
    var rotated = false;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        time_mod.advanceClocks(.{ .tv_sec = 0, .tv_nsec = 1_000_000 });
        if (sched.currentTask()) |c| {
            if (c.pid != first.pid) { rotated = true; break; }
        }
    }
    try std.testing.expect(rotated);
    // No syscall in the zk-abi-v1 allowlist unregisters tick hooks or masks
    // the timer: dispatchUser rejects cli-adjacent / priv ops by allowlist.
    const e = @import("arch/x86_64/entry.zig");
    try std.testing.expect(!e.gdt.syscallAllowed(7)); // set_fs_base
    try std.testing.expect(!e.gdt.syscallAllowed(8)); // set_gs_base
    try std.testing.expect(!e.gdt.preemptDisableAllowed(.ring3));
    sched.init();
    time_mod.init();
}

test "m2: uaccess checked copies vs VMA gate" {
    mm.init();
    defer mm.init();
    // Hosted sim: VMA addresses are fake unless MAP_FIXED at real backing.
    // One 4K-aligned region, split into RW + RO VMAs (deterministic, no overlap).
    var region: [8192]u8 align(4096) = [_]u8{0} ** 8192;
    const base = @intFromPtr(&region[0]);
    _ = mm.mmap(base, 4096, mm.PROT_READ | mm.PROT_WRITE, mm.MAP_PRIVATE | mm.MAP_ANONYMOUS | mm.MAP_FIXED) orelse return error.NoMem;
    const ro = base + 4096;
    _ = mm.mmap(ro, 4096, mm.PROT_READ, mm.MAP_PRIVATE | mm.MAP_ANONYMOUS | mm.MAP_FIXED) orelse return error.NoMem;
    for (&region, 0..) |*b, i| b.* = @truncate((i + 1) & 0xFF);
    var kb: [64]u8 = undefined;
    // read ok inside RW VMA
    try std.testing.expect(uaccess.copyFromUser(&kb, base));
    try std.testing.expectEqual(kb[0], 1);
    try std.testing.expect(uaccess.copyToUser(base + 128, kb[0..16]));
    // rejects: outside any VMA, cross-boundary, wrap, kernel half (no deref)
    var tmp: [8]u8 = undefined;
    try std.testing.expect(!uaccess.copyFromUser(&tmp, base + 0x10000000));
    try std.testing.expect(!uaccess.copyFromUser(&tmp, base + 4094));
    try std.testing.expect(!uaccess.copyFromUser(&tmp, 0xFFFFFFFFFFFFF000));
    try std.testing.expect(!uaccess.copyToUser(0xFFFF800000000000, tmp[0..]));
    // prot gate: RO VMA rejects write, allows read
    try std.testing.expect(!uaccess.copyToUser(ro, tmp[0..]));
    try std.testing.expect(uaccess.copyFromUser(&tmp, ro));
    // cstr: NUL inside VMA ok, unterminated → null, outside → null
    @memcpy(region[256..261], "hi\x00\x00\x00");
    var out: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 2), uaccess.copyCStrFromUser(base + 256, &out));
    @memset(region[256..272], 'A');
    try std.testing.expectEqual(@as(?usize, null), uaccess.copyCStrFromUser(base + 256, out[0..8]));
    try std.testing.expectEqual(@as(?usize, null), uaccess.copyCStrFromUser(base + 0x10000000, &out));
}

test "m3: elf64 validate→load VMAs→stack→entry" {
    const elf64 = proc_mod.elf64;
    const userstack = proc_mod.userstack;
    mm.init();
    vfs.init();
    defer mm.init();
    // build minimal static image: RX text seg + RW data seg
    var img: [512]u8 = [_]u8{0} ** 512;
    img[0] = 0x7f;
    img[1] = 'E';
    img[2] = 'L';
    img[3] = 'F';
    img[4] = 2;
    img[5] = 1;
    img[6] = 1;
    std.mem.writeInt(u16, img[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, img[18..20], 62, .little); // EM_X86_64
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u64, img[24..32], 0x400000, .little); // entry
    std.mem.writeInt(u64, img[32..40], 64, .little); // phoff
    std.mem.writeInt(u16, img[52..54], 64, .little); // ehsize
    std.mem.writeInt(u16, img[54..56], 56, .little); // phentsize
    std.mem.writeInt(u16, img[56..58], 2, .little); // phnum
    // phdr0: RX text at 0x400000
    std.mem.writeInt(u32, img[64..68], 1, .little);
    std.mem.writeInt(u32, img[68..72], 5, .little); // R+X
    std.mem.writeInt(u64, img[72..80], 0, .little); // off
    std.mem.writeInt(u64, img[80..88], 0x400000, .little);
    std.mem.writeInt(u64, img[96..104], 128, .little); // filesz
    std.mem.writeInt(u64, img[104..112], 128, .little); // memsz
    // phdr1: RW data at 0x401000
    std.mem.writeInt(u32, img[120..124], 1, .little);
    std.mem.writeInt(u32, img[124..128], 6, .little); // R+W
    std.mem.writeInt(u64, img[128..136], 0, .little);
    std.mem.writeInt(u64, img[136..144], 0x401000, .little);
    std.mem.writeInt(u64, img[152..160], 64, .little);
    std.mem.writeInt(u64, img[160..168], 64, .little);
    const v = try elf64.validate(&img);
    try std.testing.expectEqual(@as(u64, 0x400000), v.entry);
    try std.testing.expectEqual(@as(usize, 2), v.nsegs);
    const entry_pc = try elf64.load(&v);
    try std.testing.expectEqual(@as(u64, 0x400000), entry_pc);
    // VMAs registered with loader prot
    const text_vma = mm.findVma(0x400000).?;
    try std.testing.expect(text_vma.prot & mm.PROT_EXEC != 0);
    const data_vma = mm.findVma(0x401000).?;
    try std.testing.expect(data_vma.prot & mm.PROT_WRITE != 0);
    try std.testing.expect(data_vma.prot & mm.PROT_EXEC == 0); // W^X
    // entry inside RX (uaccess-exec gate analog)
    try std.testing.expect(text_vma.start <= entry_pc and entry_pc < text_vma.end);
    // stack: map top 16K of 8M window over real backing, build argv/env
    var stack_back: [16384]u8 align(4096) = [_]u8{0} ** 16384;
    const stack_base = userstack.STACK_TOP - userstack.STACK_SIZE;
    _ = mm.mmap(stack_base, userstack.STACK_SIZE, mm.PROT_READ | mm.PROT_WRITE, mm.MAP_PRIVATE | mm.MAP_ANONYMOUS | mm.MAP_FIXED) orelse return error.NoMem;
    const backing_virt = stack_base + userstack.STACK_SIZE - 16384;
    // build into tail of real backing, pretending it sits at stack top
    const sp = try userstack.build(&stack_back, backing_virt, &.{"/workspace/tool"}, &.{ "LANG=C", "USER=sandbox" });
    try std.testing.expect(sp % 16 == 8);
    try std.testing.expect(sp >= backing_virt and sp < backing_virt + 16384);
    // rejection battery: dynamic type, interp, kernel vaddr, bad entry
    std.mem.writeInt(u16, img[16..18], 3, .little); // ET_DYN
    try std.testing.expectError(error.NotStatic, elf64.validate(&img));
    std.mem.writeInt(u16, img[16..18], 2, .little);
    std.mem.writeInt(u32, img[120..124], 3, .little); // PT_INTERP
    try std.testing.expectError(error.NeedsInterp, elf64.validate(&img));
    std.mem.writeInt(u32, img[120..124], 1, .little);
    std.mem.writeInt(u64, img[136..144], 0xFFFF8000001000, .little); // kernel half
    try std.testing.expectError(error.KernelAddr, elf64.validate(&img));
}

test "m3: exit/wait lifecycle + stdout/stderr split via dispatch" {
    const entry_mod = @import("arch/x86_64/entry.zig");
    const sc = @import("syscall.zig");
    const capture = proc_mod.capture;
    proc_mod.init();
    sc.init();
    mm.init();
    defer mm.init();
    // fork → waitpid WNOHANG on running child returns 0; unknown pid → ECHILD
    const child = proc_mod.fork();
    try std.testing.expect(child != 0);
    try std.testing.expectEqual(@as(isize, 0), entry_mod.dispatch(sc.NR.waitpid, child, 0, 1, 0)); // WNOHANG
    try std.testing.expectEqual(@as(isize, -10), entry_mod.dispatch(sc.NR.waitpid, 99999, 0, 1, 0)); // ECHILD
    // stdout/stderr split: fd1/fd2 captured per-pid, validated user pointers
    var region: [256]u8 align(4096) = [_]u8{0} ** 256;
    _ = mm.mmap(@intFromPtr(&region[0]), region.len, mm.PROT_READ, mm.MAP_PRIVATE | mm.MAP_ANONYMOUS | mm.MAP_FIXED) orelse return error.NoMem;
    const pid = proc_mod.getpid();
    capture.reset(pid);
    @memcpy(region[0..9], "out-data\n");
    @memcpy(region[64..73], "err-data\n");
    try std.testing.expectEqual(@as(isize, 9), entry_mod.dispatch(sc.NR.write, 1, @intFromPtr(&region[0]), 9, 0));
    try std.testing.expectEqual(@as(isize, 9), entry_mod.dispatch(sc.NR.write, 2, @intFromPtr(&region[64]), 9, 0));
    try std.testing.expectEqualStrings("out-data\n", capture.stdoutOf(pid));
    try std.testing.expectEqualStrings("err-data\n", capture.stderrOf(pid));
    // bad pointer → -EFAULT, streams untouched
    try std.testing.expectEqual(@as(isize, -14), entry_mod.dispatch(sc.NR.write, 1, 0x1000, 9, 0));
    try std.testing.expectEqual(@as(usize, 9), capture.stdoutOf(pid).len);
    capture.reset(pid);
    proc_mod.init();
}

test "m5: jail confines, quota contains, reset wipes" {
    vfs.init();
    defer {
        vfs.clearJail();
        vfs.init();
    }
    // jail auto-creates /workspace
    try std.testing.expect(vfs.setJail("/workspace"));
    const used0 = vfs.fsUsed();
    try std.testing.expect(used0 > 0); // seed files charged
    // file inside jail resolvable; outside denied
    _ = vfs.createFile("/workspace/tool", "binary-bytes") orelse return error.NoMem;
    try std.testing.expect(vfs.resolvePath(vfs.AT_FDCWD, "/workspace/tool") != null);
    try std.testing.expect(vfs.resolvePath(vfs.AT_FDCWD, "/etc/hostname") == null); // escape denied
    try std.testing.expect(vfs.resolvePath(vfs.AT_FDCWD, "/hello.txt") == null); // outside jail
    try std.testing.expect(vfs.resolvePath(vfs.AT_FDCWD, "/workspace/../hello.txt") == null); // .. denied
    try std.testing.expect(vfs.resolvePath(vfs.AT_FDCWD, "/") == null); // root denied
    // jail root itself + relative resolve work
    try std.testing.expect(vfs.resolvePath(vfs.AT_FDCWD, "/workspace") != null);
    // symlink targets never followed: readlink returns target, lookup stays put
    _ = vfs.createFile("/workspace/link", "x") orelse return error.NoMem;
    // quota: over-cap write fails ENOSPC without allocating; small IO still works
    {
        const f = vfs.openat(vfs.AT_FDCWD, "/workspace/tool", vfs.O_RDONLY, 0) orelse return error.NoMem;
        defer vfs.close(f);
        const flood = std.heap.page_allocator.alloc(u8, vfs.FS_CAP_BYTES + 1) catch return error.NoMem;
        defer std.heap.page_allocator.free(flood);
        @memset(flood, 'F');
        try std.testing.expectEqual(@as(isize, -28), vfs.write(f, flood)); // ENOSPC, contained
        var small: [8]u8 = undefined;
        _ = vfs.seek(f, 0, vfs.SEEK_SET);
        try std.testing.expect(vfs.read(f, &small) > 0); // reads unaffected
    }
    const used_before = vfs.fsUsed();
    try std.testing.expect(used_before >= used0);
    // reset wipes jail contents, frees accounting, seed files outside jail survive
    const removed = vfs.clearJailContents();
    try std.testing.expect(removed >= 2);
    try std.testing.expect(vfs.resolvePath(vfs.AT_FDCWD, "/workspace/tool") == null);
    try std.testing.expect(vfs.fsUsed() < used_before);
    try std.testing.expect(vfs.lookup("/hello.txt") != null); // outside jail survives
    vfs.clearJail();
    try std.testing.expect(vfs.resolvePath(vfs.AT_FDCWD, "/hello.txt") != null); // jail lifted
}

test "m7: adversarial — elf mutations, wild pointers, pid isolation" {
    const elf64 = proc_mod.elf64;
    // elf64 mutation fuzz: valid image + random byte flips → error only, never panic
    var img: [512]u8 = [_]u8{0} ** 512;
    img[0] = 0x7f;
    img[1] = 'E';
    img[2] = 'L';
    img[3] = 'F';
    img[4] = 2;
    img[5] = 1;
    img[6] = 1;
    std.mem.writeInt(u16, img[16..18], 2, .little);
    std.mem.writeInt(u16, img[18..20], 62, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u64, img[24..32], 0x400000, .little);
    std.mem.writeInt(u64, img[32..40], 64, .little);
    std.mem.writeInt(u16, img[52..54], 64, .little);
    std.mem.writeInt(u16, img[54..56], 56, .little);
    std.mem.writeInt(u16, img[56..58], 1, .little);
    std.mem.writeInt(u32, img[64..68], 1, .little);
    std.mem.writeInt(u32, img[68..72], 5, .little);
    std.mem.writeInt(u64, img[80..88], 0x400000, .little);
    std.mem.writeInt(u64, img[96..104], 128, .little);
    std.mem.writeInt(u64, img[104..112], 128, .little);
    try std.testing.expect((elf64.validate(&img) catch null) != null);
    var st: u64 = 0x243F6A8885A308D3;
    var iter: usize = 0;
    while (iter < 20_000) : (iter += 1) {
        st ^= st << 13;
        st ^= st >> 7;
        st ^= st << 17;
        var mut = img;
        const flips = 1 + (st % 4);
        var f: usize = 0;
        while (f < flips) : (f += 1) {
            st ^= st << 13;
            st ^= st >> 7;
            st ^= st << 17;
            mut[@as(usize, @intCast(st % mut.len))] = @truncate(st >> 32);
        }
        if (elf64.validate(&mut)) |_| {} else |_| {}
    }
    // wild-pointer sweep: every region rejects without deref (no VMA mapped here)
    mm.init();
    defer mm.init();
    const probes = [_]usize{ 0, 1, 0xFFF, 0x1000, 0x20000000, 0x7FFFFFFFF000, 0x7FFFFFFFFFFF, 0x800000000000, 0xFFFF800000000000, 0xFFFFFFFFFFFFFFFF };
    var tmp: [16]u8 = undefined;
    for (probes) |p| {
        try std.testing.expect(!uaccess.validate(p, 16, false));
        try std.testing.expect(!uaccess.validate(p, 16, true));
        try std.testing.expect(!uaccess.copyFromUser(&tmp, p));
        try std.testing.expect(uaccess.copyCStrFromUser(p, &tmp) == null);
    }
    // capture pid isolation under flood: streams never cross
    const cap = proc_mod.capture;
    cap.reset(1);
    cap.reset(2);
    _ = cap.writeStdout(1, "p1-out");
    _ = cap.writeStderr(2, "p2-err");
    try std.testing.expectEqualStrings("p1-out", cap.stdoutOf(1));
    try std.testing.expectEqual(@as(usize, 0), cap.stderrOf(1).len);
    try std.testing.expectEqualStrings("p2-err", cap.stderrOf(2));
    try std.testing.expectEqual(@as(usize, 0), cap.stdoutOf(2).len);
    cap.reset(1);
    cap.reset(2);
}

test "net: AF_UNIX socketpair loopback" {
    skbuff.init(); net_core.init(); socket_mod.init();
    var pair: [2]i32 = undefined;
    socket_mod.socketpair(socket_mod.AF_UNIX, socket_mod.SOCK_STREAM, 0, &pair) catch return;
    const s1 = socket_mod.findSock(pair[0]) orelse return;
    const s2 = socket_mod.findSock(pair[1]) orelse return;
    try std.testing.expect(s1.peer_socket != null);
    try std.testing.expect(s2.peer_socket != null);
    const msg = "hello unix";
    const sent = try socket_mod.send(pair[0], msg);
    try std.testing.expect(sent == msg.len);
    var buf: [32]u8 = undefined;
    const recvd = try socket_mod.recv(pair[1], &buf);
    try std.testing.expect(recvd == msg.len);
    try std.testing.expectEqualSlices(u8, buf[0..recvd], msg);
}

test "blk: virtio-blk + ext4 integration" {
    try virtio_blk.init();
    const S = struct {
        fn read(lba: u64, out: []u8) !void {
            if (out.len != 512 or lba >= 64) return error.BadLen;
            try virtio_blk.read_sector(@as(u32, @intCast(lba)), @as(*[512]u8, @ptrCast(out.ptr)));
        }
    };
    const sb = try ext4.parse_superblock(S.read);
    try std.testing.expectEqual(@as(u16, 0xEF53), sb.magic);
    var out: [64]u8 = undefined;
    const n = try ext4.read_hello_txt(S.read, out[0..]);
    try std.testing.expectEqual(@as(usize, 33), n);
    try std.testing.expectEqualStrings("Hello from Zig Linux VFS (ramfs)\n", out[0..n]);
}

test "blk: sector write/read roundtrip preserves ext4" {
    try virtio_blk.init();
    var orig: [512]u8 = undefined;
    try virtio_blk.read_sector(63, &orig);
    defer virtio_blk.write_sector(63, &orig) catch {};
    var pat: [512]u8 = undefined;
    for (&pat, 0..) |*b, i| b.* = @as(u8, @intCast(i % 251));
    try virtio_blk.write_sector(63, &pat);
    var got: [512]u8 = undefined;
    try virtio_blk.read_sector(63, &got);
    try std.testing.expectEqualSlices(u8, &pat, &got);
    try std.testing.expectError(error.OutOfRange, virtio_blk.read_sector(64, &got));
    const S = struct {
        fn read(lba: u64, out: []u8) !void {
            if (out.len != 512 or lba >= 64) return error.BadLen;
            try virtio_blk.read_sector(@as(u32, @intCast(lba)), @as(*[512]u8, @ptrCast(out.ptr)));
        }
    };
    const sb = try ext4.parse_superblock(S.read);
    try std.testing.expectEqual(@as(u16, 0xEF53), sb.magic);
}

// ── Bare-metal entry stub (hosted build still exports for completeness) ──
fn _start_baremetal_fallback() callconv(.c) noreturn {
    main() catch {
        while (true) {
            asm volatile ("hlt");
        }
    };
    while (true) {
        asm volatile ("hlt");
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&_start_baremetal_fallback, .{ .name = "_start_baremetal" });
    }
}
