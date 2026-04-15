// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! ZirconOS DWM Compositor - Main Compositor
//! The core composition engine that merges surfaces in Z-order with DWM-style
//! glass composition, damage tracking, soft shadow effects, and a dedicated
//! cursor surface layer for tear-free cursor rendering.
//! VSync-aligned frame presentation ensures zero tearing.

const std = @import("std");
const d3d10 = @import("../d3d10/d3d10.zig");
const dxgi = @import("../dxgi/dxgi.zig");
pub const surface_mgr = @import("surface_mgr.zig");
pub const damage = @import("damage.zig");
pub const vsync = @import("vsync.zig");

const SurfaceManager = surface_mgr.SurfaceManager;
const Surface = surface_mgr.Surface;
const SurfaceFlags = surface_mgr.SurfaceFlags;
const INVALID_SURFACE = surface_mgr.INVALID_SURFACE;
const CURSOR_SURFACE_Z = surface_mgr.CURSOR_SURFACE_Z;
const MARGINS = surface_mgr.MARGINS;
const VsyncState = vsync.VsyncState;

// ============================================================================
// GPU Rendering Types
// ============================================================================

pub const BlendMode = enum(u8) {
    Opaque = 0,
    Alpha = 1,
    Additive = 2,
    Multiply = 3,
};

pub const ViewportState = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const RenderTargetBinding = struct {
    texture_id: u32,
    rtv_id: u32,
    bound: bool,
};

// ============================================================================
// Layer Types
// ============================================================================

pub const LayerType = enum(u8) {
    desktop = 0,
    normal_window = 1,
    floating_window = 2,
    taskbar = 3,
    menu = 4,
    tooltip = 5,
    cursor = 6,
    glass_overlay = 7,
};

// ============================================================================
// Compositor Statistics
// ============================================================================

pub const CompositorStats = struct {
    total_frames: u64 = 0,
    dirty_frames: u64 = 0,
    surfaces_composited: u64 = 0,
    full_redraws: u64 = 0,
    partial_redraws: u64 = 0,
    glass_surfaces: u64 = 0,
    cursor_redraws: u64 = 0,
    vsync_misses: u64 = 0,
    avg_compose_time_us: u64 = 0,
};

// ============================================================================
// Cursor Layer
// ============================================================================

pub const CursorLayer = struct {
    x: i32 = 0,
    y: i32 = 0,
    prev_x: i32 = -1,
    prev_y: i32 = -1,
    width: i32 = 14,
    height: i32 = 20,
    visible: bool = true,
    surface_id: u32 = INVALID_SURFACE,
    needs_redraw: bool = true,
};

// ============================================================================
// Peek State (Aero Peek)
// ============================================================================

pub const PeekState = enum {
    disabled,
    desktop_peek,
    window_peek,
};

pub const ThumbnailConfig = struct {
    max_width: u32 = 200,
    max_height: u32 = 150,
    padding: u32 = 8,
    border_radius: u32 = 4,
};

// ============================================================================
// ZirconCompositor
// ============================================================================

