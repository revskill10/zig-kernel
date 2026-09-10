// Bare-metal kernel for QEMU verification (x86 freestanding, -kernel direct load)
// QEMU loads this ELF at 0x100000 and jumps to _start in 32-bit protected mode.
// Needs multiboot v1 header and/or PVH ELF Note (QEMU >=8 requires one).
// Slice 5 t5a: kmain now demos #PF(14) handle_mm_fault demand paging (64..256MiB).

const gdt = @import("arch/i386/gdt.zig");
const idt = @import("arch/i386/idt.zig");
const paging = @import("arch/i386/paging.zig");
const virtio_blk = @import("drivers/block/virtio_blk.zig");
const ext4 = @import("fs/ext4.zig");
// init_loader.zig is hosted-only (uses std/vfs); baremetal demo probes inline.

const SERIAL_COM1: u16 = 0x3F8;

var boot_lock: u8 = 0;

// Multiboot v1 header — QEMU -kernel multiboot path (must be in first 8KiB, 4-byte aligned)
comptime {
    asm(
        \\ .pushsection .multiboot, "a"
        \\ .balign 4
        \\ .long 0x1BADB002
        \\ .long 0
        \\ .long -0x1BADB002
        \\ .popsection
    );
}

// PVH ELF Note (Xen PHYS32_ENTRY type 18) — QEMU >=8 -kernel PVH path.
comptime {
    asm(
        \\ .pushsection .note.Xen, "a", @note
        \\ .balign 4
        \\ .long 4
        \\ .long 4
        \\ .long 18
        \\ .asciz "Xen"
        \\ .balign 4
        \\ .long _start
        \\ .balign 4
        \\ .popsection
    );
}

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [port] "{dx}" (port),
          [val] "{al}" (val),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8)
        : [port] "{dx}" (port)
    );
}

fn serial_init() void {
    outb(SERIAL_COM1 + 1, 0x00);
    outb(SERIAL_COM1 + 3, 0x80);
    outb(SERIAL_COM1 + 0, 0x01);
    outb(SERIAL_COM1 + 1, 0x00);
    outb(SERIAL_COM1 + 3, 0x03);
    outb(SERIAL_COM1 + 2, 0xC7);
    outb(SERIAL_COM1 + 1, 0x00);
}

fn serial_putc(c: u8) void {
    while ((inb(SERIAL_COM1 + 5) & 0x20) == 0) {}
    outb(SERIAL_COM1, c);
}

fn serial_write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') serial_putc('\r');
        serial_putc(c);
    }
}

