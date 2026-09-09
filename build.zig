const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});

    // Hosted simulation build (default)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = host_target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-kernel",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run hosted kernel simulation");
    run_step.dependOn(&run_cmd.step);

    // Bare-metal build for QEMU verification (freestanding x86_32, loaded at 0x100000)
    const bare_target_query: std.Target.Query = .{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
    };
    const bare_target = b.resolveTargetQuery(bare_target_query);

    const bare_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/baremetal.zig"),
        .target = bare_target,
        .optimize = .ReleaseSmall,
    });

    const bare_exe = b.addExecutable(.{
        .name = "kernel-baremetal",
        .root_module = bare_exe_mod,
    });

    bare_exe.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(bare_exe);

    const qemu_bin_step = b.step("qemu-bin", "Build bare-metal kernel ELF for QEMU");
    qemu_bin_step.dependOn(b.getInstallStep());

    // Test step
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run kernel unit tests");
    test_step.dependOn(&run_tests.step);
}
