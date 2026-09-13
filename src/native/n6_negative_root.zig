// src/native/n6_negative_root — separately built wrong-site UD2 profile.
// Same named-module graph as native-kernel plus a named `main` module
// (main.zig cannot be a file import here; it needs boot_info/gdt/idt/...).
// Must not emit ZKN: done. Keep out of the default success parser.

pub const ZK_N6_NEGATIVE: bool = true;

const main = @import("main");
pub const panic = main.panic;

comptime {
    _ = main;
}
