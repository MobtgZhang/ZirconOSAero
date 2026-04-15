// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Build Configuration
// D3D10 Desktop Window Manager with full compositor support

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const enable_d3d10 = b.option(bool, "enable_d3d10", "Enable D3D10 hardware acceleration") orelse true;
    const enable_debug = b.option(bool, "enable_debug", "Enable debug features") orelse false;

    // Add build options
    const dwm_build_opts = b.addOptions();
    dwm_build_opts.addOption(bool, "enable_d3d10", enable_d3d10);
    dwm_build_opts.addOption(bool, "enable_debug", enable_debug);

    // Configuration modules
    const config_mod = b.createModule(.{
        .root_source_file = b.path("config/dwm_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const theme_mod = b.createModule(.{
        .root_source_file = b.path("config/theme.zig"),
        .target = target,
        .optimize = optimize,
    });

    // D3D10 modules
    const d3d10_types_mod = b.createModule(.{
        .root_source_file = b.path("d3d10/d3d10_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const d3d10_errors_mod = b.createModule(.{
        .root_source_file = b.path("d3d10/d3d10_errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    const d3d10_mod = b.createModule(.{
        .root_source_file = b.path("d3d10/d3d10.zig"),
        .target = target,
        .optimize = optimize,
    });
    d3d10_mod.addOptions("build_options", dwm_build_opts);

    // DXGI modules
    const dxgi_types_mod = b.createModule(.{
        .root_source_file = b.path("dxgi/dxgi_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dxgi_errors_mod = b.createModule(.{
        .root_source_file = b.path("dxgi/dxgi_errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dxgi_mod = b.createModule(.{
        .root_source_file = b.path("dxgi/dxgi.zig"),
        .target = target,
        .optimize = optimize,
    });
    dxgi_mod.addOptions("build_options", dwm_build_opts);

    // Compositor modules
    const damage_mod = b.createModule(.{
        .root_source_file = b.path("compositor/damage.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vsync_mod = b.createModule(.{
        .root_source_file = b.path("compositor/vsync.zig"),
        .target = target,
        .optimize = optimize,
    });

    const surface_mgr_mod = b.createModule(.{
        .root_source_file = b.path("compositor/surface_mgr.zig"),
        .target = target,
        .optimize = optimize,
    });

    const compositor_mod = b.createModule(.{
        .root_source_file = b.path("compositor/compositor.zig"),
        .target = target,
        .optimize = optimize,
    });
    compositor_mod.addOptions("build_options", dwm_build_opts);

    // Shader modules
    const shaders_mod = b.createModule(.{
        .root_source_file = b.path("shaders/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });

    const blur_shader_mod = b.createModule(.{
        .root_source_file = b.path("shaders/blur_shader.zig"),
        .target = target,
        .optimize = optimize,
    });

    const glass_shader_mod = b.createModule(.{
        .root_source_file = b.path("shaders/glass_shader.zig"),
        .target = target,
        .optimize = optimize,
    });

    const shadow_shader_mod = b.createModule(.{
        .root_source_file = b.path("shaders/shadow_shader.zig"),
        .target = target,
        .optimize = optimize,
    });

    const shader_manager_mod = b.createModule(.{
        .root_source_file = b.path("shaders/shader_manager.zig"),
        .target = target,
        .optimize = optimize,
    });

    // WDDM modules
    const wddm_mod = b.createModule(.{
        .root_source_file = b.path("wddm/wddm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vidmm_mod = b.createModule(.{
        .root_source_file = b.path("wddm/vidmm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cmd_buffer_mod = b.createModule(.{
        .root_source_file = b.path("wddm/cmd_buffer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fence_mod = b.createModule(.{
        .root_source_file = b.path("wddm/fence.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scheduler_mod = b.createModule(.{
        .root_source_file = b.path("wddm/scheduler.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Win32k modules
    const win32k_mod = b.createModule(.{
        .root_source_file = b.path("win32k/win32k.zig"),
        .target = target,
        .optimize = optimize,
    });

    const wmgr_mod = b.createModule(.{
        .root_source_file = b.path("win32k/wmgr.zig"),
        .target = target,
        .optimize = optimize,
    });

    const surface_redirect_mod = b.createModule(.{
        .root_source_file = b.path("win32k/surface_redirect.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gre_mod = b.createModule(.{
        .root_source_file = b.path("win32k/gre.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ddi_mod = b.createModule(.{
        .root_source_file = b.path("win32k/ddi.zig"),
        .target = target,
        .optimize = optimize,
    });

    // DWM API modules
    const dwmapi_types_mod = b.createModule(.{
        .root_source_file = b.path("dwmapi/dwmapi_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dwmapi_errors_mod = b.createModule(.{
        .root_source_file = b.path("dwmapi/dwmapi_errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dwmapi_mod = b.createModule(.{
        .root_source_file = b.path("dwmapi/dwmapi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dwm_composition_mod = b.createModule(.{
        .root_source_file = b.path("dwmapi/dwm_composition.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dwm_extend_frame_mod = b.createModule(.{
        .root_source_file = b.path("dwmapi/dwm_extend_frame.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dwm_blur_behind_mod = b.createModule(.{
        .root_source_file = b.path("dwmapi/dwm_blur_behind.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dwm_thumbnail_mod = b.createModule(.{
        .root_source_file = b.path("dwmapi/dwm_thumbnail.zig"),
        .target = target,
        .optimize = optimize,
    });

    // UI modules
    const ui_root_mod = b.createModule(.{
        .root_source_file = b.path("ui/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // GPU Pipeline module
    const gpu_pipeline_mod = b.createModule(.{
        .root_source_file = b.path("gpu_pipeline.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Window manager module
    const window_manager_mod = b.createModule(.{
        .root_source_file = b.path("window_manager.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main DWM module
    const dwm_root_mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    dwm_root_mod.addOptions("build_options", dwm_build_opts);

    // ============================================================================
    // Static Library (.lib)
    // ============================================================================
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", dwm_build_opts);

    lib_mod.addImport("config", config_mod);
    lib_mod.addImport("theme", theme_mod);
    lib_mod.addImport("d3d10_types", d3d10_types_mod);
    lib_mod.addImport("d3d10_errors", d3d10_errors_mod);
    lib_mod.addImport("d3d10", d3d10_mod);
    lib_mod.addImport("dxgi_types", dxgi_types_mod);
    lib_mod.addImport("dxgi_errors", dxgi_errors_mod);
    lib_mod.addImport("dxgi", dxgi_mod);
    lib_mod.addImport("damage", damage_mod);
    lib_mod.addImport("vsync", vsync_mod);
    lib_mod.addImport("surface_mgr", surface_mgr_mod);
    lib_mod.addImport("compositor", compositor_mod);
    lib_mod.addImport("shaders", shaders_mod);
    lib_mod.addImport("blur_shader", blur_shader_mod);
    lib_mod.addImport("glass_shader", glass_shader_mod);
    lib_mod.addImport("shadow_shader", shadow_shader_mod);
    lib_mod.addImport("shader_manager", shader_manager_mod);
    lib_mod.addImport("wddm", wddm_mod);
    lib_mod.addImport("vidmm", vidmm_mod);
    lib_mod.addImport("cmd_buffer", cmd_buffer_mod);
    lib_mod.addImport("fence", fence_mod);
    lib_mod.addImport("scheduler", scheduler_mod);
    lib_mod.addImport("win32k", win32k_mod);
    lib_mod.addImport("wmgr", wmgr_mod);
    lib_mod.addImport("surface_redirect", surface_redirect_mod);
    lib_mod.addImport("gre", gre_mod);
    lib_mod.addImport("ddi", ddi_mod);
    lib_mod.addImport("dwmapi_types", dwmapi_types_mod);
    lib_mod.addImport("dwmapi_errors", dwmapi_errors_mod);
    lib_mod.addImport("dwmapi", dwmapi_mod);
    lib_mod.addImport("dwm_composition", dwm_composition_mod);
    lib_mod.addImport("dwm_extend_frame", dwm_extend_frame_mod);
    lib_mod.addImport("dwm_blur_behind", dwm_blur_behind_mod);
    lib_mod.addImport("dwm_thumbnail", dwm_thumbnail_mod);
    lib_mod.addImport("ui", ui_root_mod);
    lib_mod.addImport("gpu_pipeline", gpu_pipeline_mod);
    lib_mod.addImport("window_manager", window_manager_mod);

    const lib = b.addLibrary(.{
        .name = "ZirconOSDWM",
        .linkage = .static,
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    // ============================================================================
    // DLL Build
    // ============================================================================
    const dll_mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    dll_mod.addOptions("build_options", dwm_build_opts);

    const dll = b.addLibrary(.{
        .name = "ZirconOSDWM",
        .linkage = .dynamic,
        .root_module = dll_mod,
    });

    dll.addImport("config", config_mod);
    dll.addImport("theme", theme_mod);
    dll.addImport("d3d10_types", d3d10_types_mod);
    dll.addImport("d3d10_errors", d3d10_errors_mod);
    dll.addImport("d3d10", d3d10_mod);
    dll.addImport("dxgi_types", dxgi_types_mod);
    dll.addImport("dxgi_errors", dxgi_errors_mod);
    dll.addImport("dxgi", dxgi_mod);
    dll.addImport("damage", damage_mod);
    dll.addImport("vsync", vsync_mod);
    dll.addImport("surface_mgr", surface_mgr_mod);
    dll.addImport("compositor", compositor_mod);
    dll.addImport("shaders", shaders_mod);
    dll.addImport("blur_shader", blur_shader_mod);
    dll.addImport("glass_shader", glass_shader_mod);
    dll.addImport("shadow_shader", shadow_shader_mod);
    dll.addImport("shader_manager", shader_manager_mod);
    dll.addImport("wddm", wddm_mod);
    dll.addImport("vidmm", vidmm_mod);
    dll.addImport("cmd_buffer", cmd_buffer_mod);
    dll.addImport("fence", fence_mod);
    dll.addImport("scheduler", scheduler_mod);
    dll.addImport("win32k", win32k_mod);
    dll.addImport("wmgr", wmgr_mod);
    dll.addImport("surface_redirect", surface_redirect_mod);
    dll.addImport("gre", gre_mod);
    dll.addImport("ddi", ddi_mod);
    dll.addImport("dwmapi_types", dwmapi_types_mod);
    dll.addImport("dwmapi_errors", dwmapi_errors_mod);
    dll.addImport("dwmapi", dwmapi_mod);
    dll.addImport("dwm_composition", dwm_composition_mod);
    dll.addImport("dwm_extend_frame", dwm_extend_frame_mod);
    dll.addImport("dwm_blur_behind", dwm_blur_behind_mod);
    dll.addImport("dwm_thumbnail", dwm_thumbnail_mod);
    dll.addImport("ui", ui_root_mod);
    dll.addImport("gpu_pipeline", gpu_pipeline_mod);
    dll.addImport("window_manager", window_manager_mod);

    const install_dll = b.addInstallArtifact(dll, .{});
    const dll_step = b.step("dll", "Build ZirconOSDWM.dll");
    dll_step.dependOn(&install_dll.step);

    // ============================================================================
    // Test Module
    // ============================================================================
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/dwm_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", dwm_build_opts);
    test_mod.addAnonymousImport("dwm", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    lib_unit_tests.addImport("config", config_mod);
    lib_unit_tests.addImport("theme", theme_mod);
    lib_unit_tests.addImport("d3d10", d3d10_mod);
    lib_unit_tests.addImport("dxgi", dxgi_mod);
    lib_unit_tests.addImport("damage", damage_mod);
    lib_unit_tests.addImport("vsync", vsync_mod);
    lib_unit_tests.addImport("surface_mgr", surface_mgr_mod);
    lib_unit_tests.addImport("compositor", compositor_mod);
    lib_unit_tests.addImport("shaders", shaders_mod);
    lib_unit_tests.addImport("wddm", wddm_mod);
    lib_unit_tests.addImport("win32k", win32k_mod);
    lib_unit_tests.addImport("dwmapi", dwmapi_mod);
    lib_unit_tests.addImport("window_manager", window_manager_mod);
    lib_unit_tests.addImport("gpu_pipeline", gpu_pipeline_mod);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run DWM unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
