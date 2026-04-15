//! Compositor - ZirconOS Aero Desktop Window Manager (DWM)
//! 表面标志与内核 `dwm_compositor` 的语义映射见 `src/config/dwm_surface_spec.zig`、`docs/cn/DesktopManagerSpec.md`。
//! **Shell 层脏区（规格）**：与内核 `display.zig` 对齐时，将开始菜单、桌面上下文菜单、任务栏托盘飞出、拖窗矩形视为独立 damage 源（`markDirty` / `markFullDirty`），便于未来方案 B→A 迁出内核合成而不整帧失效。
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
const dwm = @import("dwm");
const dnc = @import("dwm_nt61_api_contract");

pub const Rect = dwm.compositor.Rect;
pub const COLORREF = theme.COLORREF;

pub const MAX_SURFACES: usize = 64;
pub const MAX_DAMAGE_RECTS: usize = 16;
pub const INVALID_SURFACE: u32 = 0;

pub const CURSOR_SURFACE_Z: i32 = 0x7FFFFF00;
pub const DESKTOP_SURFACE_Z: i32 = -0x7FFFFF00;

/// 字段名与顺序必须与 [aero_flag_mapping.zig](../../config/aero_flag_mapping.zig) `UserlandSurfaceFlagsLayout`、
/// [DesktopManagerSpec.md](../../../docs/cn/DesktopManagerSpec.md) §4 一致；`comptime` 块调用 `assertUserlandSurfaceFlagsLayout`。
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
    /// 与 Learn `DwmExtendFrameIntoClientArea` / `MARGINS` 对齐的壳层提示（用户态合成阅读；内核 CSRSS 路径见 `dwmapi.zig`）。
    extend_margins: dnc.MARGINS = .{
        .cxLeftWidth = 0,
        .cxRightWidth = 0,
        .cyTopHeight = 0,
        .cyBottomHeight = 0,
    },
    /// 离屏表面 / 重定向位图共享计数；`destroySurface` 在减至 0 时移除槽位。
    ref_count: u32 = 1,

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

/// Flip3D / 任务切换预览（离屏二次投影）— 宿主在启用时绘制覆盖层。
/// 与内核 `display.flip3d_overlay_active` + `flip3d_needs_scene_refresh` 及 `dwm_compositor` 缩略数据源对齐：二者均为 **CPU 预览语义**，非完整 GPU Flip3D。
/// 契约对照行：[NT61_CONTRACT_MATRIX.md](../../../../docs/cn/NT61_CONTRACT_MATRIX.md) §4.1「用户态 flip3d_preview_enabled ↔ 内核 Flip3D」。
pub var flip3d_preview_enabled: bool = false;

/// 宿主若桥接内核桌面：应在得知 `display.flip3d_overlay_active`（或等价 IOCTL/LPC）时调用本函数以镜像状态；
/// **内核 GOP 路径不链接本模块**，默认值以 `nt61_aero_defaults.KernelCompositor.flip3d_enabled` 为是否响应 Alt+Tab 的唯一切换源。
pub fn setFlip3dPreviewEnabled(enabled: bool) void {
    flip3d_preview_enabled = enabled;
    dwm.compositor.markAllDirty();
}

pub fn isFlip3dPreviewEnabled() bool {
    return flip3d_preview_enabled;
}

pub fn init(width: u32, height: u32) void {
    // D3D10 DWM已经在dwm.init()中完成初始化，这里只需要同步配置
    dwm.compositor.resize(width, height);
    dwm_composition_enabled = theme.isGlassEnabled();
    compositor_initialized = true;
}

pub fn createSurface(width: u32, height: u32, flags: SurfaceFlags) u32 {
    // 转换标志到D3D10 DWM的surface标志
    var dwm_flags = dwm.surface_mgr.SurfaceFlags{};
    dwm_flags.has_alpha = flags.has_alpha;
    dwm_flags.needs_shadow = flags.needs_shadow;
    dwm_flags.is_visible = flags.is_visible;
    dwm_flags.is_opaque = flags.is_opaque;
    dwm_flags.needs_blur = flags.needs_blur;
    dwm_flags.is_glass = flags.is_glass;
    dwm_flags.is_cursor = flags.is_cursor;
    dwm_flags.is_desktop = flags.is_desktop;

    const id = dwm.surface_mgr.createSurface(width, height, dwm_flags);

    if (flags.is_glass and dwm_composition_enabled) {
        if (dwm.surface_mgr.getSurface(id)) |sfc| {
            sfc.alpha = theme.getGlassAlpha();
            sfc.blur_radius = theme.getBlurRadius();
        }
    }

    return id;
}

pub fn addSurfaceRef(id: u32) void {
    if (getSurface(id)) |sfc| {
        sfc.ref_count +|= 1;
    }
}

pub fn destroySurface(id: u32) bool {
    if (id == cursor_layer.surface_id) return false;

    var i: usize = 0;
    while (i < surface_count) {
        if (surfaces[i].id == id) {
            if (surfaces[i].ref_count > 1) {
                surfaces[i].ref_count -= 1;
                compositor_dirty = true;
                return true;
            }
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

/// 阶段 C：Zig 内部 `DwmExtendFrameIntoClientArea` 对等（用户态 compositor）。
pub fn setSurfaceExtendMargins(id: u32, m: dnc.MARGINS) void {
    if (getSurface(id)) |sfc| {
        sfc.extend_margins = m;
        sfc.markFullDirty();
        compositor_dirty = true;
    }
}

/// 阶段 C：`DwmEnableBlurBehindWindow` 对等（`DWM_BB_ENABLE` + `fEnable` 子集）。
pub fn setSurfaceBlurBehindDwm(id: u32, bb: dnc.DWM_BLURBEHIND) void {
    if (getSurface(id)) |sfc| {
        if ((bb.dwFlags & dnc.DWM_BB_ENABLE) != 0) {
            sfc.flags.needs_blur = bb.fEnable != 0;
            if (sfc.flags.needs_blur) {
                sfc.blur_radius = theme.getBlurRadius();
            } else {
                sfc.blur_radius = 0;
            }
        } else {
            sfc.flags.needs_blur = false;
            sfc.blur_radius = 0;
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

    // 直接调用D3D10 DWM的合成逻辑，硬件加速完成
    dwm.compositor.composeFrame();
}

fn composeCursorOnly() void {
    // 光标渲染由D3D10 DWM内部处理
}

fn composeFull(screen_rect: Rect) void {
    // 全屏合成由D3D10 DWM内部处理
    _ = screen_rect;
}

fn composePartial() void {
    // 局部合成由D3D10 DWM内部处理
}

fn composeSurface(sfc: *const Surface) void {
    // 这个函数现在由D3D10 DWM内部处理，保留空实现以兼容编译
    _ = sfc;
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

/// 稳定插入排序（按 `z_order` 升序）；同键保留数组原有相对顺序。
fn sortSurfacesByZOrder() void {
    if (surface_count <= 1) return;
    var i: usize = 1;
    while (i < surface_count) : (i += 1) {
        const key = surfaces[i];
        var j: usize = i;
        while (j > 0 and surfaces[j - 1].z_order > key.z_order) {
            surfaces[j] = surfaces[j - 1];
            j -= 1;
        }
        surfaces[j] = key;
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
    return dwm.compositor.hitTest(px, py);
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

comptime {
    @import("aero_flag_mapping").assertUserlandSurfaceFlagsLayout(SurfaceFlags);
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
