// arch/x86_64/native/serial — COM1 16550 UART, direct port I/O.
// Used by both the EFI loader (firmware-console independent) and the native
// kernel. No allocations, safe at every stage including post-ExitBootServices
// and inside trap handlers.

pub const PORT: u16 = 0x3F8;

pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "N{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[ret]"
        : [ret] "={al}" (-> u8),
        : [p] "N{dx}" (port),
    );
}

pub fn init() void {
    outb(PORT + 1, 0x00); // interrupts off (polled)
    outb(PORT + 3, 0x80); // DLAB
    outb(PORT + 0, 0x03); // 38400 baud divisor
    outb(PORT + 1, 0x00);
    outb(PORT + 3, 0x03); // 8N1
    outb(PORT + 2, 0xC7); // FIFO on, clear, 14-byte trigger
    outb(PORT + 4, 0x0B); // DTR+RTS+OUT2
}

fn writeReady() bool {
    return (inb(PORT + 5) & 0x20) != 0;
}

pub fn writeByte(b: u8) void {
    var spins: u32 = 0;
    while (!writeReady()) {
        spins += 1;
        if (spins > 1_000_000) return; // never wedge the boot on a dead UART
    }
    outb(PORT, b);
}

pub fn write(bytes: []const u8) void {
    for (bytes) |b| {
        if (b == '\n') writeByte('\r');
        writeByte(b);
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    write(s);
}

pub fn hex(value: u64) void {
    print("{x:0>16}", .{value});
}

const std = @import("std");
