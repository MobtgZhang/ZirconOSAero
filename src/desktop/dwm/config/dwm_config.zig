// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Configuration

const std = @import("std");

// ============================================================================
// DWM Configuration
// ============================================================================

pub const DWMConfiguration = struct {
    composition_enabled: bool = true,
    animation_enabled: bool = true,
    flip3d_enabled: bool = true,
    peek_enabled: bool = true,
    shadow_enabled: bool = true,
    vsync_enabled: bool = true,
    smooth_cursor: bool = true,
    cursor_lerp_factor: i32 = 10,
    max_fps: u32 = 60,
    blur_budget_per_frame: u32 = 500000,
    max_blur_rects_per_frame: u32 = 16,
    surface_pool_size: usize = 256,
};

// ============================================================================
// Glass Configuration
// ============================================================================

pub const GlassConfiguration = struct {
    enabled: bool = true,
    opacity: u8 = 200,
    blur_radius: u8 = 8,
    blur_passes: u8 = 3,
    saturation: u8 = 180,
    tint_color: u32 = 0x996666,
    tint_opacity: u8 = 200,
    specular_intensity: u8 = 40,
    taskbar_tint_opacity: u8 = 180,
};

// ============================================================================
// Shadow Configuration
// ============================================================================

pub const ShadowConfiguration = struct {
    enabled: bool = true,
    size: u8 = 8,
    layers: u8 = 4,
    tint_r: u8 = 0x30,
    tint_g: u8 = 0x48,
    tint_b: u8 = 0x60,
};

// ============================================================================
// Global Configuration
// ============================================================================

pub var g_dwm_config: DWMConfiguration = .{};
pub var g_glass_config: GlassConfiguration = .{};
pub var g_shadow_config: ShadowConfiguration = .{};

// ============================================================================
// Configuration API
// ============================================================================

pub fn initDWMConfig() void {
    g_dwm_config = .{
        .composition_enabled = true,
        .animation_enabled = true,
        .flip3d_enabled = true,
        .peek_enabled = true,
        .shadow_enabled = true,
        .vsync_enabled = true,
        .smooth_cursor = true,
        .cursor_lerp_factor = 10,
        .max_fps = 60,
        .blur_budget_per_frame = 500000,
        .max_blur_rects_per_frame = 16,
        .surface_pool_size = 256,
    };

    g_glass_config = .{
        .enabled = true,
        .opacity = 200,
        .blur_radius = 8,
        .blur_passes = 3,
        .saturation = 180,
        .tint_color = 0x996666,
        .tint_opacity = 200,
        .specular_intensity = 40,
        .taskbar_tint_opacity = 180,
    };

    g_shadow_config = .{
        .enabled = true,
        .size = 8,
        .layers = 4,
        .tint_r = 0x30,
        .tint_g = 0x48,
        .tint_b = 0x60,
    };
}

pub fn getDWMConfig() *const DWMConfiguration {
    return &g_dwm_config;
}

pub fn getGlassConfig() *const GlassConfiguration {
    return &g_glass_config;
}

pub fn getShadowConfig() *const ShadowConfiguration {
    return &g_shadow_config;
}

pub fn setCompositionEnabled(enabled: bool) void {
    g_dwm_config.composition_enabled = enabled;
}

pub fn setAnimationEnabled(enabled: bool) void {
    g_dwm_config.animation_enabled = enabled;
}

pub fn setFlip3DEnabled(enabled: bool) void {
    g_dwm_config.flip3d_enabled = enabled;
}

pub fn setVSyncEnabled(enabled: bool) void {
    g_dwm_config.vsync_enabled = enabled;
}

pub fn setMaxFPS(fps: u32) void {
    g_dwm_config.max_fps = fps;
}

pub fn setGlassEnabled(enabled: bool) void {
    g_glass_config.enabled = enabled;
}

pub fn setGlassTintColor(color: u32) void {
    g_glass_config.tint_color = color;
}

pub fn setGlassOpacity(opacity: u8) void {
    g_glass_config.opacity = opacity;
}

pub fn setBlurRadius(radius: u8) void {
    g_glass_config.blur_radius = radius;
}

pub fn setShadowEnabled(enabled: bool) void {
    g_shadow_config.enabled = enabled;
}
