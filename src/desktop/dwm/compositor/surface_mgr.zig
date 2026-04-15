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

//! ZirconOS DWM Compositor - Surface Manager
//! Migrated and enhanced from aero/src/compositor.zig
//! Enhanced compositor engine with full alpha blending support, glass transparency,
//! blur effects, and per-surface opacity.
//! Reference: DWM composition; Porter-Duff compositing (public algorithm)

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

pub const MAX_SURFACES: usize = 256;
pub const MAX_DAMAGE_RECTS: usize = 16;
pub const INVALID_SURFACE: u32 = 0;

pub const CURSOR_SURFACE_Z: i32 = 0x7FFFFF00;
pub const DESKTOP_SURFACE_Z: i32 = -0x7FFFFF00;

// ============================================================================
// Surface Flags
// ============================================================================

pub const SurfaceFlags = struct {
    has_alpha: bool = true,
    needs_shadow: bool = false,
    is_visible: bool = true,
    is_opaque: bool = false,
    needs_blur: bool = false,
    is_glass: bool = false,
    is_cursor: bool = false,
    is_desktop: bool = false,
    is_taskbar: bool = false,
    is_menu: bool = false,
    is_tooltip: bool = false,
};

// ============================================================================
// Surface
// ============================================================================

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn intersect(self: Rect, other: Rect) Rect {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.x + self.w, other.x + other.w);
        const y2 = @min(self.y + self.h, other.y + other.h);
        if (x2 <= x1 or y2 <= y1) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
    }

    pub fn union_(self: Rect, other: Rect) Rect {
        if (self.w <= 0 or self.h <= 0) return other;
        if (other.w <= 0 or other.h <= 0) return self;
        const x1 = @min(self.x, other.x);
        const y1 = @min(self.y, other.y);
        const x2 = @max(self.x + self.w, other.x + other.w);
        const y2 = @max(self.y + self.h, other.y + other.h);
        return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

pub const Surface = struct {
    id: u32 = INVALID_SURFACE,
    width: u32 = 0,
    height: u32 = 0,
    flags: SurfaceFlags = .{},
    dirty: bool = true,
    damage_rects: [MAX_DAMAGE_RECTS]Rect = [_]Rect{.{ .x = 0, .y = 0, .w = 0, .h = 0 }} ** MAX_DAMAGE_RECTS,
    damage_count: usize = 0,
    z_order: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    alpha: u8 = 255,
    blur_radius: i32 = 0,
    tint_color: u32 = 0,
    tint_opacity: u8 = 0,
    extend_margins: MARGINS = .{
        .cxLeftWidth = 0,
        .cxRightWidth = 0,
        .cyTopHeight = 0,
        .cyBottomHeight = 0,
    },
    ref_count: u32 = 1,
    data: ?[]u8 = null,

    pub fn markDirty(self: *Surface, rect: Rect) void {
        if (self.damage_count < MAX_DAMAGE_RECTS) {
            self.damage_rects[self.damage_count] = rect;
            self.damage_count += 1;
        }
        self.dirty = true;
    }

    pub fn markFullDirty(self: *Surface) void {
        self.damage_count = 0;
        self.dirty = true;
    }

    pub fn clearDamage(self: *Surface) void {
        self.damage_count = 0;
        self.dirty = false;
    }

    pub fn getBounds(self: *const Surface) Rect {
        return .{
            .x = self.x,
            .y = self.y,
            .w = @intCast(self.width),
            .h = @intCast(self.height),
        };
    }

    pub fn getDamageBounds(self: *const Surface) Rect {
        if (self.damage_count == 0) return self.getBounds();
        var result = self.damage_rects[0];
        for (self.damage_rects[1..self.damage_count]) |r| {
            result = result.union_(r);
        }
        return result.offset(self.x, self.y);
    }

    pub fn containsPoint(self: *const Surface, px: i32, py: i32) bool {
        const b = self.getBounds();
        return b.contains(px, py);
    }
};

// ============================================================================
// MARGINS (DwmExtendFrameIntoClientArea)
// ============================================================================

pub const MARGINS = extern struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};