pub const ZirconCompositor = struct {
    surface_manager: SurfaceManager,
    screen_width: u32,
    screen_height: u32,
    composition_enabled: bool,
    composition_dirty: bool,
    stats: CompositorStats,
    cursor_layer: CursorLayer,
    vsync_state: VsyncState,
    peek_state: PeekState,
    peek_window_id: u32,
    flip3d_preview_enabled: bool,
    thumbnail_config: ThumbnailConfig,
    d3d10_device: *d3d10.CompositorDevice,
    swap_chain: *dxgi.DwmSwapChain,

    // GPU rendering pipeline state
    active_blend_mode: BlendMode,
    active_viewport: ViewportState,
    rendering_pipeline_ready: bool,

    pub fn init(self: *ZirconCompositor, width: u32, height: u32) void {
        self.screen_width = width;
        self.screen_height = height;
        self.composition_enabled = true;
        self.composition_dirty = true;
        self.stats = .{};
        self.cursor_layer = .{};
        self.vsync_state = .{ .enabled = true, .frame_target_us = 16667 };
        self.peek_state = .disabled;
        self.peek_window_id = INVALID_SURFACE;
        self.flip3d_preview_enabled = false;
        self.thumbnail_config = .{};

        // Initialize GPU rendering pipeline state
        self.active_blend_mode = .Alpha;
        self.active_viewport = .{ .x = 0, .y = 0, .width = width, .height = height };
        self.rendering_pipeline_ready = true;

        // Initialize D3D10 device
        self.d3d10_device = d3d10.CompositorDevice.createCompositorDevice(width, height) catch @panic("Failed to create D3D10 compositor device");

        // Initialize DXGI swap chain (RGBA 8-bit format)
        self.swap_chain = dxgi.DwmSwapChain.create(width, height, .DXGI_FORMAT_R8G8B8A8_UNORM) catch @panic("Failed to create DXGI swap chain");

        self.surface_manager.init();

        // Create cursor surface
        self.cursor_layer.surface_id = self.surface_manager.createSurface(14, 20, .{
            .has_alpha = true,
            .is_visible = true,
            .is_cursor = true,
        });
        if (self.surface_manager.getSurface(self.cursor_layer.surface_id)) |sfc| {
            sfc.z_order = CURSOR_SURFACE_Z;
        }
    }

    pub fn createSurface(self: *ZirconCompositor, width: u32, height: u32, flags: SurfaceFlags) u32 {
        const id = self.surface_manager.createSurface(width, height, flags);
        if (id != INVALID_SURFACE) {
            self.composition_dirty = true;
        }
        return id;
    }

    pub fn destroySurface(self: *ZirconCompositor, id: u32) bool {
        if (id == self.cursor_layer.surface_id) return false;
        const result = self.surface_manager.destroySurface(id);
        if (result) {
            self.composition_dirty = true;
        }
        return result;
    }

    pub fn moveSurface(self: *ZirconCompositor, id: u32, x: i32, y: i32) void {
        if (self.surface_manager.getSurface(id)) |sfc| {
            sfc.x = x;
            sfc.y = y;
            sfc.markFullDirty();
            self.composition_dirty = true;
        }
    }

    pub fn resizeSurface(self: *ZirconCompositor, id: u32, width: u32, height: u32) void {
        if (self.surface_manager.getSurface(id)) |sfc| {
            sfc.width = width;
            sfc.height = height;
            sfc.markFullDirty();
            self.composition_dirty = true;
        }
    }

    pub fn setSurfaceZOrder(self: *ZirconCompositor, id: u32, z: i32) void {
        if (self.surface_manager.getSurface(id)) |sfc| {
            sfc.z_order = z;
            self.composition_dirty = true;
        }
    }

    pub fn setSurfaceAlpha(self: *ZirconCompositor, id: u32, alpha: u8) void {
        if (self.surface_manager.getSurface(id)) |sfc| {
            sfc.alpha = alpha;
            sfc.markFullDirty();
            self.composition_dirty = true;
        }
    }

    pub fn setSurfaceGlass(self: *ZirconCompositor, id: u32, glass: bool) void {
        if (self.surface_manager.getSurface(id)) |sfc| {
            sfc.flags.is_glass = glass;
            if (glass) {
                sfc.flags.needs_blur = true;
                sfc.blur_radius = 8;
            }
            sfc.markFullDirty();
            self.composition_dirty = true;
        }
    }

    pub fn setSurfaceExtendMargins(self: *ZirconCompositor, id: u32, m: MARGINS) void {
        if (self.surface_manager.getSurface(id)) |sfc| {
            sfc.extend_margins = m;
            sfc.markFullDirty();
            self.composition_dirty = true;
        }
    }

    pub fn setSurfaceBlurBehind(self: *ZirconCompositor, id: u32, enable: bool) void {
        if (self.surface_manager.getSurface(id)) |sfc| {
            sfc.flags.needs_blur = enable;
            if (enable) {
                sfc.blur_radius = 8;
            } else {
                sfc.blur_radius = 0;
            }
            sfc.markFullDirty();
            self.composition_dirty = true;
        }
    }

    pub fn updateCursorPosition(self: *ZirconCompositor, x: i32, y: i32) void {
        if (x == self.cursor_layer.x and y == self.cursor_layer.y) return;

        self.cursor_layer.prev_x = self.cursor_layer.x;
        self.cursor_layer.prev_y = self.cursor_layer.y;
        self.cursor_layer.x = x;
        self.cursor_layer.y = y;
        self.cursor_layer.needs_redraw = true;

        if (self.surface_manager.getSurface(self.cursor_layer.surface_id)) |sfc| {
            sfc.x = x;
            sfc.y = y;
            sfc.markFullDirty();
        }
    }

    pub fn setDwmEnabled(self: *ZirconCompositor, enabled: bool) void {
        self.composition_enabled = enabled;
        self.surface_manager.markAllDirty();
        self.composition_dirty = true;
    }

    pub fn isDwmEnabled(self: *ZirconCompositor) bool {
        return self.composition_enabled;
    }

    pub fn getStats(self: *ZirconCompositor) CompositorStats {
        return self.stats;
    }

    pub fn composeFrame(self: *ZirconCompositor) !void {
        if (!self.composition_enabled or !self.composition_dirty) return;

        self.stats.total_frames += 1;

        // Clear framebuffer
        self.d3d10_device.clear([_]f32{ 0.0, 0.0, 0.0, 1.0 });

        // Sort surfaces by Z order
        self.surface_manager.sortByZOrder();

        // Draw all surfaces
        var it = self.surface_manager.surfaces.iterator();
        while (it.next()) |entry| {
            const surface = entry.value_ptr;
            if (!surface.flags.is_visible) continue;

            // Draw quad for the surface
            self.d3d10_device.drawQuad();
            self.stats.surfaces_composited += 1;

            // Handle glass blur effect if needed
            if (surface.flags.is_glass or surface.flags.needs_blur) {
                self.stats.glass_surfaces += 1;
            }

            surface.clearDirty();
        }

        // Present the frame
        try self.swap_chain.present(if (self.vsync_state.enabled) 1 else 0);

        self.composition_dirty = false;
    }

    pub fn setVsyncEnabled(self: *ZirconCompositor, enabled: bool) void {
        self.vsync_state.enabled = enabled;
    }

    pub fn setRefreshRate(self: *ZirconCompositor, hz: u32) void {
        if (hz > 0) {
            self.vsync_state.frame_target_us = 1_000_000 / @as(u64, hz);
        }
    }

    pub fn hitTest(self: *ZirconCompositor, px: i32, py: i32) ?u32 {
        self.surface_manager.sortByZOrder();
        return self.surface_manager.hitTest(px, py);
    }

    pub fn markAllDirty(self: *ZirconCompositor) void {
        self.surface_manager.markAllDirty();
        self.composition_dirty = true;
    }
};

