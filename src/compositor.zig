//! Compositor - ZirconOS Aero Desktop Window Manager (DWM)
//! Enhanced compositing engine with full alpha blending support,
//! glass transparency, blur effects, and per-surface opacity.
//! Each window renders to its own surface; the compositor merges
//! them in Z-order with DWM-style glass composition, damage
//! tracking, and soft shadow effects, then outputs to the
//! framebuffer in a single tear-free flip.
//! Reference: DWM composition; Porter-Duff compositing (public algorithm)

const theme = @import("theme.zig");
const renderer = @import("renderer.zig");

pub const Rect = renderer.Rect;
pub const COLORREF = theme.COLORREF;

pub const MAX_SURFACES: usize = 64;
pub const MAX_DAMAGE_RECTS: usize = 16;
pub const INVALID_SURFACE: u32 = 0;

pub const SurfaceFlags = struct {
    has_alpha: bool = true,
    needs_shadow: bool = false,
    is_visible: bool = true,
    is_opaque: bool = false,
    needs_blur: bool = false,
    is_glass: bool = false,
};

pub const Surface = struct {
    id: u32 = INVALID_SURFACE,
    width: u32 = 0,
    height: u32 = 0,
    flags: SurfaceFlags = .{},
    dirty: bool = true,
    damage_rects: [MAX_DAMAGE_RECTS]Rect = [_]Rect{.{}} ** MAX_DAMAGE_RECTS,
    damage_count: usize = 0,
    z_order: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    alpha: u8 = 255,
    blur_radius: i32 = 0,

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
};

pub const CompositorStats = struct {
    total_frames: u64 = 0,
    dirty_frames: u64 = 0,
    surfaces_composited: u64 = 0,
    full_redraws: u64 = 0,
    partial_redraws: u64 = 0,
    glass_surfaces: u64 = 0,
};

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

var surfaces: [MAX_SURFACES]Surface = [_]Surface{.{}} ** MAX_SURFACES;
var surface_count: usize = 0;
var next_surface_id: u32 = 1;

var screen_width: u32 = 0;
var screen_height: u32 = 0;
var compositor_dirty: bool = true;
var stats: CompositorStats = .{};
var compositor_initialized: bool = false;
var dwm_composition_enabled: bool = true;

pub fn init(width: u32, height: u32) void {
    screen_width = width;
    screen_height = height;
    surface_count = 0;
    next_surface_id = 1;
    compositor_dirty = true;
    stats = .{};
    dwm_composition_enabled = theme.isGlassEnabled();
    compositor_initialized = true;
}

pub fn createSurface(width: u32, height: u32, flags: SurfaceFlags) u32 {
    if (surface_count >= MAX_SURFACES) return INVALID_SURFACE;

    const id = next_surface_id;
    next_surface_id += 1;

    var sfc = &surfaces[surface_count];
    sfc.* = .{};
    sfc.id = id;
    sfc.width = width;
    sfc.height = height;
    sfc.flags = flags;
    sfc.dirty = true;

    if (flags.is_glass and dwm_composition_enabled) {
        sfc.alpha = theme.getGlassAlpha();
        sfc.blur_radius = theme.getBlurRadius();
    }

    surface_count += 1;
    compositor_dirty = true;
    return id;
}

pub fn destroySurface(id: u32) bool {
    var i: usize = 0;
    while (i < surface_count) {
        if (surfaces[i].id == id) {
            var j = i;
            while (j + 1 < surface_count) : (j += 1) {
                surfaces[j] = surfaces[j + 1];
            }
            surfaces[surface_count - 1] = .{};
            surface_count -= 1;
            compositor_dirty = true;
            return true;
        }
        i += 1;
    }
    return false;
}

pub fn getSurface(id: u32) ?*Surface {
    for (surfaces[0..surface_count]) |*sfc| {
        if (sfc.id == id) return sfc;
    }
    return null;
}

pub fn moveSurface(id: u32, x: i32, y: i32) void {
    if (getSurface(id)) |sfc| {
        sfc.x = x;
        sfc.y = y;
        sfc.markFullDirty();
        compositor_dirty = true;
    }
}

pub fn resizeSurface(id: u32, width: u32, height: u32) void {
    if (getSurface(id)) |sfc| {
        sfc.width = width;
        sfc.height = height;
        sfc.markFullDirty();
        compositor_dirty = true;
    }
}

pub fn setSurfaceZOrder(id: u32, z: i32) void {
    if (getSurface(id)) |sfc| {
        sfc.z_order = z;
        compositor_dirty = true;
    }
}

