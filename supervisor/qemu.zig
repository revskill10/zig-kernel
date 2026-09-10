// supervisor/qemu — QEMU argv builder (M4).
// Pure: limits + image paths → qemu-system-x86_64 argv.
// No network device. Serial = control channel. Kernel = zig-kernel image.
// Process spawn/kill/reap is Linux-gated (M7); argv shape tested here.
const std = @import("std");
const policy = @import("policy.zig");

pub const Config = struct {
    kernel_path: [*:0]const u8,
    workspace_path: [*:0]const u8, // host dir for file transfer (never guest-writable directly)
    serial_path: []const u8, // unix socket for control channel (formatted into argv)
    machine: [*:0]const u8 = "q35",
    cpu: [*:0]const u8 = "qemu64",
    enable_kvm: bool = true,
};

pub const MAX_ARGS: usize = 32;

/// Write argv pointers into args (backed by storage). Returns argc.
pub fn buildArgs(limits: policy.Limits, cfg: Config, args: [][*:0]const u8, storage: *ArgsStorage) !usize {
    try policy.validate(limits);
    var n: usize = 0;
    args[n] = "qemu-system-x86_64";
    n += 1;
    args[n] = "-machine";
    n += 1;
    args[n] = cfg.machine;
    n += 1;
    args[n] = "-cpu";
    n += 1;
    args[n] = cfg.cpu;
    n += 1;
    if (cfg.enable_kvm) {
        args[n] = "-enable-kvm";
        n += 1;
    }
    args[n] = "-m";
    n += 1;
    const mem_str = try std.fmt.bufPrint(&storage.mem, "{d}M", .{limits.memory_mib});
    storage.mem[mem_str.len] = 0;
    args[n] = storage.mem[0..mem_str.len :0];
    n += 1;
    args[n] = "-smp";
    n += 1;
    const smp_str = try std.fmt.bufPrint(&storage.smp, "{d}", .{limits.vcpus});
    storage.smp[smp_str.len] = 0;
    args[n] = storage.smp[0..smp_str.len :0];
    n += 1;
    args[n] = "-kernel";
    n += 1;
    args[n] = cfg.kernel_path;
    n += 1;
    args[n] = "-serial";
    n += 1;
    const ser = try std.fmt.bufPrint(&storage.serial, "unix:{s},server=on,wait=off", .{cfg.serial_path});
    storage.serial[ser.len] = 0;
    args[n] = storage.serial[0..ser.len :0];
    n += 1;
    args[n] = "-display";
    n += 1;
    args[n] = "none";
    n += 1;
    args[n] = "-net";
    n += 1;
    args[n] = "none";
    n += 1;
    if (n >= MAX_ARGS) return error.TooManyArgs;
    return n;
}

pub const ArgsStorage = struct {
    mem: [17]u8 = undefined, // "4096M" + NUL
    smp: [9]u8 = undefined, // "8" + NUL
    serial: [301]u8 = undefined, // "unix:..." + NUL
};

test "qemu: argv shape — kvm, mem, smp, serial, no net" {
    var args: [MAX_ARGS][*:0]const u8 = undefined;
    var st = ArgsStorage{};
    const cfg = Config{ .kernel_path = "/img/zk", .workspace_path = "/ws/1", .serial_path = "/run/zk1.sock" };
    const n = try buildArgs(.{ .vcpus = 2, .memory_mib = 256 }, cfg, &args, &st);
    const flat = args[0..n];
    var has_kvm = false;
    var has_net_none = false;
    var has_display_none = false;
    var mem_val: ?[]const u8 = null;
    var smp_val: ?[]const u8 = null;
    var i: usize = 0;
    while (i < flat.len) : (i += 1) {
        const a = std.mem.span(flat[i]);
        if (std.mem.eql(u8, a, "-enable-kvm")) has_kvm = true;
        if (std.mem.eql(u8, a, "-m")) mem_val = std.mem.span(flat[i + 1]);
        if (std.mem.eql(u8, a, "-smp")) smp_val = std.mem.span(flat[i + 1]);
        if (std.mem.eql(u8, a, "-net") and i + 1 < flat.len and std.mem.eql(u8, std.mem.span(flat[i + 1]), "none")) has_net_none = true;
        if (std.mem.eql(u8, a, "-display") and i + 1 < flat.len and std.mem.eql(u8, std.mem.span(flat[i + 1]), "none")) has_display_none = true;
    }
    try std.testing.expect(has_kvm);
    try std.testing.expect(has_net_none);
    try std.testing.expect(has_display_none);
    try std.testing.expectEqualStrings("256M", mem_val.?);
    try std.testing.expectEqualStrings("2", smp_val.?);
    try std.testing.expectError(error.BadLimits, buildArgs(.{ .vcpus = 99 }, cfg, &args, &st));
}
