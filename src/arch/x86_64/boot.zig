// arch/x86_64/boot — simulated boot banner (real kernel: GDT/IDT, long mode)
const printk = @import("../../lib/printk.zig");

pub fn earlyBoot() void {
    printk.printk(.info, "boot: Zig Linux — Monolithic+LKMs (x86_64) booting", .{});
    printk.printk(.info, "boot: entry=_start → kernel_main | Ring3↔Ring0 via syscall table", .{});
    printk.printk(.info, "boot: subsystems: sched | mm | vfs | drivers | net | security", .{});
}
