const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nt61_aero_defaults_mod = b.createModule(.{
        .root_source_file = b.path("../../config/nt61_aero_defaults.zig"),
        .target = target,
        .optimize = optimize,
    });

    const aero_flag_mapping_mod = b.createModule(.{
        .root_source_file = b.path("../../config/aero_flag_mapping.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dwm_nt61_api_contract_mod = b.createModule(.{
        .root_source_file = b.path("../../config/dwm_nt61_api_contract.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add DWM module dependency
    const dwm_mod = b.createModule(.{
        .root_source_file = b.path("../dwm/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add image library module dependency
    const ico_mod = b.createModule(.{
        .root_source_file = b.path("../../libs/image/ico.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("nt61_aero_defaults", nt61_aero_defaults_mod);
    lib_mod.addImport("aero_flag_mapping", aero_flag_mapping_mod);
    lib_mod.addImport("dwm_nt61_api_contract", dwm_nt61_api_contract_mod);
    lib_mod.addImport("dwm", dwm_mod);
    lib_mod.addImport("ico", ico_mod);

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
    dll_mod.addImport("aero_flag_mapping", aero_flag_mapping_mod);
    dll_mod.addImport("dwm", dwm_mod);
    dll_mod.addImport("ico", ico_mod);

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
    exe_mod.addImport("aero_flag_mapping", aero_flag_mapping_mod);
    exe_mod.addImport("dwm_nt61_api_contract", dwm_nt61_api_contract_mod);
    exe_mod.addImport("dwm", dwm_mod);
    exe_mod.addImport("ico", ico_mod);

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
    test_mod.addImport("aero_flag_mapping", aero_flag_mapping_mod);
    test_mod.addImport("dwm_nt61_api_contract", dwm_nt61_api_contract_mod);
    test_mod.addImport("dwm", dwm_mod);
    test_mod.addImport("ico", ico_mod);

    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