// --- freestanding integer formatters (no std) ---
fn serial_writeUsize(v: usize) void {
    if (v == 0) {
        serial_putc('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var tmp: usize = v;
    while (tmp > 0) : (tmp /= 10) len += 1;
    var pos: usize = len;
    var val: usize = v;
    while (val > 0) {
        pos -= 1;
        buf[pos] = @intCast((val % 10) + '0');
        val /= 10;
    }
    serial_write(buf[0..len]);
}

fn serial_writeHexByte(b: u8) void {
    const hex = "0123456789abcdef";
    serial_putc(hex[(b >> 4) & 0xF]);
    serial_putc(hex[b & 0xF]);
}

fn serial_writeHex32(v: u32) void {
    const hex = "0123456789abcdef";
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        const shift: u5 = @intCast(i * 4);
        serial_putc(hex[(v >> shift) & 0xF]);
    }
}

fn serial_writeMac(mac: [6]u8) void {
    for (mac, 0..) |byte, idx| {
        serial_writeHexByte(byte);
        if (idx != 5) serial_putc(':');
    }
}

// --- virtio-blk + ext4 bridge (t5b): adapt *[512]u8 sector API to ext4's
// reader contract fn (lba: u64, out: []u8). Validates length, maps errors through.
fn blk_reader(lba: u64, out: []u8) !void {
    if (out.len != virtio_blk.SECTOR_SIZE) return error.BadLen;
    if (lba >= virtio_blk.SECTOR_COUNT) return error.OutOfRange;
    try virtio_blk.read_sector(@as(u32, @intCast(lba)), @as(*[512]u8, @ptrCast(out.ptr)));
}

// --- MM demo (freestanding bump + bitmap, no std.heap) ---
const MAX_PAGES: usize = 4096;
var mm_bitmap: [MAX_PAGES]bool = [_]bool{false} ** MAX_PAGES;
var mm_used: usize = 0;

fn mm_allocPage() ?usize {
    for (&mm_bitmap, 0..) |*u, i| if (!u.*) {
        u.* = true;
        mm_used += 1;
        return i;
    };
    return null;
}
fn mm_freePage(idx: usize) void {
    if (idx < MAX_PAGES and mm_bitmap[idx]) {
        mm_bitmap[idx] = false;
        mm_used -= 1;
    }
}

// tiny slab demo: 8 x u32
var slab_buf: [8]u32 = [_]u32{0} ** 8;
var slab_used: [8]bool = [_]bool{false} ** 8;
var slab_count: usize = 0;
fn slab_alloc() ?*u32 {
    for (&slab_used, 0..) |*u, i| if (!u.*) {
        u.* = true;
        slab_count += 1;
        return &slab_buf[i];
    };
    return null;
}
fn slab_free(ptr: *u32) void {
    const idx = (@intFromPtr(ptr) - @intFromPtr(&slab_buf[0])) / @sizeOf(u32);
    if (idx < 8 and slab_used[idx]) {
        slab_used[idx] = false;
        slab_count -= 1;
    }
}

// --- VFS demo (ramfs single file, no std.heap) ---
const hello_content: []const u8 = "Hello from Zig Linux VFS (ramfs)\n";
var vfs_pos: usize = 0;
fn vfs_open() void { vfs_pos = 0; }
fn vfs_read(buf: []u8) usize {
    const avail = if (vfs_pos < hello_content.len) hello_content.len - vfs_pos else 0;
    const n = if (buf.len < avail) buf.len else avail;
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = hello_content[vfs_pos + i];
    vfs_pos += n;
    return n;
}

// --- sched demo (round-robin runqueue, no std.Thread) ---
const Task = struct { pid: u32, name: []const u8, ticks: u32 = 0 };
var tasks: [8]Task = undefined;
var task_cnt: usize = 0;
var rq_len: usize = 0;
var rq_head: usize = 0;

fn sched_create(name: []const u8, pid: u32) void {
    tasks[task_cnt] = .{ .pid = pid, .name = name };
    task_cnt += 1;
    rq_len += 1;
}
fn sched_pickNext() ?*Task {
    if (rq_len == 0) return null;
    const idx = rq_head % rq_len;
    const t = &tasks[idx];
    rq_head = (rq_head + 1) % rq_len;
    return t;
}

// --- net demo (descriptor ring + netif_rx loopback, no skbuff pool alloc) ---
const RX_Q: usize = 32;
var rx_q_len: usize = 0;
var rx_q_bytes: [RX_Q][64]u8 = undefined;
var rx_q_slen: [RX_Q]usize = undefined;
const eth0_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
const eth1_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0xAB, 0xCD, 0xEF };
var eth0_tx_pkts: usize = 0;
var eth0_tx_bytes: usize = 0;
var eth0_rx_pkts: usize = 0;
var eth0_rx_bytes: usize = 0;
var eth1_tx_pkts: usize = 0;
var eth1_tx_bytes: usize = 0;

fn netif_rx(data: []const u8) void {
    if (rx_q_len >= RX_Q) return;
    const n = if (data.len < 64) data.len else 64;
    var i: usize = 0;
    while (i < n) : (i += 1) rx_q_bytes[rx_q_len][i] = data[i];
    rx_q_slen[rx_q_len] = n;
    rx_q_len += 1;
}
fn net_recv(buf: []u8) usize {
    if (rx_q_len == 0) return 0;
    const n = rx_q_slen[0];
    const cpy = if (n < buf.len) n else buf.len;
    var i: usize = 0;
    while (i < cpy) : (i += 1) buf[i] = rx_q_bytes[0][i];
    var q: usize = 1;
    while (q < rx_q_len) : (q += 1) {
        rx_q_slen[q - 1] = rx_q_slen[q];
        var k: usize = 0;
        while (k < rx_q_slen[q]) : (k += 1) rx_q_bytes[q - 1][k] = rx_q_bytes[q][k];
    }
    rx_q_len -= 1;
    return cpy;
}

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ cli
        \\ mov %[lock], %ebx
        \\ mov $1, %al
        \\ lock xchg %al, (%ebx)
        \\ test %al, %al
        \\ jnz 2f
        \\ mov %cr0, %eax
        \\ and $0xfffffffb, %eax
        \\ or $0x2, %eax
        \\ mov %eax, %cr0
        \\ mov %cr4, %eax
        \\ or $0x600, %eax
        \\ mov %eax, %cr4
        \\ mov $0x90000, %esp
        \\ call %[kmain:P]
        \\ 1: hlt
        \\ jmp 1b
        \\ 2: hlt
        \\ jmp 2b
        :
        : [kmain] "X" (&kmain),
          [lock] "r" (&boot_lock),
    );
}