// ============================================================================
// Surface Manager
// ============================================================================

pub const SurfaceManager = struct {
    surfaces: [MAX_SURFACES]Surface = [_]Surface{.{}} ** MAX_SURFACES,
    surface_count: usize = 0,
    next_surface_id: u32 = 1,
    initialized: bool = false,

    pub fn init(self: *SurfaceManager) void {
        self.surface_count = 0;
        self.next_surface_id = 1;
        self.initialized = true;
    }

    pub fn createSurface(self: *SurfaceManager, width: u32, height: u32, flags: SurfaceFlags) u32 {
        if (self.surface_count >= MAX_SURFACES) return INVALID_SURFACE;

        const id = self.next_surface_id;
        self.next_surface_id += 1;

        var sfc = &self.surfaces[self.surface_count];
        sfc.* = .{};
        sfc.id = id;
        sfc.width = width;
        sfc.height = height;
        sfc.flags = flags;
        sfc.dirty = true;

        // Allocate surface data
        const pixel_size: usize = 4; // BGRA
        const row_pitch = width * @as(u32, @intCast(pixel_size));
        const size = row_pitch * height;
        sfc.data = std.heap.page_allocator.alloc(u8, size) catch null;

        self.surface_count += 1;
        return id;
    }

    pub fn destroySurface(self: *SurfaceManager, id: u32) bool {
        var i: usize = 0;
        while (i < self.surface_count) {
            if (self.surfaces[i].id == id) {
                // Free surface data
                if (self.surfaces[i].data) |d| {
                    std.heap.page_allocator.free(d);
                }

                // Shift remaining surfaces
                var j = i;
                while (j + 1 < self.surface_count) : (j += 1) {
                    self.surfaces[j] = self.surfaces[j + 1];
                }
                self.surfaces[self.surface_count - 1] = .{};
                self.surface_count -= 1;
                return true;
            }
            i += 1;
        }
        return false;
    }

    pub fn getSurface(self: *SurfaceManager, id: u32) ?*Surface {
        for (self.surfaces[0..self.surface_count]) |*sfc| {
            if (sfc.id == id) return sfc;
        }
        return null;
    }

    pub fn getSurfaceCount(self: *SurfaceManager) usize {
        return self.surface_count;
    }

    pub fn hitTest(self: *SurfaceManager, px: i32, py: i32) ?u32 {
        // Test from top to bottom (highest z-order first)
        var i: usize = self.surface_count;
        while (i > 0) {
            i -= 1;
            const sfc = &self.surfaces[i];
            if (!sfc.flags.is_visible or sfc.flags.is_cursor or sfc.flags.is_desktop) continue;
            if (sfc.containsPoint(px, py)) return sfc.id;
        }
        return null;
    }

    pub fn sortByZOrder(self: *SurfaceManager) void {
        if (self.surface_count <= 1) return;
        var i: usize = 1;
        while (i < self.surface_count) : (i += 1) {
            const key = self.surfaces[i];
            var j: usize = i;
            while (j > 0 and self.surfaces[j - 1].z_order > key.z_order) {
                self.surfaces[j] = self.surfaces[j - 1];
                j -= 1;
            }
            self.surfaces[j] = key;
        }
    }

    pub fn markAllDirty(self: *SurfaceManager) void {
        for (self.surfaces[0..self.surface_count]) |*sfc| {
            sfc.markFullDirty();
        }
    }
};

// ============================================================================
// Global Surface Manager Instance
// ============================================================================

pub var g_surface_manager: SurfaceManager = .{};

// ============================================================================
// Helper Functions
// ============================================================================

pub fn initSurfaceManager() void {
    g_surface_manager.init();
}

pub fn createSurface(width: u32, height: u32, flags: SurfaceFlags) u32 {
    return g_surface_manager.createSurface(width, height, flags);
}

pub fn destroySurface(id: u32) bool {
    return g_surface_manager.destroySurface(id);
}

pub fn getSurface(id: u32) ?*Surface {
    return g_surface_manager.getSurface(id);
}

pub fn getSurfaceCount() usize {
    return g_surface_manager.getSurfaceCount();
}

