// src/native/vm_probe_root — opt-in native root for the CPL0 VM probe.
// Distinct generated options modules select positive, skip-switch, and
// writable-RO artifacts. Not the default native kernel.

pub const ZK_VM_PROBE: bool = true;

const options = @import("vm_probe_options");
pub const ZK_VM_SKIP_SWITCH: bool = options.skip_switch;
pub const ZK_VM_WRITABLE_RO: bool = options.writable_ro;

const main = @import("main");
pub const panic = main.panic;
const vm_probe = @import("vm_probe");

comptime {
    _ = main;
    if (ZK_VM_SKIP_SWITCH and ZK_VM_WRITABLE_RO)
        @compileError("VM negative modes are mutually exclusive");
}

pub fn runVmProbe(info: *anyopaque) void {
    vm_probe.run(info);
}