pub fn setSurfaceAlpha(id: u32, alpha: u8) void {
    if (getSurface(id)) |sfc| {
        sfc.alpha = alpha;
        sfc.markFullDirty();
        compositor_dirty = true;
    }
}

pub fn setSurfaceVisible(id: u32, visible: bool) void {
    if (getSurface(id)) |sfc| {
        sfc.flags.is_visible = visible;
        compositor_dirty = true;
    }
}

pub fn setSurfaceGlass(id: u32, glass: bool) void {
    if (getSurface(id)) |sfc| {
        sfc.flags.is_glass = glass;
        if (glass and dwm_composition_enabled) {
            sfc.alpha = theme.getGlassAlpha();
            sfc.blur_radius = theme.getBlurRadius();
            sfc.flags.needs_blur = true;
        } else {
            sfc.alpha = 255;
            sfc.blur_radius = 0;
            sfc.flags.needs_blur = false;
        }
        sfc.markFullDirty();
        compositor_dirty = true;
    }
}

pub fn compose() void {
    if (!compositor_initialized) return;

    stats.total_frames += 1;

    if (!needsRedraw()) return;
    stats.dirty_frames += 1;

    sortSurfacesByZOrder();

    const screen_rect = Rect{
        .x = 0,
        .y = 0,
        .w = @intCast(screen_width),
        .h = @intCast(screen_height),
    };

    var has_partial = false;
    for (surfaces[0..surface_count]) |*sfc| {
        if (sfc.dirty and sfc.damage_count > 0) {
            has_partial = true;
            break;
        }
    }

    if (has_partial) {
        stats.partial_redraws += 1;
        composePartial();
    } else {
        stats.full_redraws += 1;
        composeFull(screen_rect);
    }

    for (surfaces[0..surface_count]) |*sfc| {
        sfc.clearDamage();
    }
    compositor_dirty = false;

    renderer.flushRender();
}

fn composeFull(screen_rect: Rect) void {
    renderer.fillRect(screen_rect, theme.getColors().desktop_background);

    for (surfaces[0..surface_count]) |*sfc| {
        if (!sfc.flags.is_visible) continue;
        composeSurface(sfc);
        stats.surfaces_composited += 1;
    }
}

fn composePartial() void {
    for (surfaces[0..surface_count]) |*sfc| {
        if (!sfc.flags.is_visible) continue;
        if (!sfc.dirty) continue;

        if (sfc.damage_count > 0) {
            const damage = sfc.getDamageBounds();
            renderer.setClip(damage);
        }

        composeSurface(sfc);
        stats.surfaces_composited += 1;

        if (sfc.damage_count > 0) {
            renderer.clearClip();
        }
    }
}

fn composeSurface(sfc: *const Surface) void {
    const bounds = sfc.getBounds();

    if (sfc.flags.needs_shadow) {
        renderer.drawShadow(bounds, theme.WINDOW_SHADOW_SIZE);
    }

    if (sfc.flags.needs_blur and dwm_composition_enabled) {
        renderer.drawBlur(bounds, sfc.blur_radius);
        stats.glass_surfaces += 1;
    }

    renderer.blitSurface(sfc.id, bounds, sfc.alpha);
}

fn needsRedraw() bool {
    if (compositor_dirty) return true;
    for (surfaces[0..surface_count]) |*sfc| {
        if (sfc.dirty) return true;
    }
    return false;
}

fn sortSurfacesByZOrder() void {
    var i: usize = 0;
    while (i + 1 < surface_count) : (i += 1) {
        var j: usize = 0;
        while (j + 1 < surface_count - i) : (j += 1) {
            if (surfaces[j].z_order > surfaces[j + 1].z_order) {
                const tmp = surfaces[j];
                surfaces[j] = surfaces[j + 1];
                surfaces[j + 1] = tmp;
            }
        }
    }
}

pub fn getStats() CompositorStats {
    return stats;
}

pub fn getSurfaceCount() usize {
    return surface_count;
}

pub fn getScreenSize() struct { w: u32, h: u32 } {
    return .{ .w = screen_width, .h = screen_height };
}

pub fn setScreenSize(width: u32, height: u32) void {
    screen_width = width;
    screen_height = height;
    compositor_dirty = true;
}

pub fn markAllDirty() void {
    for (surfaces[0..surface_count]) |*sfc| {
        sfc.markFullDirty();
    }
    compositor_dirty = true;
}

pub fn isDwmEnabled() bool {
    return dwm_composition_enabled;
}

pub fn setDwmEnabled(enabled: bool) void {
    dwm_composition_enabled = enabled;
    markAllDirty();
}
