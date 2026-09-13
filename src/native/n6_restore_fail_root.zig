// src/native/n6_restore_fail_root — skip FXRSTOR so XMM/x87 sentinels fail.
// Distinct from n6_negative_root (wrong-site UD2). Must not emit ZKN: done.
// Same named-module graph as native-kernel plus named `main`.

pub const ZK_N6_RESTORE_FAIL: bool = true;

const main = @import("main");
pub const panic = main.panic;

comptime {
    _ = main;
}
