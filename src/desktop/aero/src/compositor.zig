//! Compositor - ZirconOS Aero Desktop Window Manager (DWM)
//! 表面标志与内核 `dwm_compositor` 的语义映射见 `src/config/dwm_surface_spec.zig`、`docs/cn/DesktopManagerSpec.md`。
//! Enhanced compositing engine with full alpha blending support,
//! glass transparency, blur effects, and per-surface opacity.
//! Each window renders to its own surface; the compositor merges
//! them in Z-order with DWM-style glass composition, damage
//! tracking, soft shadow effects, and a dedicated cursor surface
//! layer for tear-free, silky-smooth cursor rendering.
//! VSync-aligned frame presentation ensures zero tearing.
//! Reference: DWM composition; Porter-Duff compositing (public algorithm)

const std = @import("std");
const theme = @import("theme.zig");
const renderer = @import("renderer.zig");

pub const Rect = renderer.Rect;
pub const COLORREF = theme.COLORREF;

pub const MAX_SURFACES: usize = 64;
pub const MAX_DAMAGE_RECTS: usize = 16;
pub const INVALID_SURFACE: u32 = 0;

pub const CURSOR_SURFACE_Z: i32 = 0x7FFFFF00;
pub const DESKTOP_SURFACE_Z: i32 = -0x7FFFFF00;

