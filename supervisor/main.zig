// supervisor/main — host supervisor root (M4).
// Linux deployment target; pure policy modules tested on host via
// `zig build test-supervisor`. Process spawn/kill/reap + socket IO
// land with Linux/QEMU qualification (M7).
// ponytail: no daemon loop yet; ceiling: unix-socket API server (M6).
pub const policy = @import("policy.zig");
pub const session = @import("session.zig");
pub const frame = @import("frame.zig");
pub const qemu = @import("qemu.zig");
pub const jail = @import("jail.zig"); // P2: per-session UID/cgroup/ns/seccomp spec
pub const runtime = @import("runtime.zig"); // P2: pidfd spawn/kill/reap lifecycle
pub const workspace = @import("workspace.zig"); // M5 path confinement + quota
pub const api = @import("api.zig"); // M6 public API service logic
pub const adversarial = @import("adversarial.zig"); // M7 host adversarial suite

test {
    _ = policy;
    _ = session;
    _ = frame;
    _ = qemu;
    _ = jail;
    _ = runtime;
    _ = workspace;
    _ = api;
    _ = adversarial;
}