pub fn sortSurfacesByZOrder() void {
    g_surface_manager.sortByZOrder();
}

pub fn hitTestTopMost(px: i32, py: i32) ?u32 {
    return g_surface_manager.hitTest(px, py);
}

// ============================================================================
// Additional Surface Management Functions
// ============================================================================

pub fn moveSurface(id: u32, x: i32, y: i32) void {
    if (getSurface(id)) |sfc| {
        sfc.x = x;
        sfc.y = y;
        sfc.markFullDirty();
    }
}

pub fn resizeSurface(id: u32, width: u32, height: u32) void {
    if (getSurface(id)) |sfc| {
        sfc.width = width;
        sfc.height = height;
        sfc.markFullDirty();
    }
}

pub fn setSurfaceZOrder(id: u32, z: i32) void {
    if (getSurface(id)) |sfc| {
        sfc.z_order = z;
    }
}

pub fn setSurfaceAlpha(id: u32, alpha: u8) void {
    if (getSurface(id)) |sfc| {
        sfc.alpha = alpha;
        sfc.markFullDirty();
    }
}

pub fn setSurfaceVisible(id: u32, visible: bool) void {
    if (getSurface(id)) |sfc| {
        sfc.flags.is_visible = visible;
    }
}

pub fn setSurfaceGlass(id: u32, glass: bool) void {
    if (getSurface(id)) |sfc| {
        sfc.flags.is_glass = glass;
        if (glass) {
            sfc.flags.needs_blur = true;
            sfc.blur_radius = 8;
        }
        sfc.markFullDirty();
    }
}

pub fn setSurfaceExtendMargins(id: u32, m: MARGINS) void {
    if (getSurface(id)) |sfc| {
        sfc.extend_margins = m;
        sfc.markFullDirty();
    }
}

pub fn setSurfaceBlurBehind(id: u32, enable: bool) void {
    if (getSurface(id)) |sfc| {
        sfc.flags.needs_blur = enable;
        if (enable) {
            sfc.blur_radius = 8;
        } else {
            sfc.blur_radius = 0;
        }
        sfc.markFullDirty();
    }
}

pub fn getSurfaceBounds(id: u32) ?Rect {
    if (getSurface(id)) |sfc| {
        return sfc.getBounds();
    }
    return null;
}

pub fn getVisibleSurfaceCount() usize {
    var count: usize = 0;
    for (0..g_surface_manager.surface_count) |i| {
        if (g_surface_manager.surfaces[i].flags.is_visible) {
            count += 1;
        }
    }
    return count;
}

// ============================================================================
// Surface Texture Binding (D3D10 Integration)
// ============================================================================

pub const SurfaceTextureBinding = struct {
    texture_id: u32,
    rtv_id: u32,
    bound: bool,
};

var g_surface_bindings: [MAX_SURFACES]SurfaceTextureBinding = [_]SurfaceTextureBinding{.{.texture_id = 0, .rtv_id = 0, .bound = false}} ** MAX_SURFACES;

pub fn bindSurfaceTexture(surface_id: u32, texture_id: u32, rtv_id: u32) void {
    if (surface_id == INVALID_SURFACE or surface_id > MAX_SURFACES) return;
    g_surface_bindings[surface_id] = .{
        .texture_id = texture_id,
        .rtv_id = rtv_id,
        .bound = true,
    };
}

pub fn unbindSurfaceTexture(surface_id: u32) void {
    if (surface_id == INVALID_SURFACE or surface_id > MAX_SURFACES) return;
    g_surface_bindings[surface_id] = .{
        .texture_id = 0,
        .rtv_id = 0,
        .bound = false,
    };
}

pub fn getSurfaceBinding(surface_id: u32) ?SurfaceTextureBinding {
    if (surface_id == INVALID_SURFACE or surface_id > MAX_SURFACES) return null;
    return g_surface_bindings[surface_id];
}

pub fn isSurfaceBound(surface_id: u32) bool {
    if (surface_id == INVALID_SURFACE or surface_id > MAX_SURFACES) return false;
    return g_surface_bindings[surface_id].bound;
}