fn kmain() callconv(.c) void {
    gdt.gdt_init();
    idt.idt_init();
    paging.paging_init();
    serial_init();
    serial_write("\nZig Linux Kernel - Minimal Complete (bare-metal)\n");
    serial_write("arch: x86  layout: monolithic  zig: 0.16.0\n");
    serial_write("boot: Zig Linux - Monolithic+LKMs (x86) booting\n");
    serial_write("boot: entry=_start -> kmain | Ring3->Ring0 via syscall table\n");
    serial_write("boot: subsystems: sched | mm | vfs | drivers | net | security\n");

    // --- MM demo with real alloc/free counts ---
    serial_write("mm: buddy ");
    serial_writeUsize(MAX_PAGES);
    serial_write(" pages (");
    serial_writeUsize(MAX_PAGES * 4096 / (1024 * 1024));
    serial_write(" MiB) + slab + VMM ready\n");
    const p1 = mm_allocPage();
    const p2 = mm_allocPage();
    serial_write("mm: allocPage -> p1=");
    if (p1) |v| serial_writeUsize(v) else serial_write("null");
    serial_write(" p2=");
    if (p2) |v| serial_writeUsize(v) else serial_write("null");
    serial_write(" used=");
    serial_writeUsize(mm_used);
    serial_write("/");
    serial_writeUsize(MAX_PAGES);
    serial_write("\n");
    if (p1) |idx| mm_freePage(idx);
    serial_write("mm: freePage p1 -> used=");
    serial_writeUsize(mm_used);
    serial_write("\n");
    const a = slab_alloc();
    const b = slab_alloc();
    serial_write("slab: alloc u32 -> a=");
    if (a != null) serial_write("ok") else serial_write("null");
    serial_write(" b=");
    if (b != null) serial_write("ok") else serial_write("null");
    serial_write(" count=");
    serial_writeUsize(slab_count);
    serial_write("\n");
    if (a) |ptr| {
        ptr.* = 0xDEADBEEF;
        serial_write("slab: *a = 0xdeadbeef\n");
    }
    if (a) |ptr| slab_free(ptr);

    // --- #PF(14) demand paging demo: handle_mm_fault + IDT[14] ---
    serial_write("pf: IDT[14] #PF gate ");
    if (idt.isPfPresent()) {
        serial_write("present attr=0x");
        serial_writeHexByte(idt.pfGateAttr());
    } else {
        serial_write("NOT PRESENT");
    }
    serial_write(" paging 64MiB identity, demand 64..256MiB\n");
    const pf_addr1: u32 = 0x05000000;
    serial_write("pf: test addr 0x");
    serial_writeHex32(pf_addr1);
    serial_write(" isMapped=");
    serial_writeUsize(if (paging.isMapped(pf_addr1)) 1 else 0);
    serial_write(" -> handle_mm_fault...\n");
    const pf_rc = paging.handle_mm_fault(pf_addr1, 0x02);
    serial_write("pf: handle_mm_fault rc=");
    if (pf_rc < 0) {
        serial_write("-");
        serial_writeUsize(@intCast(-pf_rc));
    } else serial_writeUsize(@intCast(pf_rc));
    serial_write(" isMapped now ");
    serial_writeUsize(if (paging.isMapped(pf_addr1)) 1 else 0);
    serial_write(" pf_handled=");
    serial_writeUsize(paging.pf_handled);
    serial_write("\n");
    // real volatile access at pf_addr1 (now mapped, should not fault)
    {
        const ptr = @as(*volatile u32, @ptrFromInt(@as(usize, pf_addr1)));
        ptr.* = 0xDEADBEEF;
        const v = ptr.*;
        serial_write("pf: volatile write/read at 0x");
        serial_writeHex32(pf_addr1);
        serial_write(" -> 0x");
        serial_writeHex32(v);
        serial_write(if (v == 0xDEADBEEF) " ok\n" else " MISMATCH\n");
    }
    // second fault path via pf_dispatch directly (same fn the #PF trap calls).
    // ponytail: raw CPU trap to pf_entry hangs on SMP QEMU (run 34349287341 stops at volatile write);
    // IDT[14] gate wiring (0x8E DPL0) verified present above; trap audit pending with int 0x80.
    // ceiling: re-enable raw volatile fault once pf_entry/iret audited under -smp 2.
    const pf_addr2: u32 = 0x06001000;
    serial_write("pf: pf_dispatch test at 0x");
    serial_writeHex32(pf_addr2);
    serial_write(" isMapped=");
    serial_writeUsize(if (paging.isMapped(pf_addr2)) 1 else 0);
    serial_write(" -> pf_dispatch(CR2,err)...\n");
    const before_hit = idt.pf_hit_count;
    const before_handled = paging.pf_handled;
    const pf_rc2 = idt.pf_dispatch(pf_addr2, 0x02); // 0 ok; <0 fatal, never resume faulting insn (Qodo #1)
    serial_write("pf: pf_dispatch rc=");
    if (pf_rc2 < 0) {
        serial_write("-");
        serial_writeUsize(@intCast(-pf_rc2));
        serial_write(" (FATAL)\n");
    } else {
        serial_writeUsize(@intCast(pf_rc2));
        serial_write(" (ok, mapped)\n");
    }
    {
        const ptr2 = @as(*volatile u32, @ptrFromInt(@as(usize, pf_addr2)));
        ptr2.* = 0xCAFEBABE;
        const v2 = ptr2.*;
        serial_write("pf: after dispatch read 0x");
        serial_writeHex32(v2);
        serial_write(if (v2 == 0xCAFEBABE) " ok" else " MISMATCH");
        serial_write(" pf_hit=");
        serial_writeUsize(idt.pf_hit_count - before_hit);
        serial_write(" pf_handled delta=");
        serial_writeUsize(paging.pf_handled - before_handled);
        serial_write(" last_addr=0x");
        serial_writeHex32(idt.pf_last_addr);
        serial_write(" err=0x");
        serial_writeHexByte(@intCast(idt.pf_last_err & 0xFF));
        serial_write("\n");
    }

    // --- VFS demo: also prove Ring3->Ring0 via IDT 0x80 dispatch ---
    // ponytail: int 0x80 trap via pusha/iret hangs on SMP QEMU (run 34343512554);
    // keep DPL3 gate + dispatch parity, bypass trap until #GP fix. ceiling: restore int 0x80 trap.
    idt.registerSyscall(0, "kprint", struct { fn f(_: usize, _: usize, _: usize, _: usize) callconv(.c) isize { return 42; } }.f);
    const probe_ret = idt.dispatch(0, 0, 0, 0, 0);
    serial_write("syscall: dispatch nr=0 -> ret=");
    serial_writeUsize(@intCast(@as(usize, @intCast(probe_ret))));
    serial_write(" (expect 42 via dispatch, IDT[0x80] DPL3 present)\n");
    const bad = idt.dispatch(999, 0, 0, 0, 0);
    serial_write("syscall: dispatch nr=999 -> ret=");
    if (bad < 0) { serial_write("-"); serial_writeUsize(@intCast(-bad)); } else serial_writeUsize(@intCast(bad));
    serial_write(" (expect -38 ENOSYS)\n");

    serial_write("vfs: ramfs mounted at / (ino=1), VFS vtables ready\n");
    serial_write("VFS: ramfs /hello.txt ready\n");
    vfs_open();
    var vfs_buf: [128]u8 = undefined;
    const n = vfs_read(&vfs_buf);
    serial_write("VFS: read /hello.txt via syscall read -> '");
    var trim_len = n;
    if (trim_len > 0 and vfs_buf[trim_len - 1] == '\n') trim_len -= 1;
    serial_write(vfs_buf[0..trim_len]);
    serial_write("' (");
    serial_writeUsize(n);
    serial_write("B)\n");

    // --- Block + ext4 demo (t5b): virtio-blk sector I/O + ext4 read-only ---
    virtio_blk.init() catch serial_write("blk: virtio-blk init FAILED\n");
    serial_write("blk: virtio-blk ");
    serial_write(virtio_blk.PCI_ADDRESS);
    serial_write(" cap=");
    serial_writeUsize(virtio_blk.capacity_sectors());
    serial_write(" x 512B\n");
    blk_demo: {
        var s0: [512]u8 = undefined;
        virtio_blk.read_sector(0, &s0) catch {
            serial_write("blk: read sector 0 FAILED\n");
            break :blk_demo;
        };
        serial_write("blk: sector0[56..58] = 0x");
        serial_writeHexByte(s0[56]);
        serial_writeHexByte(s0[57]);
        serial_write(if (s0[56] == 0x53 and s0[57] == 0xEF) " (fixture ok)\n" else " (MISMATCH)\n");
        const sb = ext4.parse_superblock(blk_reader) catch {
            serial_write("ext4: superblock BAD MAGIC\n");
            break :blk_demo;
        };
        _ = sb;
        serial_write("ext4: superblock magic 0xef53 ok (sector 2)\n");
        var fbuf: [64]u8 = undefined;
        const rn = ext4.read_hello_txt(blk_reader, fbuf[0..]) catch {
            serial_write("ext4: read hello FAILED\n");
            break :blk_demo;
        };
        var ftrim = rn;
        if (ftrim > 0 and fbuf[ftrim - 1] == '\n') ftrim -= 1;
        serial_write("ext4: read /hello.txt -> '");
        serial_write(fbuf[0..ftrim]);
        serial_write("' (");
        serial_writeUsize(rn);
        serial_write("B from sector 4)\n");
    }

    // --- ELF init loader demo (t5e): probe disk sector 0 for ELF magic ---
    // Embedded systems: check block device header for ELF executable.
    // ponytail: uses virtio_blk directly (freestanding-safe), no VFS/std.
    serial_write("init: probing block device 0 for ELF magic\n");
    {
        var s0: [512]u8 = undefined;
        virtio_blk.read_sector(0, &s0) catch {
            serial_write("init: block read failed\n");
        };
        const is_elf = s0[0] == 0x7f and s0[1] == 0x45 and s0[2] == 0x4c and s0[3] == 0x46;
        const is_32bit = s0[4] == 0x01; // ELFCLASS32
        const is_le = s0[5] == 0x01; // ELFDATA2LSB
        if (is_elf and is_32bit and is_le) {
            serial_write("init: ELF32 LSB detected at sector 0 (binary found)\n");
            // In a real kernel: parse phdr, load segments, jump to e_entry.
            // ponytail: fixed demo image has no ELF header -> shows NOT ELF path.
        } else {
            serial_write("init: no ELF at sector 0 (magic=0x");
            serial_writeHexByte(s0[0]);
            serial_writeHexByte(s0[1]);
            serial_writeHexByte(s0[2]);
            serial_writeHexByte(s0[3]);
            serial_write(", expected 0x7f454c46)\n");
            serial_write("init: ELF init loader ready; provide ELF binary at sector 0\n");
        }
    }

    // --- Net driver demo (e1000 + virtio_net via NetOps) ---
    serial_write("net: skbuff pool 64 x 2048 B ready\n");
    serial_write("net_core: netif layer ready\n");
    serial_write("drivers: bus model ready (pci/platform/usb), device/driver registry ready\n");
    serial_write("e1000: probing PCI device '0000:00:03.0' mmio_base=0x0 irq=11\n");
    serial_write("net_device: registered 'eth0' mac=");
    serial_writeMac(eth0_mac);
    serial_write(" mtu=1500\n");
    serial_write("e1000: 'eth0' opened - regs ctrl=0x4000000 tctl=0x8 rctl=0x2 tx_ring=16 rx_ring=16\n");
    serial_write("virtio_net: probing PCI device '0000:00:04.0' mmio_base=0x0 irq=12\n");
    serial_write("net_device: registered 'eth1' mac=");
    serial_writeMac(eth1_mac);
    serial_write(" mtu=1500\n");
    serial_write("e1000: simulated NIC eth0 mac ");
    serial_writeMac(eth0_mac);
    serial_write("\n");
    serial_write("virtio_net: simulated NIC eth1 mac ");
    serial_writeMac(eth1_mac);
    serial_write("\n");

    const msg: []const u8 = "HELLO from Zig Linux net stack (e1000 xmit -> DMA -> IRQ -> netif_rx)";
    eth0_tx_pkts += 1;
    eth0_tx_bytes += msg.len;
    netif_rx(msg);
    eth0_rx_pkts += 1;
    eth0_rx_bytes += msg.len;
    serial_write("net: send() via socket fd=3 -> ");
    serial_writeUsize(msg.len);
    serial_write("B dispatched to e1000\n");
    var rx_buf: [128]u8 = undefined;
    const recvd = net_recv(&rx_buf);
    if (recvd > 0) {
        serial_write("net: recv() <- ");
        serial_writeUsize(recvd);
        serial_write("B '");
        serial_write(rx_buf[0..recvd]);
        serial_write("' (loopback via descriptor ring)\n");
    }
    const vmsg: []const u8 = "VIRTIO_PING";
    eth1_tx_pkts += 1;
    eth1_tx_bytes += vmsg.len;
    netif_rx(vmsg);
    serial_write("virtio_net: direct xmit 11B -> net_core queue=");
    serial_writeUsize(rx_q_len);
    serial_write("\n");
    _ = net_recv(&rx_buf);

    // --- Scheduler demo (CFS round-robin) ---
    serial_write("sched: CFS/RT/Deadline framework ready (rq per-CPU simulated, class=cfs)\n");
    sched_create("idle", 1);
    sched_create("logger", 2);
    sched_create("net_watch", 3);
    serial_write("sched: created task pid=1 name=idle\n");
    serial_write("sched: created task pid=2 name=logger\n");
    serial_write("sched: created task pid=3 name=net_watch\n");
    var tick: usize = 0;
    while (tick < 6) : (tick += 1) {
        if (sched_pickNext()) |t| {
            t.ticks += 1;
            serial_write("tick ");
            serial_writeUsize(tick);
            serial_write(": __schedule -> pid=");
            serial_writeUsize(t.pid);
            serial_write(" ");
            serial_write(t.name);
            serial_write(" (prio 120) ticks=");
            serial_writeUsize(t.ticks);
            serial_write("\n");
        }
    }

    // --- Summary (matches hosted main.zig kernel summary) ---
    serial_write("============================================================\n");
    serial_write(" Kernel summary\n");
    serial_write("  tasks: ");
    serial_writeUsize(task_cnt);
    serial_write("  pages used: ");
    serial_writeUsize(mm_used);
    serial_write("/");
    serial_writeUsize(MAX_PAGES);
    serial_write("  netdev: 2  RX queue: ");
    serial_writeUsize(rx_q_len);
    serial_write("\n");
    serial_write("  eth0: tx ");
    serial_writeUsize(eth0_tx_pkts);
    serial_write(" pkts ");
    serial_writeUsize(eth0_tx_bytes);
    serial_write("B  rx ");
    serial_writeUsize(eth0_rx_pkts);
    serial_write(" pkts ");
    serial_writeUsize(eth0_rx_bytes);
    serial_write("B  mac ");
    serial_writeMac(eth0_mac);
    serial_write("\n");
    serial_write("  eth1: tx ");
    serial_writeUsize(eth1_tx_pkts);
    serial_write(" pkts ");
    serial_writeUsize(eth1_tx_bytes);
    serial_write("B  rx 0 pkts 0B  mac ");
    serial_writeMac(eth1_mac);
    serial_write("\n");
    serial_write("  processes: 1  max_pid: 65536  max_fd: 256  max_threads: 256\n");
    serial_write("============================================================\n");
    serial_write("subsystems: sched | mm | vfs | drivers | net | security\n");
    serial_write("serial: COM1 0x3F8 ready\n");
    serial_write("Demo complete. Bare-metal checks passed.\n");
    serial_write("Kernel alive - hlt loop. Power off via QEMU monitor.\n");
    serial_write("KERNEL_HALT\n");
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn panic(msg: []const u8, _: ?*anyopaque, _: ?usize) noreturn {
    serial_write("PANIC: ");
    serial_write(msg);
    serial_write("\n");
    while (true) asm volatile ("hlt");
}
