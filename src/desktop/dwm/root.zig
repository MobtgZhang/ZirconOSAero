// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Root Module Entry Point

const std = @import("std");

// Export all modules
pub const d3d10 = @import("d3d10/d3d10.zig");
pub const dxgi = @import("dxgi/dxgi.zig");
pub const dwmapi = @import("dwmapi/dwmapi.zig");
pub const dwm_composition = @import("dwmapi/dwm_composition.zig");
pub const dwm_extend_frame = @import("dwmapi/dwm_extend_frame.zig");
pub const dwm_blur_behind = @import("dwmapi/dwm_blur_behind.zig");
pub const dwm_thumbnail = @import("dwmapi/dwm_thumbnail.zig");
pub const compositor = @import("compositor/compositor.zig");
pub const surface_mgr = @import("compositor/surface_mgr.zig");
pub const damage = @import("compositor/damage.zig");
pub const vsync = @import("compositor/vsync.zig");
pub const shaders = @import("shaders/shaders.zig");
pub const blur_shader = @import("shaders/blur_shader.zig");
pub const glass_shader = @import("shaders/glass_shader.zig");
pub const shadow_shader = @import("shaders/shadow_shader.zig");
pub const shader_manager = @import("shaders/shader_manager.zig");
pub const win32k = @import("win32k/win32k.zig");
pub const wmgr = @import("win32k/wmgr.zig");
pub const surface_redirect = @import("win32k/surface_redirect.zig");
pub const gre = @import("win32k/gre.zig");
pub const ddi = @import("win32k/ddi.zig");
pub const wddm = @import("wddm/wddm.zig");
pub const vidmm = @import("wddm/vidmm.zig");
pub const cmd_buffer = @import("wddm/cmd_buffer.zig");
pub const fence = @import("wddm/fence.zig");
pub const scheduler = @import("wddm/scheduler.zig");
pub const dwm_config = @import("config/dwm_config.zig");
pub const theme = @import("config/theme.zig");
pub const ui = @import("ui/root.zig");
pub const gpu_pipeline = @import("gpu_pipeline.zig");
pub const window_manager = @import("window_manager.zig");

// ============================================================================
// Module State
// ============================================================================

pub var g_dwm_initialized: bool = false;

pub const ZirconDWMVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,
    name: []const u8,

    pub fn getVersion() ZirconDWMVersion {
        return .{
            .major = 1,
            .minor = 0,
            .patch = 0,
            .name = "ZirconOS Desktop Window Manager",
        };
    }
};

// ============================================================================
// Initialize all subsystems
// ============================================================================

pub fn init() void {
    // Initialize configuration
    dwm_config.initDWMConfig();
    theme.initThemeManager();

    // Initialize D3D10
    d3d10.init();

    // Initialize DXGI
    dxgi.init();

    // Initialize compositor
    surface_mgr.initSurfaceManager();
    compositor.initCompositor(1920, 1080);
    vsync.initVSync();
    damage.initDamage();

    // Initialize DWM API
    dwm_composition.initComposition();

    // Initialize shaders
    shaders.initShaderLoader();
    shaders.loadDefaultShaders();

    // Initialize win32k subsystem
    win32k.initWin32k();
    wmgr.initWindowManager();
    surface_redirect.initRedirectPool();
    ddi.initDDI();

    // Initialize WDDM
    wddm.initWDDM();
    vidmm.initVidMM();
    cmd_buffer.initCommandBufferManager();
    fence.initFenceManager();
    scheduler.initGPUScheduler();

    g_dwm_initialized = true;
}

// ============================================================================
// Shutdown all subsystems
// ============================================================================

pub fn deinit() void {
    g_dwm_initialized = false;

    // Shutdown in reverse order
    scheduler.stopScheduler();
    scheduler.deinitGPUScheduler();
    fence.deinitFenceManager();
    cmd_buffer.deinitCommandBufferManager();
    vidmm.deinitVidMM();
    wddm.deinitWDDM();

    ddi.deinitDDI();
    surface_redirect.deinitRedirectPool();
    wmgr.deinitWindowManager();
    win32k.deinitWin32k();

    shaders.deinitShaderLoader();

    dwm_composition.deinitComposition();

    compositor.deinitCompositor();
    surface_mgr.deinitSurfaceManager();
    vsync.deinitVSync();

    dxgi.deinit();
    d3d10.deinit();
}

pub fn isInitialized() bool {
    return g_dwm_initialized;
}

// ============================================================================
// Version Information
// ============================================================================

pub fn getVersion() ZirconDWMVersion {
    return ZirconDWMVersion.getVersion();
}

// ============================================================================
// Status Check
// ============================================================================

pub const SubsystemStatus = struct {
    d3d10: bool,
    dxgi: bool,
    compositor: bool,
    dwm_api: bool,
    shaders: bool,
    win32k: bool,
    wddm: bool,
};

pub fn getSubsystemStatus() SubsystemStatus {
    return .{
        .d3d10 = d3d10.isInitialized(),
        .dxgi = dxgi.isInitialized(),
        .compositor = true,
        .dwm_api = dwm_composition.isCompositionSupported(),
        .shaders = shaders.g_shader_cache.initialized,
        .win32k = win32k.isWin32kInitialized(),
        .wddm = wddm.isWDDMInitialized(),
    };
}
