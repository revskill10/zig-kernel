// IDT — 256 entries, lidt. Sets 0x80 syscall gate (DPL=3 trap gate) for Ring3→Ring0.
var idt: [256]IDTEntry align(8) = [_]IDTEntry{.{ .offset_low = 0, .selector = 0, .zero = 0, .type_attr = 0, .offset_high = 0 }} ** 256;
var idt_desc: IDTDescriptor align(4) = undefined;

pub const IDTEntry = packed struct {
    offset_low: u16,
    selector: u16,
    zero: u8 = 0,
    type_attr: u8,
    offset_high: u16,
};

pub const IDTDescriptor = packed struct {
    limit: u16,
    base: u32,
};

pub inline fn cli() void { asm volatile ("cli" ::: .{ .memory = true }); }
pub inline fn sti() void { asm volatile ("sti" ::: .{ .memory = true }); }

fn setGate(vec: u8, handler: usize, dpl: u2) void {
    const attr: u8 = 0x80 | (@as(u8, dpl) << 5) | 0x0F; // P + DPL + trap gate 0xF
    idt[vec] = .{
        .offset_low = @intCast(handler & 0xFFFF),
        .selector = 0x08,
        .type_attr = attr,
        .offset_high = @intCast((handler >> 16) & 0xFFFF),
    };
}

export fn syscall_entry() callconv(.naked) void {
    asm volatile (
        \\pushl $0
        \\pusha
        \\call syscall_dispatch
        \\popa
        \\add $4, %esp
        \\iret
        ::: .{ .memory = true }
    );
}

pub fn idt_init() void {
    setGate(0x80, @intFromPtr(&syscall_entry), 3);
    idt_desc = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt[0]) };
    asm volatile ("lidt (%[p])" : : [p] "r" (&idt_desc) : .{ .memory = true });
}

export fn syscall_dispatch() callconv(.c) void {}
