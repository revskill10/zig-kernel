// security/caps — Linux capabilities (analog: include/linux/capability.h)
// Clean: Policy layer — enforces capabilities, LSM hooks
const std = @import("std");
const printk = @import("../lib/printk.zig");

pub const Capability = enum {
    cap_chown,        // 0
    cap_dac_override, // 1
    cap_dac_read_search, // 2
    cap_fowner,       // 3
    cap_fsetid,       // 4
    cap_kill,         // 5
    cap_setgid,       // 6
    cap_setuid,       // 7
    cap_setpcap,      // 8
    cap_linux_immutable, // 9
    cap_net_bind_service, // 10
    cap_net_broadcast,    // 11
    cap_net_admin,    // 12
    cap_net_raw,      // 13
    cap_ipc_lock,     // 14
    cap_ipc_owner,    // 15
    cap_sys_module,   // 16
    cap_sys_rawio,    // 17
    cap_sys_chroot,   // 18
    cap_sys_ptrace,   // 19
    cap_sys_pacct,    // 20
    cap_sys_admin,    // 21
    cap_sys_boot,     // 22
    cap_sys_nice,     // 23
    cap_sys_resource, // 24
    cap_sys_time,     // 25
    cap_sys_tty_config, // 26
    cap_mknod,        // 27
    cap_lease,        // 28
    cap_audit_write,  // 29
    cap_audit_control, // 30
    cap_setfcap,      // 31
    cap_mac_override, // 32
    cap_mac_admin,    // 33
    cap_syslog,       // 34
    cap_wake_alarm,   // 35
    cap_block_suspend, // 36
    cap_audit_read,   // 37
};

pub const MAX_CAPS: usize = 38;

// Simulated process capability set (global for hosted sim)
var cap_last_cap: usize = 13; // Up to cap_net_raw
var effective: [MAX_CAPS]bool = [_]bool{false} ** MAX_CAPS;
var permitted: [MAX_CAPS]bool = [_]bool{false} ** MAX_CAPS;
var inheritable: [MAX_CAPS]bool = [_]bool{false} ** MAX_CAPS;

pub fn init() void {
    // In production kernel: all caps for root, then dropped
    // For hosted sim: grant cap_net_raw and cap_sys_admin
    setCap(.cap_net_raw, true);
    setCap(.cap_sys_admin, true);
    setCap(.cap_chown, true);
    setCap(.cap_dac_override, true);
    setCap(.cap_fowner, true);
    setCap(.cap_setuid, true);
    setCap(.cap_setgid, true);
    println("[INFO] caps: {d} capabilities enabled (net_raw, sys_admin, ...)\n", .{ countEnabled() });
}

pub fn setCap(cap: Capability, enable: bool) void {
    const idx = capToInt(cap);
    effective[idx] = enable;
    permitted[idx] = enable;
}

pub fn checkPermission(cap: Capability) bool {
    const idx = capToInt(cap);
    return effective[idx];
}

// LSM hook analog: check_security on open
pub fn securityCheckFileOpen(dentry: usize) bool {
    _ = dentry;
    return true; // Allow all in hosted sim
}

// LSM hook: inode_permission (check access to file)
pub fn securityInodePermission(mode: u16, mask: u32) bool {
    // If DAC override is set, allow all
    if (checkPermission(.cap_dac_override)) return true;
    // Simple check: readable/writable bit
    if ((mask & 0x4) != 0 and (mode & 0o400) == 0) return false; // read
    if ((mask & 0x2) != 0 and (mode & 0o200) == 0) return false; // write
    return true;
}

fn capToInt(cap: Capability) usize {
    return @intFromEnum(cap);
}

fn countEnabled() usize {
    var n: usize = 0;
    for (effective) |e| {
        if (e) n += 1;
    }
    return n;
}

fn println(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