pub const SurfaceFlags = struct {
    has_alpha: bool = true,
    needs_shadow: bool = false,
    is_visible: bool = true,
    is_opaque: bool = false,
    needs_blur: bool = false,
    is_glass: bool = false,
    is_cursor: bool = false,
    is_desktop: bool = false,
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
    cursor_redraws: u64 = 0,
    vsync_misses: u64 = 0,
    avg_compose_time_us: u64 = 0,
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

pub const VsyncState = struct {
    enabled: bool = true,
    frame_target_us: u64 = 16667,
    last_present_tick: u64 = 0,
    frame_budget_remaining: i64 = 0,
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

var cursor_layer: CursorLayer = .{};
var vsync_state: VsyncState = .{};

/// Flip3D / 任务切换预览（离屏二次投影）— 宿主在启用时绘制覆盖层
pub var flip3d_preview_enabled: bool = false;

pub fn setFlip3dPreviewEnabled(enabled: bool) void {
    flip3d_preview_enabled = enabled;
    compositor_dirty = true;
}

pub fn isFlip3dPreviewEnabled() bool {
    return flip3d_preview_enabled;
}

pub fn init(width: u32, height: u32) void {
    screen_width = width;
    screen_height = height;
    surface_count = 0;
    next_surface_id = 1;
    compositor_dirty = true;
    stats = .{};
    dwm_composition_enabled = theme.isGlassEnabled();
    cursor_layer = .{};
    vsync_state = .{};

    cursor_layer.surface_id = createSurface(14, 20, .{
        .has_alpha = true,
        .is_visible = true,
        .is_cursor = true,
    });
    if (getSurface(cursor_layer.surface_id)) |sfc| {
        sfc.z_order = CURSOR_SURFACE_Z;
    }

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
    if (id == cursor_layer.surface_id) return false;

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

pub fn updateCursorPosition(x: i32, y: i32) void {
    if (x == cursor_layer.x and y == cursor_layer.y) return;

    cursor_layer.prev_x = cursor_layer.x;
    cursor_layer.prev_y = cursor_layer.y;
    cursor_layer.x = x;
    cursor_layer.y = y;
    cursor_layer.needs_redraw = true;

    if (getSurface(cursor_layer.surface_id)) |sfc| {
        sfc.x = x;
        sfc.y = y;
        sfc.markFullDirty();
    }
}

pub fn setCursorVisible(visible: bool) void {
    cursor_layer.visible = visible;
    if (getSurface(cursor_layer.surface_id)) |sfc| {
        sfc.flags.is_visible = visible;
    }
    compositor_dirty = true;
}

pub fn getCursorPosition() struct { x: i32, y: i32 } {
    return .{ .x = cursor_layer.x, .y = cursor_layer.y };
}

pub fn compose() void {
    if (!compositor_initialized) return;

    stats.total_frames += 1;

    const cursor_only = cursor_layer.needs_redraw and !needsSceneRedraw();

    if (cursor_only) {
        composeCursorOnly();
        return;
    }

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
        if (sfc.flags.is_cursor) continue;
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
    cursor_layer.needs_redraw = false;

    renderer.flushRender();
}

fn composeCursorOnly() void {
    if (cursor_layer.prev_x >= 0 and cursor_layer.prev_y >= 0) {
        const restore_rect = Rect{
            .x = cursor_layer.prev_x,
            .y = cursor_layer.prev_y,
            .w = cursor_layer.width + 2,
            .h = cursor_layer.height + 2,
        };
        renderer.setClip(restore_rect);
        renderer.fillRect(restore_rect, theme.getColors().desktop_background);

        for (surfaces[0..surface_count]) |*sfc| {
            if (!sfc.flags.is_visible or sfc.flags.is_cursor) continue;
            const bounds = sfc.getBounds();
            if (restore_rect.intersects(bounds)) {
                composeSurface(sfc);
            }
        }
        renderer.clearClip();
    }

    if (cursor_layer.visible) {
        if (getSurface(cursor_layer.surface_id)) |sfc| {
            composeSurface(sfc);
        }
    }

    cursor_layer.needs_redraw = false;
    stats.cursor_redraws += 1;

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
    sortSurfacesByZOrder();

    // 先以桌面底色填充所有脏区并集，避免局部 clip 合成时残留旧像素（类 DWM 脏矩形修复）
    var union_rect: Rect = .{};
    var has_union = false;
    for (surfaces[0..surface_count]) |*sfc| {
        if (!sfc.flags.is_visible or sfc.flags.is_cursor) continue;
        if (sfc.dirty and sfc.damage_count > 0) {
            const b = sfc.getDamageBounds();
            if (!has_union) {
                union_rect = b;
                has_union = true;
            } else {
                union_rect = union_rect.union_(b);
            }
        }
    }
    if (has_union and !union_rect.isEmpty()) {
        renderer.fillRect(union_rect, theme.getColors().desktop_background);
    }

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

    if (sfc.flags.needs_shadow and !sfc.flags.is_cursor) {
        renderer.drawShadow(bounds, theme.WINDOW_SHADOW_SIZE);
    }

    if (dwm_composition_enabled) {
        if (sfc.flags.is_glass) {
            const gp = theme.getGlassParams();
            renderer.drawBlur(bounds, sfc.blur_radius);
            renderer.fillRectAlpha(bounds, gp.tint_color, gp.tint_opacity);
            stats.glass_surfaces += 1;
        } else if (sfc.flags.needs_blur) {
            renderer.drawBlur(bounds, sfc.blur_radius);
            stats.glass_surfaces += 1;
        }
    }

    renderer.blitSurface(sfc.id, bounds, sfc.alpha);
}

fn needsRedraw() bool {
    if (compositor_dirty) return true;
    if (cursor_layer.needs_redraw) return true;
    for (surfaces[0..surface_count]) |*sfc| {
        if (sfc.dirty) return true;
    }
    return false;
}

fn needsSceneRedraw() bool {
    if (compositor_dirty) return true;
    for (surfaces[0..surface_count]) |*sfc| {
        if (sfc.flags.is_cursor) continue;
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

pub fn getCursorLayer() *const CursorLayer {
    return &cursor_layer;
}

pub fn getVsyncState() *const VsyncState {
    return &vsync_state;
}

pub fn setVsyncEnabled(enabled: bool) void {
    vsync_state.enabled = enabled;
}

pub fn setRefreshRate(hz: u32) void {
    if (hz > 0) {
        vsync_state.frame_target_us = 1_000_000 / @as(u64, hz);
    }
}

/// 自顶向下 Hit-test（排除桌面底图与光标层）；与 Shell 输入路由 Z 序一致。
pub fn hitTestTopMost(px: i32, py: i32) ?u32 {
    sortSurfacesByZOrder();
    var i = surface_count;
    while (i > 0) {
        i -= 1;
        const sfc = &surfaces[i];
        if (!sfc.flags.is_visible or sfc.flags.is_cursor or sfc.flags.is_desktop) continue;
        const b = sfc.getBounds();
        if (b.contains(px, py)) return sfc.id;
    }
    return null;
}

/// 若距离上一帧不足 `frame_target_us`，宿主可跳过 `compose()` 以降低 CPU 占用。
pub fn shouldThrottleFrame(now_us: u64) bool {
    if (!vsync_state.enabled) return false;
    if (vsync_state.last_present_tick == 0) return false;
    return (now_us -| vsync_state.last_present_tick) < vsync_state.frame_target_us;
}

pub fn recordPresentTime(now_us: u64) void {
    const elapsed = if (now_us > vsync_state.last_present_tick)
        now_us - vsync_state.last_present_tick
    else
        0;
    if (vsync_state.enabled and vsync_state.last_present_tick != 0 and elapsed > vsync_state.frame_target_us) {
        stats.vsync_misses += 1;
    }
    vsync_state.last_present_tick = now_us;
}

test "hitTestTopMost prefers higher z-order" {
    init(640, 480);
    const back = createSurface(100, 100, .{ .is_visible = true });
    const front = createSurface(50, 50, .{ .is_visible = true });
    moveSurface(back, 0, 0);
    setSurfaceZOrder(back, 1);
    moveSurface(front, 10, 10);
    setSurfaceZOrder(front, 10);
    try std.testing.expectEqual(front, hitTestTopMost(15, 15).?);
}