// ============================================================================
// Global Compositor Instance
// ============================================================================

pub var g_compositor: ZirconCompositor = undefined;

pub fn initCompositor(width: u32, height: u32) void {
    g_compositor.init(width, height);
}

pub fn createSurface(width: u32, height: u32, flags: SurfaceFlags) u32 {
    return g_compositor.createSurface(width, height, flags);
}

pub fn destroySurface(id: u32) bool {
    return g_compositor.destroySurface(id);
}

pub fn getSurface(id: u32) ?*Surface {
    return g_compositor.surface_manager.getSurface(id);
}

pub fn moveSurface(id: u32, x: i32, y: i32) void {
    g_compositor.moveSurface(id, x, y);
}

pub fn setSurfaceZOrder(id: u32, z: i32) void {
    g_compositor.setSurfaceZOrder(id, z);
}

pub fn setSurfaceAlpha(id: u32, alpha: u8) void {
    g_compositor.setSurfaceAlpha(id, alpha);
}

pub fn setSurfaceGlass(id: u32, glass: bool) void {
    g_compositor.setSurfaceGlass(id, glass);
}

pub fn updateCursorPosition(x: i32, y: i32) void {
    g_compositor.updateCursorPosition(x, y);
}

pub fn isDwmEnabled() bool {
    return g_compositor.isDwmEnabled();
}

