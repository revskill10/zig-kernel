// supervisor/qemu — hardened QEMU argv builder (P2).
// Pure: limits + image paths → qemu-system-x86_64 argv. Exact argv, no shell.
// Hardening posture per docs/sandbox-production-plan.md §4:
//   -nodefaults -no-user-config -display none -nic none
//   -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
//   -object memory-backend-memfd (no host file mmap of guest RAM)
// Process spawn/kill/reap is runtime.zig (Linux-gated); argv shape tested everywhere.
const std = @import("std");
const policy = @import("policy.zig");

pub const Config = struct {
    kernel_path: [*:0]const u8,
    /// Per-session read-only kernel/initrd dir passed via -L? No: kernel only.
    serial_path: []const u8, // unix socket for control channel (formatted into argv)
    machine: [*:0]const u8 = "q35",
    cpu: [*:0]const u8 = "qemu64",
    /// Guest RAM grows from memfd; host never mmaps a file for guest RAM.
    memfd_id: [*:0]const u8 = "zk-ram",
    enable_kvm: bool = true,
};

pub const MAX_ARGS: usize = 48;

/// Write argv pointers into args (backed by storage). Returns argc.
pub fn buildArgs(limits: policy.Limits, cfg: Config, args: [][*:0]const u8, storage: *ArgsStorage) !usize {
    try policy.validate(limits);
    var n: usize = 0;
    const put = struct {
        fn one(args_: [][*:0]const u8, n_: *usize, a: [*:0]const u8) !void {
            if (n_.* >= args_.len) return error.TooManyArgs;
            args_[n_.*] = a;
            n_.* += 1;
        }
    };
    try put.one(args, &n, "qemu-system-x86_64");
    // No default devices, no user config files: attack surface stays the exact argv.
    try put.one(args, &n, "-nodefaults");
    try put.one(args, &n, "-no-user-config");
    try put.one(args, &n, "-machine");
    try put.one(args, &n, cfg.machine);
    try put.one(args, &n, "-cpu");
    try put.one(args, &n, cfg.cpu);
    if (cfg.enable_kvm) try put.one(args, &n, "-enable-kvm");
    try put.one(args, &n, "-m");
    const mem_str = try std.fmt.bufPrint(&storage.mem, "{d}M", .{limits.memory_mib});
    storage.mem[mem_str.len] = 0;
    args[n] = storage.mem[0..mem_str.len :0];
    n += 1;
    // Guest RAM from memfd, not a host file mapping.
    try put.one(args, &n, "-object");
    const obj = try std.fmt.bufPrint(&storage.obj, "memory-backend-memfd,id={s},size={d}M,share=off", .{ cfg.memfd_id, limits.memory_mib });
    storage.obj[obj.len] = 0;
    args[n] = storage.obj[0..obj.len :0];
    n += 1;
    try put.one(args, &n, "-numa");
    const numa = try std.fmt.bufPrint(&storage.numa, "node,memdev={s}", .{cfg.memfd_id});
    storage.numa[numa.len] = 0;
    args[n] = storage.numa[0..numa.len :0];
    n += 1;
    try put.one(args, &n, "-smp");
    const smp_str = try std.fmt.bufPrint(&storage.smp, "{d}", .{limits.vcpus});
    storage.smp[smp_str.len] = 0;
    args[n] = storage.smp[0..smp_str.len :0];
    n += 1;
    try put.one(args, &n, "-kernel");
    try put.one(args, &n, cfg.kernel_path);
    try put.one(args, &n, "-serial");
    const ser = try std.fmt.bufPrint(&storage.serial, "unix:{s},server=on,wait=off", .{cfg.serial_path});
    storage.serial[ser.len] = 0;
    args[n] = storage.serial[0..ser.len :0];
    n += 1;
    try put.one(args, &n, "-display");
    try put.one(args, &n, "none");
    // No NIC of any kind (P1 posture; egress is not a feature until P6+).
    try put.one(args, &n, "-nic");
    try put.one(args, &n, "none");
    // QEMU-internal sandbox: deny privileged syscalls inside QEMU itself.
    try put.one(args, &n, "-sandbox");
    try put.one(args, &n, "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny");
    // Kill on guest-requested shutdown instead of lingering; no reboot loops.
    try put.one(args, &n, "-no-reboot");
    try put.one(args, &n, "-no-shutdown");
    if (n >= args.len) return error.TooManyArgs;
    return n;
}

