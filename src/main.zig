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

// ── demo user tasks (analog to init + kthreads) ──
fn taskIdle() void { printk.printk(.debug, "task idle: cpu idle (hlt analog)", .{}); }
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
    var path: [16]u8 = [_]u8{0} ** 16;
    @memcpy(path[0..10], "/hello.txt");
    const fd = entry_mod.dispatch(sc.NR.openat, 0, @intFromPtr(&path[0]), 0, 0);
    try std.testing.expect(fd >= 0);
    var buf: [64]u8 = undefined;
    const n = entry_mod.dispatch(sc.NR.read, @intCast(fd), @intFromPtr(&buf[0]), buf.len, 0);
    try std.testing.expect(n > 0);
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