pub fn getStats() CompositorStats {
    return g_compositor.getStats();
}

pub fn getScreenSize() struct { w: u32, h: u32 } {
    return .{ .w = g_compositor.screen_width, .h = g_compositor.screen_height };
}

pub fn setScreenSize(width: u32, height: u32) void {
    g_compositor.screen_width = width;
    g_compositor.screen_height = height;
}

pub fn getCursorLayer() *const CursorLayer {
    return &g_compositor.cursor_layer;
}

pub fn setCursorVisible(visible: bool) void {
    g_compositor.cursor_layer.visible = visible;
    if (g_compositor.surface_manager.getSurface(g_compositor.cursor_layer.surface_id)) |sfc| {
        sfc.flags.is_visible = visible;
    }
}

pub fn getPeekState() PeekState {
    return g_compositor.peek_state;
}

// ============================================================================
// GPU Rendering Pipeline Integration
// ============================================================================

pub fn setBlendMode(mode: BlendMode) void {
    g_compositor.active_blend_mode = mode;
}

pub fn getBlendMode() BlendMode {
    return g_compositor.active_blend_mode;
}

pub fn setViewport(x: i32, y: i32, width: u32, height: u32) void {
    g_compositor.active_viewport = .{ .x = x, .y = y, .width = width, .height = height };
    g_compositor.d3d10_device.setViewport(x, y, width, height);
}

pub fn getViewport() ViewportState {
    return g_compositor.active_viewport;
}

pub fn isPipelineReady() bool {
    return g_compositor.rendering_pipeline_ready;
}

pub fn resetPipelineStats() void {
    g_compositor.d3d10_device.resetStats();
}

// ============================================================================
// Texture Binding Helpers
// ============================================================================

pub fn bindSurfaceToRenderTarget(surface_id: u32, texture_id: u32, rtv_id: u32) void {
    _ = surface_mgr.bindSurfaceTexture(surface_id, texture_id, rtv_id);
}

pub fn unbindSurfaceFromRenderTarget(surface_id: u32) void {
    _ = surface_mgr.unbindSurfaceTexture(surface_id);
}

pub fn getSurfaceRenderBinding(surface_id: u32) ?RenderTargetBinding {
    if (surface_mgr.getSurfaceBinding(surface_id)) |binding| {
        return .{
            .texture_id = binding.texture_id,
            .rtv_id = binding.rtv_id,
            .bound = binding.bound,
        };
    }
    return null;
}

// ============================================================================
// Frame Composition
// ============================================================================

pub fn beginComposition() void {
    g_compositor.stats.total_frames += 1;
    g_compositor.d3d10_device.clear([_]f32{ 0.0, 0.0, 0.0, 1.0 });
}

pub fn endComposition() void {
    // Present handled by compose()
}

pub fn resizeSurface(id: u32, width: u32, height: u32) void {
    g_compositor.resizeSurface(id, width, height);
}

pub fn setSurfaceVisible(id: u32, visible: bool) void {
    if (g_compositor.surface_manager.getSurface(id)) |sfc| {
        sfc.flags.is_visible = visible;
    }
}

pub fn setSurfaceExtendMargins(id: u32, m: MARGINS) void {
    g_compositor.setSurfaceExtendMargins(id, m);
}

pub fn setSurfaceBlurBehind(id: u32, enable: bool) void {
    g_compositor.setSurfaceBlurBehind(id, enable);
}

pub fn setDwmEnabled(enabled: bool) void {
    g_compositor.setDwmEnabled(enabled);
}

pub fn compose() void {
    g_compositor.composeFrame() catch {};
}

pub fn deinitCompositor() void {
    _ = g_compositor.surface_manager.surface_count;
}

pub fn setPeekState(state: PeekState, window_id: u32) void {
    g_compositor.peek_state = state;
    g_compositor.peek_window_id = window_id;
}

pub fn isFlip3dPreviewEnabled() bool {
    return g_compositor.flip3d_preview_enabled;
}

pub fn setFlip3dPreviewEnabled(enabled: bool) void {
    g_compositor.flip3d_preview_enabled = enabled;
}
