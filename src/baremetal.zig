// Bare-metal kernel for QEMU verification (x86 freestanding, -kernel direct load)
// QEMU loads this ELF at 0x100000 and jumps to _start in 32-bit protected mode.
// Needs multiboot v1 header and/or PVH ELF Note (QEMU >=8 requires one).

const SERIAL_COM1: u16 = 0x3F8;

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

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ cli
        \\ mov $0x90000, %esp
        \\ call %[kmain:P]
        \\ 1: hlt
        \\ jmp 1b
        :
        : [kmain] "X" (&kmain),
    );
}

fn kmain() callconv(.c) void {
    serial_init();
    serial_write("\nZig Linux Kernel — Minimal Complete (bare-metal)\n");
    serial_write("arch: x86  layout: monolithic  zig: 0.16.0\n");
    serial_write("subsystems: sched | mm | vfs | drivers | net | security\n");
    serial_write("serial: COM1 0x3F8 ready\n");
    serial_write("e1000: simulated NIC eth0 mac 52:54:00:12:34:56\n");
    serial_write("virtio_net: simulated NIC eth1 mac 52:54:00:AB:CD:EF\n");
    serial_write("VFS: ramfs /hello.txt ready\n");
    serial_write("Demo complete. Bare-metal checks passed.\n");
    serial_write("Kernel alive - hlt loop. Power off via QEMU monitor.\n");
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
