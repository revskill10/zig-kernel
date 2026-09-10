// supervisor/main — host supervisor root (M4).
// Linux deployment target; pure policy modules tested on host via
// `zig build test-supervisor`. Process spawn/kill/reap + socket IO
// land with Linux/QEMU qualification (M7).
// ponytail: no daemon loop yet; ceiling: unix-socket API server (M6).
pub const policy = @import("policy.zig");
pub const session = @import("session.zig");
pub const frame = @import("frame.zig");
pub const qemu = @import("qemu.zig");

test {
    _ = policy;
    _ = session;
    _ = frame;
    _ = qemu;
}
