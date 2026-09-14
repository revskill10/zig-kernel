const std = @import("std");
const builtin = @import("builtin");

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

    // Supervisor (M4 host-side, Linux target; pure policy testable on host)
    const sup_mod = b.createModule(.{
        .root_source_file = b.path("supervisor/main.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const sup_tests = b.addTest(.{ .root_module = sup_mod });
    const run_sup_tests = b.addRunArtifact(sup_tests);
    const sup_test_step = b.step("test-supervisor", "Run supervisor unit tests");
    sup_test_step.dependOn(&run_sup_tests.step);

    // ================= Track Z native (KWP1/KWP2) =================
    // Independent of the hosted and i386 demo targets above; nothing here
    // falls back to hosted execution.

    // Native x86_64 ELF64 payload loaded by the EFI stub at 2 MiB.
    const native_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const native_optimize: std.builtin.OptimizeMode = .ReleaseSmall;
    const mkNativeMod = struct {
        fn f(b2: *std.Build, path: []const u8, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
            return b2.createModule(.{
                .root_source_file = b2.path(path),
                .target = t,
                .optimize = o,
                .red_zone = false, // interruptible native code: no red zone
                .stack_check = false,
                .omit_frame_pointer = true,
                .code_model = .small,
            });
        }
    }.f;

    const n_boot_info = mkNativeMod(b, "src/native/boot_info.zig", native_target, native_optimize);
    const n_serial = mkNativeMod(b, "src/arch/x86_64/native/serial.zig", native_target, native_optimize);
    const n_gdt = mkNativeMod(b, "src/arch/x86_64/native/gdt.zig", native_target, native_optimize);
    const n_idt = mkNativeMod(b, "src/arch/x86_64/native/idt.zig", native_target, native_optimize);
    n_idt.addImport("serial", n_serial);
    n_idt.addImport("gdt", n_gdt);
    const n_paging = mkNativeMod(b, "src/arch/x86_64/native/paging.zig", native_target, native_optimize);
    n_paging.addImport("serial", n_serial);
    const n_pmm = mkNativeMod(b, "src/arch/x86_64/native/pmm.zig", native_target, native_optimize);
    n_pmm.addImport("boot_info", n_boot_info);

    const native_kernel_mod = mkNativeMod(b, "src/native/main.zig", native_target, native_optimize);
    native_kernel_mod.addImport("boot_info", n_boot_info);
    native_kernel_mod.addImport("serial", n_serial);
    native_kernel_mod.addImport("gdt", n_gdt);
    native_kernel_mod.addImport("idt", n_idt);
    native_kernel_mod.addImport("paging", n_paging);
    native_kernel_mod.addImport("pmm", n_pmm);
    const native_kernel = b.addExecutable(.{
        .name = "zk-kernel",
        .root_module = native_kernel_mod,
    });
    native_kernel.entry = .disabled; // linker script ENTRY(kmain)
    native_kernel.setLinkerScript(b.path("linker/native-x86_64.ld"));
    const native_kernel_install = b.addInstallArtifact(native_kernel, .{});
    const native_kernel_step = b.step("native-kernel", "Build native x86_64 ELF64 payload");
    native_kernel_step.dependOn(&native_kernel_install.step);

    // N6 negative image: distinct root, not the default success parser.
    const n6_neg_mod = mkNativeMod(b, "src/native/n6_negative_root.zig", native_target, native_optimize);
    n6_neg_mod.addImport("main", native_kernel_mod);
    const n6_neg = b.addExecutable(.{
        .name = "zk-kernel-n6-negative",
        .root_module = n6_neg_mod,
    });
    n6_neg.entry = .disabled;
    n6_neg.setLinkerScript(b.path("linker/native-x86_64.ld"));
    const n6_neg_step = b.step("native-kernel-n6-negative", "Build N6 negative trap-site kernel (not default success image)");
    n6_neg_step.dependOn(&b.addInstallArtifact(n6_neg, .{}).step);

    const n6_rf_mod = mkNativeMod(b, "src/native/n6_restore_fail_root.zig", native_target, native_optimize);
    n6_rf_mod.addImport("main", native_kernel_mod);
    const n6_rf = b.addExecutable(.{
        .name = "zk-kernel-n6-restore-fail",
        .root_module = n6_rf_mod,
    });
    n6_rf.entry = .disabled;
    n6_rf.setLinkerScript(b.path("linker/native-x86_64.ld"));
    const n6_rf_step = b.step("native-kernel-n6-restore-fail", "Build N6 skip-FXRSTOR kernel (not default success image)");
    n6_rf_step.dependOn(&b.addInstallArtifact(n6_rf, .{}).step);

    // PE32+ UEFI loader (\EFI\BOOT\BOOTX64.EFI on the ESP).
    const uefi_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .none,
    });
    const uefi_optimize: std.builtin.OptimizeMode = .ReleaseSafe;
    const mkUefiMod = struct {
        fn f(b2: *std.Build, path: []const u8, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
            return b2.createModule(.{
                .root_source_file = b2.path(path),
                .target = t,
                .optimize = o,
                .red_zone = false,
            });
        }
    }.f;
    const u_boot_info = mkUefiMod(b, "src/native/boot_info.zig", uefi_target, uefi_optimize);
    const u_memmap = mkUefiMod(b, "src/native/memmap.zig", uefi_target, uefi_optimize);
    u_memmap.addImport("boot_info", u_boot_info);
    const u_initramfs = mkUefiMod(b, "src/native/initramfs.zig", uefi_target, uefi_optimize);
    const u_serial = mkUefiMod(b, "src/arch/x86_64/native/serial.zig", uefi_target, uefi_optimize);
    const native_efi_mod = mkUefiMod(b, "boot/uefi/main.zig", uefi_target, uefi_optimize);
    native_efi_mod.addImport("boot_info", u_boot_info);
    native_efi_mod.addImport("memmap", u_memmap);
    native_efi_mod.addImport("initramfs", u_initramfs);
    native_efi_mod.addImport("serial", u_serial);
    const native_efi = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = native_efi_mod,
    });
    const native_efi_install = b.addInstallArtifact(native_efi, .{});
    const native_efi_step = b.step("native-efi", "Build PE32+ UEFI loader");
    native_efi_step.dependOn(&native_efi_install.step);

    // Hosted contract tests for the shared native modules (validation logic
    // only; these never stand in for runtime boot/trap evidence). N5: one
    // explicit test artifact per module — named module tests never execute
    // through a comptime import, so each gets its own addTest/run root and
    // test-native depends on every run step.
    const h_boot_info = b.createModule(.{
        .root_source_file = b.path("src/native/boot_info.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const h_memmap = b.createModule(.{
        .root_source_file = b.path("src/native/memmap.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    h_memmap.addImport("boot_info", h_boot_info);
    const h_initramfs = b.createModule(.{
        .root_source_file = b.path("src/native/initramfs.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const h_mkesp = b.createModule(.{
        .root_source_file = b.path("tools/mkesp.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const native_test_step = b.step("test-native", "Run native boot contract tests");
    native_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = h_boot_info })).step);
    native_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = h_memmap })).step);
    native_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = h_initramfs })).step);
    native_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = h_mkesp })).step);
    const h_ebs_retry = b.createModule(.{
        .root_source_file = b.path("boot/uefi/ebs_retry.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const native_root_mod = b.createModule(.{
        .root_source_file = b.path("tests/native-boot/main.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    native_root_mod.addImport("boot_info", h_boot_info);
    native_root_mod.addImport("memmap", h_memmap);
    native_root_mod.addImport("initramfs", h_initramfs);
    native_root_mod.addImport("ebs_retry", h_ebs_retry);
    native_test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = native_root_mod })).step);

    // Hosted layout fixtures for the native descriptor tables. Shared named
    // gdt/idt/serial graph: idt.zig imports both, so anonymous modules fail.
    const h_serial = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/serial.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const h_gdt = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/gdt.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const h_idt = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/idt.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    h_idt.addImport("gdt", h_gdt);
    h_idt.addImport("serial", h_serial);
    const ntt_mod = b.createModule(.{
        .root_source_file = b.path("tests/native-tables/main.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    ntt_mod.addImport("gdt", h_gdt);
    ntt_mod.addImport("idt", h_idt);
    // Explicit LLVM is required for these imported/native inline-assembly fixtures across hosts.
    const run_ntt = b.addRunArtifact(b.addTest(.{ .root_module = ntt_mod, .use_llvm = true }));
    native_test_step.dependOn(&run_ntt.step);
    const ntt_step = b.step("test-native-tables", "Run native GDT/IDT layout fixtures");
    ntt_step.dependOn(&run_ntt.step);

    const h_pmm = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/pmm.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    h_pmm.addImport("boot_info", h_boot_info);
    const pmm_check = b.createModule(.{
        .root_source_file = b.path("tests/native-pmm/check.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    pmm_check.addImport("boot_info", h_boot_info);
    pmm_check.addImport("pmm", h_pmm);
    const run_pmm = b.addRunArtifact(b.addTest(.{ .root_module = pmm_check }));
    native_test_step.dependOn(&run_pmm.step);
    const pmm_step = b.step("test-native-pmm", "Run native PMM hosted fixtures");
    pmm_step.dependOn(&run_pmm.step);

    const run_ebs_retry = b.addRunArtifact(b.addTest(.{ .root_module = h_ebs_retry }));
    native_test_step.dependOn(&run_ebs_retry.step);
    const ebs_step = b.step("test-ebs-retry", "Run ExitBootServices retry policy tests");
    ebs_step.dependOn(&run_ebs_retry.step);

    const h_alloc_probe = b.createModule(.{
        .root_source_file = b.path("src/native/alloc_probe.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const traps_mod = b.createModule(.{
        .root_source_file = b.path("tests/native-traps/main.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    traps_mod.addImport("gdt", h_gdt);
    traps_mod.addImport("idt", h_idt);
    traps_mod.addImport("alloc_probe", h_alloc_probe);
    const run_traps = b.addRunArtifact(b.addTest(.{ .root_module = traps_mod, .use_llvm = true }));
    native_test_step.dependOn(&run_traps.step);
    const h_probes = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/probes.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const traps_control = b.createModule(.{
        .root_source_file = b.path("tests/native-traps/control.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    traps_control.addImport("probes", h_probes);
    const run_traps_control = b.addRunArtifact(b.addTest(.{ .root_module = traps_control, .use_llvm = true }));
    native_test_step.dependOn(&run_traps_control.step);
    const traps_step = b.step("test-native-traps", "Run native trap/alloc-probe hosted fixtures");
    traps_step.dependOn(&run_traps.step);
    traps_step.dependOn(&run_traps_control.step);

    // N5: ELF64 module tests and named-module companion, plus individual steps.
    const h_elf64 = b.createModule(.{
        .root_source_file = b.path("boot/uefi/elf64.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const run_elf64_tests = b.addRunArtifact(b.addTest(.{ .root_module = h_elf64 }));
    native_test_step.dependOn(&run_elf64_tests.step);
    const test_elf64_step = b.step("test-elf64", "Run ELF64 loader contract tests");
    test_elf64_step.dependOn(&run_elf64_tests.step);

    const h_elf64_dep = b.createModule(.{
        .root_source_file = b.path("boot/uefi/elf64.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const elf64_companion = b.createModule(.{
        .root_source_file = b.path("tests/native-elf/check.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    elf64_companion.addImport("elf64", h_elf64_dep);
    const run_elf64_companion = b.addRunArtifact(b.addTest(.{ .root_module = elf64_companion }));
    native_test_step.dependOn(&run_elf64_companion.step);
    const test_elf64_companion_step = b.step("test-elf64-companion", "Run ELF64 companion identity/span/entry fixtures");
    test_elf64_companion_step.dependOn(&run_elf64_companion.step);

    // KWP3a.1: hosted one-file newc `/init` and static-user ELF parser
    // contracts. Host-side parse fixtures only; not guest execution.
    // Not imported by native runtime roots in this slice.
    const h_initrd_newc = b.createModule(.{
        .root_source_file = b.path("src/native/initrd_newc.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const newc_check = b.createModule(.{
        .root_source_file = b.path("tests/native-user/newc_check.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    newc_check.addImport("initrd_newc", h_initrd_newc);
    const run_newc = b.addRunArtifact(b.addTest(.{ .root_module = newc_check }));
    native_test_step.dependOn(&run_newc.step);
    const h_user_elf = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/user_elf.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const elf_check = b.createModule(.{
        .root_source_file = b.path("tests/native-user/elf_check.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    elf_check.addImport("user_elf", h_user_elf);
    const run_user_elf = b.addRunArtifact(b.addTest(.{ .root_module = elf_check }));
    native_test_step.dependOn(&run_user_elf.step);
    const user_parsers_step = b.step("test-native-user-parsers", "Run native user parser hosted fixtures");
    user_parsers_step.dependOn(&run_newc.step);
    user_parsers_step.dependOn(&run_user_elf.step);

    // KWP3a.2a: hosted user VM construction/teardown and PMM adapter.
    // Not imported by the default native kernel.
    const h_user_vm = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/user_vm.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    h_user_vm.addImport("user_elf", h_user_elf);
    const vm_check = b.createModule(.{
        .root_source_file = b.path("tests/native-user/vm_check.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    vm_check.addImport("user_vm", h_user_vm);
    vm_check.addImport("user_elf", h_user_elf);
    const run_vm_check = b.addRunArtifact(b.addTest(.{ .root_module = vm_check }));

    const h_user_vm_pmm = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/user_vm_pmm.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    h_user_vm_pmm.addImport("pmm", h_pmm);
    const vm_pmm_check = b.createModule(.{
        .root_source_file = b.path("tests/native-user/vm_pmm_check.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    vm_pmm_check.addImport("user_vm_pmm", h_user_vm_pmm);
    vm_pmm_check.addImport("pmm", h_pmm);
    vm_pmm_check.addImport("boot_info", h_boot_info);
    vm_pmm_check.addImport("user_vm", h_user_vm);
    vm_pmm_check.addImport("user_elf", h_user_elf);
    const run_vm_pmm_check = b.addRunArtifact(b.addTest(.{ .root_module = vm_pmm_check }));

    const n_user_elf = mkNativeMod(b, "src/arch/x86_64/native/user_elf.zig", native_target, native_optimize);
    const n_user_vm = mkNativeMod(b, "src/arch/x86_64/native/user_vm.zig", native_target, native_optimize);
    n_user_vm.addImport("user_elf", n_user_elf);
    const n_user_vm_pmm = mkNativeMod(b, "src/arch/x86_64/native/user_vm_pmm.zig", native_target, native_optimize);
    n_user_vm_pmm.addImport("pmm", n_pmm);
    const native_vm_compile_mod = mkNativeMod(b, "tests/native-user/vm_native_compile.zig", native_target, native_optimize);
    native_vm_compile_mod.addImport("user_vm", n_user_vm);
    native_vm_compile_mod.addImport("user_vm_pmm", n_user_vm_pmm);
    native_vm_compile_mod.addImport("paging", n_paging);
    native_vm_compile_mod.addImport("pmm", n_pmm);
    native_vm_compile_mod.addImport("boot_info", n_boot_info);
    const native_vm_compile_obj = b.addObject(.{
        .name = "user-vm-native-compile",
        .root_module = native_vm_compile_mod,
        .use_llvm = true,
    });
    const native_vm_compile_install = b.addInstallFile(
        native_vm_compile_obj.getEmittedBin(),
        "native/user-vm-native-compile.o",
    );

    const vm_step = b.step("test-native-user-vm", "Run hosted user VM construction fixtures");
    vm_step.dependOn(&run_vm_check.step);
    vm_step.dependOn(&run_vm_pmm_check.step);
    vm_step.dependOn(&native_vm_compile_install.step);
    native_test_step.dependOn(&run_vm_check.step);
    native_test_step.dependOn(&run_vm_pmm_check.step);
    native_test_step.dependOn(&native_vm_compile_install.step);

    // KWP3a.2b: opt-in CPL0 private-VM probe. Distinct roots; default
    // native-kernel is unchanged. Named options select positive and the
    // two compile-time negative artifacts.
    const n_vm_cr3 = mkNativeMod(b, "src/arch/x86_64/native/vm_cr3.zig", native_target, native_optimize);
    const n_vm_fixture = mkNativeMod(b, "src/native/vm_probe_fixture.zig", native_target, native_optimize);
    n_vm_fixture.addImport("user_elf", n_user_elf);
    const n_vm_probe = mkNativeMod(b, "src/native/vm_probe.zig", native_target, native_optimize);
    n_vm_probe.addImport("serial", n_serial);
    n_vm_probe.addImport("gdt", n_gdt);
    n_vm_probe.addImport("idt", n_idt);
    n_vm_probe.addImport("paging", n_paging);
    n_vm_probe.addImport("pmm", n_pmm);
    n_vm_probe.addImport("boot_info", n_boot_info);
    n_vm_probe.addImport("user_vm", n_user_vm);
    n_vm_probe.addImport("user_vm_pmm", n_user_vm_pmm);
    n_vm_probe.addImport("user_elf", n_user_elf);
    n_vm_probe.addImport("vm_probe_fixture", n_vm_fixture);
    n_vm_probe.addImport("vm_cr3", n_vm_cr3);

    const addVmKernel = struct {
        fn f(
            b2: *std.Build,
            t: std.Build.ResolvedTarget,
            o: std.builtin.OptimizeMode,
            main_mod: *std.Build.Module,
            probe_mod: *std.Build.Module,
            name: []const u8,
            skip: bool,
            wro: bool,
        ) *std.Build.Step.Compile {
            const opts = b2.addOptions();
            opts.addOption(bool, "skip_switch", skip);
            opts.addOption(bool, "writable_ro", wro);
            const root_mod = b2.createModule(.{
                .root_source_file = b2.path("src/native/vm_probe_root.zig"),
                .target = t,
                .optimize = o,
                .red_zone = false,
                .stack_check = false,
                .omit_frame_pointer = true,
                .code_model = .small,
            });
            root_mod.addImport("main", main_mod);
            root_mod.addImport("vm_probe", probe_mod);
            root_mod.addImport("vm_probe_options", opts.createModule());
            const vm_kernel = b2.addExecutable(.{ .name = name, .root_module = root_mod });
            vm_kernel.entry = .disabled;
            vm_kernel.setLinkerScript(b2.path("linker/native-x86_64.ld"));
            return vm_kernel;
        }
    }.f;

    const vm_pos = addVmKernel(b, native_target, native_optimize, native_kernel_mod, n_vm_probe, "zk-kernel-vm-probe", false, false);
    const vm_skip = addVmKernel(b, native_target, native_optimize, native_kernel_mod, n_vm_probe, "zk-kernel-vm-skip-switch", true, false);
    const vm_wro = addVmKernel(b, native_target, native_optimize, native_kernel_mod, n_vm_probe, "zk-kernel-vm-writable-ro", false, true);
    const vm_pos_install = b.addInstallArtifact(vm_pos, .{});
    const vm_skip_install = b.addInstallArtifact(vm_skip, .{});
    const vm_wro_install = b.addInstallArtifact(vm_wro, .{});
    const vm_pos_step = b.step("native-kernel-vm-probe", "Build opt-in CPL0 VM probe kernel (not default)");
    vm_pos_step.dependOn(&vm_pos_install.step);
    const vm_skip_step = b.step("native-kernel-vm-skip-switch", "Build skip-switch negative VM probe kernel (not default)");
    vm_skip_step.dependOn(&vm_skip_install.step);
    const vm_wro_step = b.step("native-kernel-vm-writable-ro", "Build writable-RO negative VM probe kernel (not default)");
    vm_wro_step.dependOn(&vm_wro_install.step);

    const h_paging = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/paging.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    h_paging.addImport("serial", h_serial);
    const h_vm_cr3 = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/native/vm_cr3.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const h_vm_fixture = b.createModule(.{
        .root_source_file = b.path("src/native/vm_probe_fixture.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    h_vm_fixture.addImport("user_elf", h_user_elf);
    const h_vm_probe = b.createModule(.{
        .root_source_file = b.path("src/native/vm_probe.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    h_vm_probe.addImport("serial", h_serial);
    h_vm_probe.addImport("gdt", h_gdt);
    h_vm_probe.addImport("idt", h_idt);
    h_vm_probe.addImport("paging", h_paging);
    h_vm_probe.addImport("pmm", h_pmm);
    h_vm_probe.addImport("boot_info", h_boot_info);
    h_vm_probe.addImport("user_vm", h_user_vm);
    h_vm_probe.addImport("user_vm_pmm", h_user_vm_pmm);
    h_vm_probe.addImport("user_elf", h_user_elf);
    h_vm_probe.addImport("vm_probe_fixture", h_vm_fixture);
    h_vm_probe.addImport("vm_cr3", h_vm_cr3);
    const vm_probe_check = b.createModule(.{
        .root_source_file = b.path("tests/native-user/vm_probe_check.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    vm_probe_check.addImport("user_elf", h_user_elf);
    vm_probe_check.addImport("user_vm", h_user_vm);
    vm_probe_check.addImport("vm_probe_fixture", h_vm_fixture);
    vm_probe_check.addImport("vm_cr3", h_vm_cr3);
    vm_probe_check.addImport("vm_probe", h_vm_probe);
    const run_vm_probe_check = b.addRunArtifact(b.addTest(.{ .root_module = vm_probe_check, .use_llvm = true }));
    const vm_probe_test_step = b.step("test-native-vm-probe", "Run hosted VM probe fixture/walker checks");
    vm_probe_test_step.dependOn(&run_vm_probe_check.step);
    native_test_step.dependOn(&run_vm_probe_check.step);
    vm_step.dependOn(&run_vm_probe_check.step);

    // Host tools: initramfs builder + FAT16 ESP image builder.
    const mkinitramfs_mod = b.createModule(.{
        .root_source_file = b.path("tools/mkinitramfs.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    mkinitramfs_mod.addImport("initramfs", b.createModule(.{
        .root_source_file = b.path("src/native/initramfs.zig"),
        .target = host_target,
        .optimize = optimize,
    }));
    const mkinitramfs = b.addExecutable(.{
        .name = "mkinitramfs",
        .root_module = mkinitramfs_mod,
    });
    const mkesp = b.addExecutable(.{
        .name = "mkesp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkesp.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    const imginfo = b.addExecutable(.{
        .name = "imginfo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/imginfo.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    const tools_step = b.step("native-tools", "Build native image host tools");
    tools_step.dependOn(&b.addInstallArtifact(mkinitramfs, .{}).step);
    tools_step.dependOn(&b.addInstallArtifact(mkesp, .{}).step);
    tools_step.dependOn(&b.addInstallArtifact(imginfo, .{}).step);

    // ESP image assembly: initramfs -> FAT16 ESP with BOOTX64.EFI + payload.
    const native_dir = b.pathJoin(&.{ b.install_prefix, "native" });
    const initramfs_bin = b.pathJoin(&.{ native_dir, "initramfs.bin" });
    const esp_img = b.pathJoin(&.{ native_dir, "esp.img" });

    const run_mkinitramfs = b.addRunArtifact(mkinitramfs);
    run_mkinitramfs.addArgs(&.{ "--out", initramfs_bin });

    const run_mkesp = b.addRunArtifact(mkesp);
    run_mkesp.addArgs(&.{
        "--out", esp_img,
        "--size-mb", "64",
        "--bootx64", b.getInstallPath(.bin, "BOOTX64.efi"),
        "--kernel", b.getInstallPath(.bin, "zk-kernel"),
        "--initramfs", initramfs_bin,
    });
    run_mkesp.step.dependOn(&run_mkinitramfs.step);
    run_mkesp.step.dependOn(&native_kernel_install.step);
    run_mkesp.step.dependOn(&native_efi_install.step);

    const native_image_step = b.step("native-image", "Assemble native ESP image");
    native_image_step.dependOn(&run_mkesp.step);

    const addVmEsp = struct {
        fn f(
            b2: *std.Build,
            mkesp_exe: *std.Build.Step.Compile,
            initrd: []const u8,
            out_name: []const u8,
            kernel_name: []const u8,
            kernel_install: *std.Build.Step.InstallArtifact,
            efi_install: *std.Build.Step.InstallArtifact,
            mkinit: *std.Build.Step.Run,
            native_prefix: []const u8,
        ) *std.Build.Step.Run {
            const run = b2.addRunArtifact(mkesp_exe);
            run.addArgs(&.{
                "--out", b2.pathJoin(&.{ native_prefix, out_name }),
                "--size-mb", "64",
                "--bootx64", b2.getInstallPath(.bin, "BOOTX64.efi"),
                "--kernel", b2.getInstallPath(.bin, kernel_name),
                "--initramfs", initrd,
            });
            run.step.dependOn(&mkinit.step);
            run.step.dependOn(&kernel_install.step);
            run.step.dependOn(&efi_install.step);
            return run;
        }
    }.f;
    const run_mkesp_vm_pos = addVmEsp(b, mkesp, initramfs_bin, "esp-vm-probe.img", "zk-kernel-vm-probe", vm_pos_install, native_efi_install, run_mkinitramfs, native_dir);
    const run_mkesp_vm_skip = addVmEsp(b, mkesp, initramfs_bin, "esp-vm-skip-switch.img", "zk-kernel-vm-skip-switch", vm_skip_install, native_efi_install, run_mkinitramfs, native_dir);
    const run_mkesp_vm_wro = addVmEsp(b, mkesp, initramfs_bin, "esp-vm-writable-ro.img", "zk-kernel-vm-writable-ro", vm_wro_install, native_efi_install, run_mkinitramfs, native_dir);
    const vm_image_step = b.step("native-image-vm-probe", "Assemble opt-in VM probe ESP images (not default native-image)");
    vm_image_step.dependOn(&run_mkesp_vm_pos.step);
    vm_image_step.dependOn(&run_mkesp_vm_skip.step);
    vm_image_step.dependOn(&run_mkesp_vm_wro.step);

    // Full native qualification. Direct Python on every host; Windows also
    // keeps scripts/qualify-native/qualify.ps1 as an optional wrapper.
    // imginfo basename follows the host executable suffix.
    const python = if (builtin.os.tag == .windows) "python" else "python3";
    const imginfo_basename = if (builtin.os.tag == .windows) "imginfo.exe" else "imginfo";
    const evidence_parent = b.pathJoin(&.{ b.install_prefix, "qualify-native-evidence" });
    const qualify_cmd = b.addSystemCommand(&.{
        python, "-B", "scripts/qualify-native/qualify.py",
        "--esp-image", esp_img,
        "--loader", b.getInstallPath(.bin, "BOOTX64.efi"),
        "--kernel", b.getInstallPath(.bin, "zk-kernel"),
        "--initramfs", initramfs_bin,
        "--imginfo", b.getInstallPath(.bin, imginfo_basename),
        "--evidence-parent", evidence_parent,
    });
    qualify_cmd.step.dependOn(&run_mkesp.step);
    qualify_cmd.step.dependOn(&b.addInstallArtifact(imginfo, .{}).step);
    const qualify_step = b.step("qualify-native", "Run native QEMU/OVMF qualification");
    qualify_step.dependOn(&qualify_cmd.step);

    const qualify_vm_cmd = b.addSystemCommand(&.{
        python, "-B", "scripts/qualify-native/qualify_vm.py",
        "--esp-image", b.pathJoin(&.{ native_dir, "esp-vm-probe.img" }),
        "--loader", b.getInstallPath(.bin, "BOOTX64.efi"),
        "--kernel", b.getInstallPath(.bin, "zk-kernel-vm-probe"),
        "--initramfs", initramfs_bin,
        "--imginfo", b.getInstallPath(.bin, imginfo_basename),
        "--evidence-parent", b.pathJoin(&.{ b.install_prefix, "qualify-native-vm-evidence" }),
        "--timeout", "90",
        "--mode", "positive",
    });
    qualify_vm_cmd.step.dependOn(&run_mkesp_vm_pos.step);
    qualify_vm_cmd.step.dependOn(&b.addInstallArtifact(imginfo, .{}).step);
    const qualify_vm_step = b.step("qualify-native-vm", "Run opt-in CPL0 VM mapping qualification (not default bootstrap)");
    qualify_vm_step.dependOn(&qualify_vm_cmd.step);

    const qualify_tests = b.addSystemCommand(&.{
        python, "-B", "scripts/qualify-native/run-tests.py",
    });
    const qualify_test_step = b.step("test-native-qualification", "Run native qualifier regression tests");
    qualify_test_step.dependOn(&qualify_tests.step);

    // Deliberately fail-closed Linux HTTP bootstrap.  It exposes liveness,
    // readiness, and capability truth only; it never runs guest code.
    const api_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    // Hosted named modules so fixture tests, bootstrap, and engine share one
    // contract type identity. Relative @import of files outside a module root
    // is rejected by Zig 0.16.
    const contract_mod = b.createModule(.{
        .root_source_file = b.path("supervisor/contract.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const bootstrap_mod = b.createModule(.{
        .root_source_file = b.path("supervisor/bootstrap.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_contract", .module = contract_mod },
        },
    });
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("engine/contracts.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_contract", .module = contract_mod },
        },
    });

    const api_contract_mod = b.createModule(.{
        .root_source_file = b.path("supervisor/contract.zig"),
        .target = api_target,
        .optimize = optimize,
    });
    const api_mod = b.createModule(.{
        .root_source_file = b.path("supervisor/bootstrap_main.zig"),
        .target = api_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_contract", .module = api_contract_mod },
        },
    });
    const api_exe = b.addExecutable(.{
        .name = "zig-sandbox",
        .root_module = api_mod,
    });
    const api_step = b.step("sandbox-api", "Build fail-closed Linux sandbox API bootstrap");
    api_step.dependOn(&b.addInstallArtifact(api_exe, .{}).step);

    const bootstrap_tests = b.addTest(.{ .root_module = bootstrap_mod });
    const bootstrap_test_step = b.step("test-bootstrap", "Run fail-closed API contract tests");
    bootstrap_test_step.dependOn(&b.addRunArtifact(bootstrap_tests).step);

    const engine_tests = b.addTest(.{ .root_module = engine_mod });
    const engine_test_step = b.step("test-engine", "Run unavailable subsystem seam tests");
    engine_test_step.dependOn(&b.addRunArtifact(engine_tests).step);

    // Zig 0.16 forbids @embedFile outside a module package root. Copy the
    // OpenAPI document into a generated module whose root contains it so
    // contract tests keep the MutualTLS / identity-header assertions.
    const openapi_wf = b.addWriteFiles();
    _ = openapi_wf.addCopyFile(b.path("docs/sandbox-api.openapi.yaml"), "sandbox-api.openapi.yaml");
    const openapi_embed = openapi_wf.add(
        "openapi_embed.zig",
        \\pub const spec: []const u8 = @embedFile("sandbox-api.openapi.yaml");
        \\
        ,
    );
    const openapi_mod = b.createModule(.{
        .root_source_file = openapi_embed,
    });

    const contract_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/contract/root.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_contract", .module = contract_mod },
            .{ .name = "sandbox_bootstrap", .module = bootstrap_mod },
            .{ .name = "sandbox_engine", .module = engine_mod },
            .{ .name = "openapi_spec", .module = openapi_mod },
        },
    }) });
    const contract_test_step = b.step("test-contract", "Run independent sandbox API contract fixtures");
    contract_test_step.dependOn(&b.addRunArtifact(contract_tests).step);

    const sandbox_test_step = b.step("test-sandbox", "Run supervisor, bootstrap, engine, and contract tests");
    sandbox_test_step.dependOn(sup_test_step);
    sandbox_test_step.dependOn(bootstrap_test_step);
    sandbox_test_step.dependOn(engine_test_step);
    sandbox_test_step.dependOn(contract_test_step);

    // Opt-in TS0 local SDK helper. Host userspace stdio process; not the Linux
    // TCP bootstrap, not default install, and not a VM/kernel payload.
    const helper_logic_mod = b.createModule(.{
        .root_source_file = b.path("supervisor/sdk_helper.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sandbox_contract", .module = contract_mod },
            .{ .name = "sandbox_bootstrap", .module = bootstrap_mod },
        },
    });
    const helper_main_mod = b.createModule(.{
        .root_source_file = b.path("supervisor/sdk_helper_main.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdk_helper", .module = helper_logic_mod },
        },
    });
    const helper_exe = b.addExecutable(.{
        .name = "zig-sandbox-helper",
        .root_module = helper_main_mod,
    });
    const helper_step = b.step("sandbox-helper", "Build portable TS0 local SDK stdio helper (opt-in)");
    helper_step.dependOn(&b.addInstallArtifact(helper_exe, .{}).step);

    const helper_tests = b.addTest(.{ .root_module = helper_logic_mod });
    const helper_test_step = b.step("test-sdk-helper", "Run TS0 local SDK helper protocol tests (opt-in)");
    helper_test_step.dependOn(&b.addRunArtifact(helper_tests).step);

    // AP2a.0: pinned SQLite amalgamation. Opt-in only; not default install/API
    // and not wired into engine/contracts.Store readiness.
    const sqlite_c_flags = [_][]const u8{
        "-std=c99",
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION=1",
        "-DSQLITE_DQS=0",
        "-DSQLITE_USE_URI=0",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
        "-DSQLITE_OMIT_DEPRECATED=1",
    };
    const makeSqliteC = struct {
        fn f(
            b2: *std.Build,
            target: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
            flags: []const []const u8,
        ) *std.Build.Module {
            const mod = b2.createModule(.{
                .root_source_file = b2.path("engine/sqlite_c.zig"),
                .target = target,
                .optimize = opt,
                .link_libc = true,
                .sanitize_c = .off,
            });
            mod.addIncludePath(b2.path("vendor/sqlite"));
            mod.addCSourceFile(.{
                .file = b2.path("vendor/sqlite/sqlite3.c"),
                .flags = flags,
                .language = .c,
            });
            return mod;
        }
    }.f;

    const host_sqlite_c = makeSqliteC(b, host_target, optimize, &sqlite_c_flags);
    const dep_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/store/dependency_check.zig"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sqlite_c", .module = host_sqlite_c },
        },
    });
    const dep_tests = b.addTest(.{ .root_module = dep_test_mod });
    const run_dep_tests = b.addRunArtifact(dep_tests);
    const dep_test_step = b.step("test-store-dependency", "Run actual-file SQLite dependency gate");
    dep_test_step.dependOn(&run_dep_tests.step);

    const linux_sqlite_c = makeSqliteC(b, api_target, optimize, &sqlite_c_flags);
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("tests/store/dependency_check.zig"),
        .target = api_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sqlite_c", .module = linux_sqlite_c },
        },
    });
    const probe_exe = b.addExecutable(.{
        .name = "store-dependency-probe",
        .root_module = probe_mod,
    });
    const probe_step = b.step("store-dependency-probe", "Build linux-musl SQLite seed/reopen probe");
    probe_step.dependOn(&b.addInstallArtifact(probe_exe, .{}).step);
}
