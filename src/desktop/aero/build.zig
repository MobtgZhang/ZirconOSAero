const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nt61_aero_defaults_mod = b.createModule(.{
        .root_source_file = b.path("../../config/nt61_aero_defaults.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_mod);

    // Static library (.lib) — Windows-compatible archive
    const lib = b.addLibrary(.{
        .name = "ZirconOSAero",
        .linkage = .static,
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const dll_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    dll_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_mod);

    // DLL — Windows-compatible dynamic library (PE format when targeting windows)
    const dll = b.addLibrary(.{
        .name = "ZirconOSAero",
        .linkage = .dynamic,
        .root_module = dll_mod,
    });
    const install_dll = b.addInstallArtifact(dll, .{});
    const dll_step = b.step("dll", "Build ZirconOSAero.dll (shared library)");
    dll_step.dependOn(&install_dll.step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // main.zig 与 root.zig 同属本模块，theme.zig 的 @import("nt61_aero_defaults") 解析自此处
    exe_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_mod);

    // EXE — Windows PE-compatible executable
    const exe = b.addExecutable(.{
        .name = "ZirconOSAero",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_mod);

    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
