// Bare-metal boot setup for QEMU
const std = @import("std");

pub fn baremetal_init() void {
    setup_gdt();
    setup_idt();
}

// GDT setup
pub const GDTEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
};

pub const GDTDescriptor = packed struct {
    limit: u16,
    base: u64,
};

fn setup_gdt() void {
    // Null descriptor
    const null_desc: GDTEntry = .{
        .limit_low = 0,
        .base_low = 0,
        .base_middle = 0,
        .access = 0,
        .granularity = 0,
        .base_high = 0,
    };

    // Code descriptor
    const code_desc: GDTEntry = .{
        .limit_low = 0xFFFF,
        .base_low = 0,
        .base_middle = 0,
        .access = 0x9A,  // Present, Ring 0, Executable, Readable
        .granularity = 0xCF, // Granularity, 32-bit, Limit high
        .base_high = 0,
    };

    // Data descriptor
    const data_desc: GDTEntry = .{
        .limit_low = 0xFFFF,
        .base_low = 0,
        .base_middle = 0,
        .access = 0x92,  // Present, Ring 0, Expand-up, Writable
        .granularity = 0xCF, // Granularity, 32-bit, Limit high
        .base_high = 0,
    };

    // Load GDT
    const gdt: [_]GDTEntry = [_]GDTEntry{ null_desc, code_desc, data_desc };
    const gdt_desc: GDTDescriptor = .{
        .limit = (@sizeOf(gdt) - 1),
        .base = @intFromPtr(&gdt),
    };

    asm volatile ("lgdt %0" : : "m"(gdt_desc) : "memory");

    // Reload segment registers
    asm volatile (
        "mov %%ax, %%ds\\n\\t"
        "mov %%ax, %%es\\n\\t"
        "mov %%ax, %%fs\\n\\t"
        "mov %%ax, %%gs\\n\\t"
        :
        : "a"(0x10)  // Data segment selector
        :
    );
}

// IDT setup
pub const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    attributes: u8,
    offset_middle: u16,
    offset_high: u32,
};

pub const IDTDescriptor = packed struct {
    limit: u16,
    base: u64,
};

fn setup_idt() void {
    // For now just set up a basic IDT with 256 entries
    const idt_size: u16 = 256;
    const idt: [*c]IDTEntry = @cDefine(@import("c").malloc(@sizeOf(IDTEntry) * idt_size)) orelse unreachable;

    // Zero out IDT
    @memset(idt, 0, @sizeOf(IDTEntry) * idt_size);

    // Load IDT
    const idt_desc: IDTDescriptor = .{
        .limit = (@sizeOf(IDTEntry) * idt_size) - 1,
        .base = @intFromPtr(idt),
    };

    asm volatile ("lidt %0" : : "m"(idt_desc) : "memory");
}

// Simple serial port output for debugging
pub fn putc(c: u8) void {
    // COM1 port
    const COM1: u16 = 0x3F8;
    // Wait for transmit buffer to be empty
    while ((@inPort(COM1 + 5) and 0x20) == 0) {
        // nop
    }
    @outPort(COM1, c);
}

pub fn puts(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') {
            putc('\r');
        }
        putc(c);
    }
}

// Simple port I/O helpers
pub fn inPort(port: u16) u8 inline asm volatile ("in %0, %1" : "=a"(result) : "Nd"(port) : "memory");
pub fn outPort(port: u16, value: u8) void inline asm volatile ("out %0, %1" : : "Nd"(port), "a"(value) : "memory");