pub const ArgsStorage = struct {
    mem: [17]u8 = undefined, // "4096M" + NUL
    smp: [9]u8 = undefined, // "8" + NUL
    serial: [301]u8 = undefined, // "unix:..." + NUL
    obj: [128]u8 = undefined, // memory-backend-memfd spec + NUL
    numa: [64]u8 = undefined, // numa node spec + NUL
};

test "qemu: hardened argv shape — nodefaults, sandbox, memfd, nic none" {
    var args: [MAX_ARGS][*:0]const u8 = undefined;
    var st = ArgsStorage{};
    const cfg = Config{ .kernel_path = "/img/zk", .serial_path = "/run/zk1.sock" };
    const n = try buildArgs(.{ .vcpus = 2, .memory_mib = 256 }, cfg, &args, &st);
    const flat = args[0..n];
    var has_nodefaults = false;
    var has_no_user_config = false;
    var has_sandbox = false;
    var has_memfd = false;
    var has_numa_memdev = false;
    var has_nic_none = false;
    var has_display_none = false;
    var has_kvm = false;
    var mem_val: ?[]const u8 = null;
    var smp_val: ?[]const u8 = null;
    var i: usize = 0;
    while (i < flat.len) : (i += 1) {
        const a = std.mem.span(flat[i]);
        if (std.mem.eql(u8, a, "-nodefaults")) has_nodefaults = true;
        if (std.mem.eql(u8, a, "-no-user-config")) has_no_user_config = true;
        if (std.mem.eql(u8, a, "-enable-kvm")) has_kvm = true;
        if (std.mem.eql(u8, a, "-sandbox") and i + 1 < flat.len) {
            const v = std.mem.span(flat[i + 1]);
            if (std.mem.indexOf(u8, v, "spawn=deny") != null and
                std.mem.indexOf(u8, v, "elevateprivileges=deny") != null and
                std.mem.indexOf(u8, v, "resourcecontrol=deny") != null) has_sandbox = true;
        }
        if (std.mem.eql(u8, a, "-object") and i + 1 < flat.len) {
            const v = std.mem.span(flat[i + 1]);
            if (std.mem.indexOf(u8, v, "memory-backend-memfd") != null and
                std.mem.indexOf(u8, v, "size=256M") != null and
                std.mem.indexOf(u8, v, "share=off") != null) has_memfd = true;
        }
        if (std.mem.eql(u8, a, "-numa") and i + 1 < flat.len) {
            if (std.mem.indexOf(u8, std.mem.span(flat[i + 1]), "memdev=zk-ram") != null) has_numa_memdev = true;
        }
        if (std.mem.eql(u8, a, "-nic") and i + 1 < flat.len and std.mem.eql(u8, std.mem.span(flat[i + 1]), "none")) has_nic_none = true;
        if (std.mem.eql(u8, a, "-display") and i + 1 < flat.len and std.mem.eql(u8, std.mem.span(flat[i + 1]), "none")) has_display_none = true;
        if (std.mem.eql(u8, a, "-m")) mem_val = std.mem.span(flat[i + 1]);
        if (std.mem.eql(u8, a, "-smp")) smp_val = std.mem.span(flat[i + 1]);
    }
    try std.testing.expect(has_nodefaults);
    try std.testing.expect(has_no_user_config);
    try std.testing.expect(has_sandbox);
    try std.testing.expect(has_memfd);
    try std.testing.expect(has_numa_memdev);
    try std.testing.expect(has_nic_none);
    try std.testing.expect(has_display_none);
    try std.testing.expect(has_kvm);
    try std.testing.expectEqualStrings("256M", mem_val.?);
    try std.testing.expectEqualStrings("2", smp_val.?);
    var args2: [MAX_ARGS][*:0]const u8 = undefined;
    try std.testing.expectError(error.BadLimits, buildArgs(.{ .vcpus = 99 }, cfg, &args2, &st));
}
