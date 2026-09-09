// GDT for x86 32-bit freestanding — flat 4GB
var gdt: [3]GDTEntry align(8) = undefined;
var gdt_desc: GDTDescriptor align(4) = undefined;

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
    base: u32,
};

pub fn gdt_init() void {
    gdt[0] = .{ .limit_low = 0, .base_low = 0, .base_middle = 0, .access = 0, .granularity = 0, .base_high = 0 };
    gdt[1] = .{ .limit_low = 0xFFFF, .base_low = 0, .base_middle = 0, .access = 0x9A, .granularity = 0xCF, .base_high = 0 };
    gdt[2] = .{ .limit_low = 0xFFFF, .base_low = 0, .base_middle = 0, .access = 0x92, .granularity = 0xCF, .base_high = 0 };
    gdt_desc = .{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt[0]) };
    asm volatile ("lgdt (%[p])" : : [p] "r" (&gdt_desc) : .{ .memory = true });
    asm volatile (
        \\mov $0x10, %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\mov %ax, %fs
        \\mov %ax, %gs
        : : : .{ .memory = true }
    );
    asm volatile ("ljmp $0x08, $1f; 1:" : : : .{ .memory = true });
}
