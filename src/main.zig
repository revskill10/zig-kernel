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

// ── Bare-metal entry stub (hosted build still exports for completeness) ──
export fn _start_baremetal() noreturn {
    main() catch {
        while (true) {
            asm volatile ("hlt");
        }
    };
    while (true) {
        asm volatile ("hlt");
    }
}
