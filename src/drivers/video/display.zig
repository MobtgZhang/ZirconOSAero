//! Display Manager / Desktop Compositor — Windows 7 Aero (NT 6.1)
//!
//! Screen space (same as Windows / top-left origin): **(0,0) = top-left**, X increases
//! **right**, Y increases **down**. Taskbar occupies `y ∈ [scr_h - tb_h, scr_h)`.

const std = @import("std");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");
const vga_driver = @import("vga.zig");
const hdmi_driver = @import("hdmi.zig");
const fb = @import("framebuffer.zig");
const icons = @import("icons.zig");
const startmenu = @import("startmenu.zig");
const dwm_comp = @import("dwm_compositor.zig");
const mat = @import("material.zig");
const shell_strings = @import("shell_strings.zig");
const aero_tray = @import("aero_tray.zig");
const aero_cursor_shape = @import("aero_cursor_shape.zig");
const cursor_plane = @import("cursor_plane.zig");
const builtin_apps = @import("builtin_apps.zig");
const config = @import("../../config/config.zig");
const process = @import("../../ps/process.zig");
const user32 = @import("../../subsystems/win32/user32.zig");
const virtio_gpu_pci = @import("virtio_gpu_pci.zig");
const color_nt61 = @import("../../config/color_nt61.zig");

pub const theme_mod = @import("theme.zig");
pub const dwm_mod = @import("dwm.zig");
pub const renderer_aero = @import("renderer_aero.zig");
const wallpaper_bitmap = @import("wallpaper_bitmap.zig");
const display_flip_journal = @import("display_flip_journal.zig");

pub const ThemeColors = theme_mod.ThemeColors;

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub fn clampI32FromI64(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// 矩形宽/高：非负，且可安全落回 i32（用于 rectUnion 等 i64 差分）。
fn clampRectDimI64(d: i64) i32 {
    if (d <= 0) return 0;
    if (d > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(d);
}

/// 轴对齐矩形命中：`x ∈ [rx, rx+rw)`、`y ∈ [ry, ry+rh)`，加法在 i64 上避免 i32 溢出。
pub fn pointInRectI32(px: i32, py: i32, rx: i32, ry: i32, rw: i32, rh: i32) bool {
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    const x0 = @as(i64, rx);
    const y0 = @as(i64, ry);
    const w0 = @as(i64, rw);
    const h0 = @as(i64, rh);
    return pxi >= x0 and pyi >= y0 and pxi < x0 + w0 and pyi < y0 + h0;
}

// ── Theme Definitions (canonical source: theme.zig) ──

pub const THEME_AERO = theme_mod.THEME_AERO;

pub const ThemeId = theme_mod.ThemeId;

var active_theme: *const ThemeColors = &THEME_AERO;
var active_theme_id: ThemeId = .aero;

pub fn setTheme(id: ThemeId) void {
    theme_mod.setTheme(id);
    active_theme_id = id;
    active_theme = theme_mod.getActiveTheme();
}

pub fn getActiveTheme() *const ThemeColors {
    return active_theme;
}

pub fn getActiveThemeId() ThemeId {
    return active_theme_id;
}

pub fn getThemeName() []const u8 {
    return theme_mod.getThemeName();
}

// ── Display Mode / State ──

pub const DisplayMode = enum(u8) { text = 0, graphics_lowres = 1, graphics_svga = 2, graphics_hd = 3, desktop = 4 };
pub const DisplayState = enum(u8) { uninitialized = 0, text_mode = 1, graphics_mode = 2, desktop_mode = 3, suspended = 4 };

pub const Surface = struct {
    width: u32 = 0,
    height: u32 = 0,
    bpp: u8 = 0,
    pitch: u32 = 0,
    address: usize = 0,
    format: fb.PixelFormat = .xrgb8888,
};

pub const CursorState = struct {
    prev_x: i32 = -1,
    prev_y: i32 = -1,
    target_x: i32 = 0,
    target_y: i32 = 0,
    display_x: i32 = 0,
    display_y: i32 = 0,
    sub_x: i32 = 0,
    sub_y: i32 = 0,
    lerp_factor: i32 = 200,
    is_moving: bool = false,
    needs_restore: bool = false,
};

pub const DesktopContext = struct {
    surface: Surface = .{},
    background_color: u32 = 0,
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    cursor_visible: bool = true,
    vsync_enabled: bool = true,
    frame_count: u64 = 0,
    /// `present()` / `presentFull()` 调用次数；用于 Aero 首帧快速路径（跳过盒式模糊）。
    present_count: u64 = 0,
    smooth_cursor: CursorState = .{},
    dwm_active: bool = false,
};

// ── Global State ──

var display_state: DisplayState = .uninitialized;
var display_mode: DisplayMode = .text;
var desktop_ctx: DesktopContext = .{};

var desktop_cursor_kind: aero_cursor_shape.CursorKind = .arrow;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

var use_framebuffer: bool = false;
var use_hdmi: bool = false;

/// `renderDesktopFrameEx` 整场景路径计数 vs 增量/光标快路径（阶段 2 合成效率回归；与 `mouse_debug` 分类一致）。
var desktop_compose_full_scene_frames: u64 = 0;
var desktop_compose_partial_frames: u64 = 0;

// ── Layout Constants ──

/// 与 `theme.getTaskbarHeight()`（40）一致；遗留 `renderTaskbar` 路径仅内部使用。
const TASKBAR_H: i32 = 40;

/// Aero 开始球几何：左槽 `slot_w` 内水平居中，与任务栏垂直居中；`r` 为半径（直径小于 `tb_h` 以留边）。
fn aeroTaskbarStartOrb(tb_y: i32, tb_h: i32) struct { cx: i32, cy: i32, r: i32, slot_w: i32 } {
    const slot_w: i32 = 48;
    const r: i32 = 15;
    return .{
        .cx = @divTrunc(slot_w, 2),
        .cy = tb_y + @divTrunc(tb_h, 2),
        .r = r,
        .slot_w = slot_w,
    };
}
const TITLEBAR_H: i32 = 26;
const START_BTN_W: i32 = 108;
const ICON_GRID_X: i32 = 75;
const ICON_GRID_Y: i32 = 75;
const ICON_SIZE: i32 = 32;
const TRAY_CLOCK_W: i32 = 64;
const TRAY_H: i32 = 22;
const WINDOW_BORDER: i32 = 3;
const BTN_SIZE: i32 = 21;

/// 与 renderer_aero 中 Explorer / 壳窗口标题栏一致（勿与 TITLEBAR_H=26 混用）。
/// 双行标题（主标题 + 副标题）需足够高度；略收紧以接近 NT 6.1 Aero 资源管理器标题带比例。
pub const AERO_TITLEBAR_H: i32 = 32;
pub const AERO_CLIENT_INSET: i32 = 2;

/// NT 6.1 Aero 标题栏三键悬停（DWM 风格绘制 + 命中测试）。
pub const AeroCaptionBtnHover = enum { none, minimize, maximize, close };

/// Explorer / 任务管理器壳窗口的显示状态（与 Win32 SW_* 概念对齐，实现为内核壳层）。
pub const ShellWindowState = enum(u8) {
    normal,
    minimized,
    maximized,
};

/// 边框拖拽缩放时激活的边或角（`none` 表示未在缩放）。
pub const FrameResizeEdge = enum(u8) {
    none,
    n,
    s,
    e,
    w,
    ne,
    nw,
    se,
    sw,
};

/// 与 `hitTestFrameResizeEdge` 一致：边框命中带宽度（像素）。
const frame_resize_hit_px: i32 = 6;
const explorer_min_frame_w: i32 = 320;
const explorer_min_frame_h: i32 = 200;
const taskmgr_min_frame_w: i32 = 260;
const taskmgr_min_frame_h: i32 = 160;

var explorer_caption_btn_hover: AeroCaptionBtnHover = .none;
var taskmgr_caption_btn_hover: AeroCaptionBtnHover = .none;

/// Alt+Tab 风格 Flip3D 近似：全屏暗化 + 叠放窗口卡片（CPU 2D；无 GPU 透视）。
var flip3d_overlay_active: bool = false;
/// 打开 Flip3D 后首帧需整场景采样；之后冻结背景仅叠光标/覆盖层（见 `renderSceneWithoutSoftwareCursorFlip3dAware`）。
var flip3d_needs_scene_refresh: bool = false;
/// 任务栏 Explorer 磁贴悬停缩略图（`WM_DWMSENDICONICTHUMBNAIL` 壳层可视占位；自帧缓冲降采样）。
var taskbar_explorer_thumb: [20 * 15]u32 = [_]u32{0} ** (20 * 15);
var taskbar_explorer_thumb_valid: bool = false;
var taskbar_explorer_thumb_last_tick: u64 = 0;

pub fn isFlip3dOverlayActive() bool {
    return flip3d_overlay_active;
}

pub fn getExplorerCaptionBtnHover() AeroCaptionBtnHover {
    return explorer_caption_btn_hover;
}

pub fn getTaskMgrCaptionBtnHover() AeroCaptionBtnHover {
    return taskmgr_caption_btn_hover;
}

/// NT 6.1 Aero：最小化/最大化等宽略扁矩形，关闭列更宽；按钮区相对标题栏垂直内缩，热区仍覆盖整段标题高度。
pub fn aeroCaptionButtonLayout(win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32) struct {
    min_x: i32,
    max_x: i32,
    close_x: i32,
    btn_w: i32,
    btn_w_close: i32,
    btn_y: i32,
    btn_h: i32,
    group_sep_x: i32,
} {
    const vpad: i32 = 2;
    const btn_h = @max(18, titlebar_h - 2 * vpad);
    const btn_y = win_y + @divTrunc(titlebar_h - btn_h, 2);
    const btn_w: i32 = if (titlebar_h >= 28) 40 else @max(34, titlebar_h + 2);
    const btn_w_close: i32 = btn_w + 8;
    const close_x = clampI32FromI64(@as(i64, win_x) + @as(i64, win_w) - @as(i64, btn_w_close));
    const max_x = clampI32FromI64(@as(i64, close_x) - @as(i64, btn_w));
    const min_x = clampI32FromI64(@as(i64, max_x) - @as(i64, btn_w));
    const group_sep_x = clampI32FromI64(@as(i64, min_x) - 1);
    return .{
        .min_x = min_x,
        .max_x = max_x,
        .close_x = close_x,
        .btn_w = btn_w,
        .btn_w_close = btn_w_close,
        .btn_y = btn_y,
        .btn_h = btn_h,
        .group_sep_x = group_sep_x,
    };
}

pub fn hitTestAeroCaptionButtons(px: i32, py: i32, win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32) AeroCaptionBtnHover {
    if (titlebar_h < 4 or win_w < 96) return .none;
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    const wx = @as(i64, win_x);
    const wy = @as(i64, win_y);
    const ww = @as(i64, win_w);
    const th = @as(i64, titlebar_h);
    if (pxi < wx or pyi < wy or pxi >= wx + ww or pyi >= wy + th) return .none;
    const L = aeroCaptionButtonLayout(win_x, win_y, win_w, titlebar_h);
    if (pxi < @as(i64, L.min_x)) return .none;
    if (pxi >= @as(i64, L.close_x) + @as(i64, L.btn_w_close)) return .none;
    if (pxi >= @as(i64, L.close_x)) return .close;
    if (pxi >= @as(i64, L.max_x)) return .maximize;
    return .minimize;
}

/// 迟滞：上一帧在某按钮上时扩大该按钮命中区（约 2px），减少三键边界上每帧翻转与整屏重绘。
fn inCaptionButtonStickyPx(pxi: i64, pyi: i64, L: anytype, wy: i64, th: i64, which: AeroCaptionBtnHover, exp: i64) bool {
    const y0 = wy - exp;
    const y1 = wy + th + exp;
    if (pyi < y0 or pyi >= y1) return false;
    switch (which) {
        .none => return false,
        .close => {
            const x0 = @as(i64, L.close_x) - exp;
            const x1 = @as(i64, L.close_x) + @as(i64, L.btn_w_close) + exp;
            return pxi >= x0 and pxi < x1;
        },
        .maximize => {
            const x0 = @as(i64, L.max_x) - exp;
            const x1 = @as(i64, L.close_x) + exp;
            return pxi >= x0 and pxi < x1;
        },
        .minimize => {
            const x0 = @as(i64, L.min_x) - exp;
            const x1 = @as(i64, L.max_x) + exp;
            return pxi >= x0 and pxi < x1;
        },
    }
}

pub fn hitTestAeroCaptionButtonsHysteresis(px: i32, py: i32, win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32, prev: AeroCaptionBtnHover) AeroCaptionBtnHover {
    const raw = hitTestAeroCaptionButtons(px, py, win_x, win_y, win_w, titlebar_h);
    if (prev == .none) return raw;
    const L = aeroCaptionButtonLayout(win_x, win_y, win_w, titlebar_h);
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    const wy = @as(i64, win_y);
    const th = @as(i64, titlebar_h);
    const sticky_exp: i64 = 2;
    if (inCaptionButtonStickyPx(pxi, pyi, L, wy, th, prev, sticky_exp)) return prev;
    return raw;
}

/// 与 renderer_aero.renderExplorerContent 中命令栏/地址栏高度一致（用于命中测试）。
pub const AERO_EXPLORER_CMD_H: i32 = 28;
pub const AERO_EXPLORER_ADDR_H: i32 = 26;
/// 与 `renderer_aero.renderExplorerContent` 地址栏「Go」按钮一致（命中测试必须同源）。
pub const AERO_EXPLORER_GO_BTN_W: i32 = 40;
pub const AERO_EXPLORER_GO_MARGIN_END: i32 = 6;
/// 库视图地址行：面包屑字段起点（相对客户区左缘 + inset）、右侧搜索框宽度（与 renderer_aero 一致）。
pub const AERO_EXPLORER_LIB_ADDR_FIELD_X: i32 = 54;
pub const AERO_EXPLORER_LIB_SEARCH_W: i32 = 140;

pub const ExplorerShellView = enum { computer, libraries };

var explorer_shell_view_state: ExplorerShellView = .libraries;

pub fn getExplorerShellView() ExplorerShellView {
    return explorer_shell_view_state;
}

pub fn setExplorerShellView(v: ExplorerShellView) void {
    explorer_shell_view_state = v;
}

fn shellTitlebarH() i32 {
    return AERO_TITLEBAR_H;
}

// ── IOCTL Codes ──

pub const IOCTL_DISPLAY_GET_STATE: u32 = 0x000A0000;
pub const IOCTL_DISPLAY_SET_MODE: u32 = 0x000A0004;
pub const IOCTL_DISPLAY_GET_SURFACE: u32 = 0x000A0008;
pub const IOCTL_DISPLAY_SET_BG_COLOR: u32 = 0x000A000C;
pub const IOCTL_DISPLAY_SET_CURSOR: u32 = 0x000A0010;
pub const IOCTL_DISPLAY_PRESENT: u32 = 0x000A0014;
pub const IOCTL_DISPLAY_ENUMERATE: u32 = 0x000A0018;

// ── Display Initialization ──

pub fn initDesktopMode(fb_addr: usize, width: u32, height: u32, pitch: u32, bpp: u8, pixel_bgr: bool) void {
    // 合成顺序契约（整帧）：renderer_aero / 壳层 → 软件 CursorPlane → present()/flip。
    fb.init(fb_addr, width, height, pitch, bpp, pixel_bgr);
    use_framebuffer = true;

    const min_pitch = width *| @as(u32, bpp) / 8;
    if (pitch < min_pitch) {
        klog.warn("DesktopFB: pitch=%u < width*bpp/8 (%u) — check UEFI GOP / ZBM handoff (LoongArch: EfiHandoff.fb_pitch)", .{
            pitch, min_pitch,
        });
    }
    fb.logDesktopGopSummary();

    desktop_ctx.surface = .{
        .width = width,
        .height = height,
        .bpp = bpp,
        .pitch = pitch,
        .address = fb_addr,
        .format = if (bpp == 32) .xrgb8888 else if (bpp == 24) .rgb888 else .rgb565,
    };

    display_state = .desktop_mode;
    display_mode = .desktop;

    const app_cfg = @import("../../config/config.zig");
    @import("shell_strings.zig").explorer_use_zh = app_cfg.isExplorerShellLangZh();
}

pub fn initTextMode() void {
    vga_driver.init();
    vga_driver.setTextMode();
    display_state = .text_mode;
    display_mode = .text;
}

/// `desktop_bisect` 串口日志用：0 表示未初始化帧缓冲。
pub fn desktopFramebufferWidth() u32 {
    if (!use_framebuffer or !fb.isInitialized()) return 0;
    return fb.getWidth();
}

// ══════════════════════════════════════════════════════════════
//  Desktop Rendering (theme-aware)
// ══════════════════════════════════════════════════════════════

pub fn clearFramebuffer() void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    cursor_plane.invalidate();
    fb.clearScreen(0x00000000);
}

pub const ShellRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Explorer / 任务管理器客户区外框宽高（与 `computeSampleWindowDims` / `explorerFrameDims` 共用类型，避免 Zig 匿名结构体不兼容）。
pub const ShellFrameDims = struct { w: i32, h: i32 };

pub fn rectUnion(a: ShellRect, b: ShellRect) ShellRect {
    const ax1 = @as(i64, a.x);
    const ay1 = @as(i64, a.y);
    const bx1 = @as(i64, b.x);
    const by1 = @as(i64, b.y);
    const ax2 = ax1 + a.w;
    const ay2 = ay1 + a.h;
    const bx2 = bx1 + b.w;
    const by2 = by1 + b.h;
    const x1 = @min(ax1, bx1);
    const y1 = @min(ay1, by1);
    const x2 = @max(ax2, bx2);
    const y2 = @max(ay2, by2);
    return .{
        .x = clampI32FromI64(x1),
        .y = clampI32FromI64(y1),
        .w = clampRectDimI64(x2 - x1),
        .h = clampRectDimI64(y2 - y1),
    };
}

pub fn rectInflate(r: ShellRect, p: i32) ShellRect {
    const pi = @as(i64, p);
    const x = @as(i64, r.x) - pi;
    const y = @as(i64, r.y) - pi;
    const w = @as(i64, r.w) + 2 * pi;
    const h = @as(i64, r.h) + 2 * pi;
    return .{
        .x = clampI32FromI64(x),
        .y = clampI32FromI64(y),
        .w = clampRectDimI64(w),
        .h = clampRectDimI64(h),
    };
}

pub fn rectClampToScreen(r: ShellRect, scr_w: i32, scr_h: i32) ShellRect {
    var x: i64 = r.x;
    var y: i64 = r.y;
    var rw: i64 = r.w;
    var rh: i64 = r.h;
    const sw: i64 = scr_w;
    const sh: i64 = scr_h;
    if (x < 0) {
        rw += x;
        x = 0;
    }
    if (y < 0) {
        rh += y;
        y = 0;
    }
    if (x + rw > sw) rw = sw - x;
    if (y + rh > sh) rh = sh - y;
    if (rw < 0) rw = 0;
    if (rh < 0) rh = 0;
    return .{
        .x = clampI32FromI64(x),
        .y = clampI32FromI64(y),
        .w = clampRectDimI64(rw),
        .h = clampRectDimI64(rh),
    };
}

pub fn rectIntersection(a: ShellRect, b: ShellRect) ?ShellRect {
    const ax1 = @as(i64, a.x);
    const ay1 = @as(i64, a.y);
    const bx1 = @as(i64, b.x);
    const by1 = @as(i64, b.y);
    const ax2 = ax1 + a.w;
    const ay2 = ay1 + a.h;
    const bx2 = bx1 + b.w;
    const by2 = by1 + b.h;
    const x1 = @max(ax1, bx1);
    const y1 = @max(ay1, by1);
    const x2 = @min(ax2, bx2);
    const y2 = @min(ay2, by2);
    if (x2 <= x1 or y2 <= y1) return null;
    return .{
        .x = clampI32FromI64(x1),
        .y = clampI32FromI64(y1),
        .w = clampRectDimI64(x2 - x1),
        .h = clampRectDimI64(y2 - y1),
    };
}

pub fn rectsOverlap(a: ShellRect, b: ShellRect) bool {
    return rectIntersection(a, b) != null;
}

/// 桌面图标列保守外包（与 `renderDesktopIcons` 左列 + 标签宽度一致量级）。
pub fn desktopIconStripBounds(scr_w: i32, scr_h: i32) ShellRect {
    const tb = getTaskbarHeight();
    const strip_w: i32 = @min(200, scr_w);
    const sh = @as(i64, scr_h) - @as(i64, tb) - 8;
    const h: i32 = if (sh > 0) clampI32FromI64(sh) else 0;
    return .{ .x = 0, .y = 0, .w = strip_w, .h = h };
}

pub fn taskbarBoundsRect(scr_w: i32, scr_h: i32) ShellRect {
    const tb = getTaskbarHeight();
    const y = clampI32FromI64(@as(i64, scr_h) - @as(i64, tb));
    return .{ .x = 0, .y = y, .w = scr_w, .h = tb };
}

pub fn patchVerticalGradientRegion(scr_w: i32, scr_h: i32, rx: i32, ry: i32, rw: i32, rh: i32, topc: u32, botc: u32) void {
    var r = ShellRect{ .x = rx, .y = ry, .w = rw, .h = rh };
    r = rectClampToScreen(r, scr_w, scr_h);
    if (r.w <= 0 or r.h <= 0 or scr_h <= 0) return;
    const gh: u32 = @intCast(scr_h);
    const sh1: i64 = @as(i64, scr_h) - 1;
    const row_top = std.math.clamp(@as(i64, r.y), 0, @max(0, sh1));
    const row_bot = std.math.clamp(@as(i64, r.y) + @as(i64, r.h) - 1, 0, @max(0, sh1));
    const t1 = @as(u32, @intCast(row_top));
    const t2 = @as(u32, @intCast(row_bot));
    const c_top = fb.interpolateColor(topc, botc, t1, gh);
    const c_bot = fb.interpolateColor(topc, botc, t2, gh);
    fb.drawGradientV(r.x, r.y, r.w, r.h, c_top, c_bot);
}

/// Redraw wallpaper in a dirty rectangle（**所有** `wallpaper_bitmap` 预设；函数名历史遗留「Harmony」）。
pub fn patchHarmonyWallpaperRegion(scr_w: i32, scr_h: i32, rx: i32, ry: i32, rw: i32, rh: i32) void {
    wallpaper_bitmap.drawPresetRegion(renderer_aero.wallpaperPresetIndex(), scr_w, scr_h, rx, ry, rw, rh);
}

fn patchAeroDragBackground(scr_w: i32, scr_h: i32) void {
    const pad: i32 = 10;
    if (drag_active) {
        const wr = getWindowRect(scr_w, scr_h);
        const cur = ShellRect{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h };
        var u = rectUnion(explorer_drag_prev_rect, cur);
        u = rectInflate(u, pad);
        u = rectClampToScreen(u, scr_w, scr_h);
        if (u.w > 0 and u.h > 0) {
            patchHarmonyWallpaperRegion(scr_w, scr_h, u.x, u.y, u.w, u.h);
        }
        explorer_drag_prev_rect = cur;
    }
    if (taskmgr_drag_active) {
        const cur = ShellRect{ .x = taskmgr_x, .y = taskmgr_y, .w = taskmgr_w, .h = taskmgr_h };
        var u = rectUnion(taskmgr_drag_prev_rect, cur);
        u = rectInflate(u, pad);
        u = rectClampToScreen(u, scr_w, scr_h);
        if (u.w > 0 and u.h > 0) {
            patchHarmonyWallpaperRegion(scr_w, scr_h, u.x, u.y, u.w, u.h);
        }
        taskmgr_drag_prev_rect = cur;
    }
}

var explorer_drag_prev_rect: ShellRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var taskmgr_drag_prev_rect: ShellRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

fn renderSceneWithoutSoftwareCursor() void {
    const panic_ctx = @import("../../rtl/panic_context.zig");
    panic_ctx.setPhase(0x0002_0070);
    cursor_plane.invalidate();
    syncAeroGlassFastPath();
    panic_ctx.setPhase(0x0002_0071);
    renderer_aero.renderFrameEx(false);
}

fn renderSceneWithoutSoftwareCursorFlip3dAware(scene_dirty: bool) void {
    const freeze_bg = flip3d_overlay_active and !flip3d_needs_scene_refresh;
    if (freeze_bg and !scene_dirty) {
        syncAeroGlassFastPath();
    } else {
        renderSceneWithoutSoftwareCursor();
        if (flip3d_overlay_active) flip3d_needs_scene_refresh = false;
    }
}

/// Returns the taskbar height for the active theme（与 Aero 任务栏绘制一致）。
pub fn getTaskbarHeight() i32 {
    return theme_mod.getTaskbarHeight();
}

/// Align DWM smooth-cursor state with the PS/2 driver so the first painted frame
/// shows the pointer at the correct position (typically screen center).
pub fn syncCursorFromMouse() void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    const mouse = @import("../input/mouse.zig");
    const mx = mouse.getX();
    const my = mouse.getY();
    const P: i32 = 256;
    desktop_ctx.smooth_cursor.sub_x = @truncate(@as(i64, mx) * @as(i64, P));
    desktop_ctx.smooth_cursor.sub_y = @truncate(@as(i64, my) * @as(i64, P));
    desktop_ctx.smooth_cursor.display_x = mx;
    desktop_ctx.smooth_cursor.display_y = my;
    desktop_ctx.smooth_cursor.target_x = mx;
    desktop_ctx.smooth_cursor.target_y = my;
    desktop_ctx.smooth_cursor.prev_x = mx;
    desktop_ctx.smooth_cursor.prev_y = my;
    desktop_ctx.cursor_x = mx;
    desktop_ctx.cursor_y = my;
}

fn appendU32Digits(buf: []u8, pos: usize, n: u32) usize {
    if (n == 0) {
        if (pos < buf.len) buf[pos] = '0';
        return pos + 1;
    }
    var tmp: [10]u8 = undefined;
    var d: usize = 0;
    var n2 = n;
    while (n2 > 0) : (n2 /= 10) {
        tmp[d] = @truncate('0' + (n2 % 10));
        d += 1;
    }
    var p = pos;
    while (d > 0) {
        d -= 1;
        if (p < buf.len) buf[p] = tmp[d];
        p += 1;
    }
    return p;
}

fn appendSignedI32(buf: []u8, pos: usize, v: i32) usize {
    if (v >= 0) return appendU32Digits(buf, pos, @intCast(v));
    var p = pos;
    if (p < buf.len) {
        buf[p] = '-';
        p += 1;
    }
    const vu: u32 = @intCast(-@as(i64, v));
    return appendU32Digits(buf, p, vu);
}

/// Bottom-right status line: theme + resolution + DWM (above taskbar, not top-left banner).
fn buildSystemInfoText() []const u8 {
    var buf: [160]u8 = undefined;
    var pos: usize = 0;
    const prefix = "ZirconOSAero | ";
    for (prefix) |c| {
        if (pos < buf.len) {
            buf[pos] = c;
            pos += 1;
        }
    }
    const theme_part: []const u8 = "Aero";
    for (theme_part) |c| {
        if (pos < buf.len) {
            buf[pos] = c;
            pos += 1;
        }
    }
    const sep = " | ";
    for (sep) |c| {
        if (pos < buf.len) {
            buf[pos] = c;
            pos += 1;
        }
    }
    pos = appendU32Digits(buf[0..], pos, fb.getWidth());
    if (pos < buf.len) {
        buf[pos] = 'x';
        pos += 1;
    }
    pos = appendU32Digits(buf[0..], pos, fb.getHeight());
    const tail = " | DWM";
    for (tail) |c| {
        if (pos < buf.len) {
            buf[pos] = c;
            pos += 1;
        }
    }
    if (@import("build_options").mouse_debug) {
        const mouse = @import("../input/mouse.zig");
        const mx = mouse.getX();
        const my = mouse.getY();
        const ptr_lbl = " | ptr ";
        for (ptr_lbl) |c| {
            if (pos < buf.len) {
                buf[pos] = c;
                pos += 1;
            }
        }
        pos = appendSignedI32(buf[0..], pos, mx);
        if (pos < buf.len) {
            buf[pos] = ',';
            pos += 1;
        }
        pos = appendSignedI32(buf[0..], pos, my);
    }
    return buf[0..pos];
}

pub fn drawSystemInfoStrip(scr_w: i32, scr_h: i32, tb_h: i32) void {
    const text = buildSystemInfoText();
    const scale: u32 = 2;
    const tw = fb.textWidthScaled(text, scale);
    const pad: i32 = 12;
    const strip_h: i32 = @as(i32, @intCast(16 * scale)) + 8;
    const bar_y = clampI32FromI64(@as(i64, scr_h) - @as(i64, tb_h) - @as(i64, strip_h));
    if (bar_y < 4) return;
    const tw_pad: i64 = @as(i64, tw) + @as(i64, pad) * 2;
    const bar_w = @min(scr_w - 16, clampI32FromI64(tw_pad));
    const bar_x = clampI32FromI64(@as(i64, scr_w) - @as(i64, bar_w) - 8);

    fb.fillRect(bar_x, bar_y, bar_w, strip_h, rgb(0x18, 0x1A, 0x22));
    fb.drawRect(bar_x, bar_y, bar_w, strip_h, rgb(0x50, 0x5C, 0x70));
    fb.drawHLine(bar_x + 1, bar_y + 1, bar_w - 2, rgb(0x35, 0x3D, 0x4A));

    const tx = clampI32FromI64(@as(i64, bar_x) + @as(i64, bar_w) - @as(i64, tw) - @as(i64, pad));
    const ty = bar_y + @divTrunc(strip_h - @as(i32, @intCast(16 * scale)), 2);
    fb.drawTextTransparentScaled(tx, ty, text, rgb(0xE4, 0xE8, 0xF2), scale);
}

pub fn renderDesktopFrame() void {
    renderDesktopFrameEx(true, false, false, false, false);
}

/// `scene_dirty`：整壁纸+壳层；`startmenu_repaint`：开始菜单悬停行变化时的局部重绘（Harmony 壁纸预设下避免整帧）；`caption_chrome_only`：仅标题栏带；`drag_repaint`：仅拖窗合成（`renderDragFrame`），不计入整场景以免与光标快速路径冲突。
/// `shell_geometry_repaint`：边框缩放或 `needs_post_drag_composite`（松手恢复全窗玻璃）等：`renderFrameEx` 全壳层，非整场景 `scene_dirty`。
/// `scene_dirty` 为真时优先于其余路径。
/// **诊断**：`-Ddwm_blur_stats=true` 时本帧结束打 `klog.debug` 一行（盒式模糊调用次数、预算拒绝、`renderGlassTintOnly` 次数）；常与 `-Ddesktop_bisect` 分帧日志配合。
pub fn renderDesktopFrameEx(scene_dirty: bool, caption_chrome_only: bool, drag_repaint: bool, startmenu_repaint: bool, shell_geometry_repaint: bool) void {
    const panic_ctx = @import("../../rtl/panic_context.zig");
    panic_ctx.setPhase(0x0002_0001);
    defer panic_ctx.setPhase(0);
    if (!use_framebuffer or !fb.isInitialized()) return;

    dwm_mod.beginFrameBlurBudget();

    // Blur 策略（与 `syncAeroGlassFastPath` 矩阵，见 SOFTWARE_COMPOSITOR_WDDM.md）：此处按 **壳层 UI** 打开态启用轻量模糊；
    // `present`/其他路径上较晚调用的 `syncAeroGlassFastPath` 再按 **首帧跳过盒式模糊**、**拖窗** 覆盖。二者均为 dwm 帧内布尔开关，不重复扣 `blur_budget_pixel_passes`。
    const shell_glass_lite = ctx_menu_visible or startmenu.isVisible() or aero_tray_flyout_visible;
    dwm_mod.setGlassLiteBlurEnabled(shell_glass_lite);
    defer dwm_mod.setGlassLiteBlurEnabled(false);

    // 合成顺序：场景（壁纸/窗口/DWM 效果）→ 任务栏等壳层（renderer_aero 内）→ CursorPlane（save-under + 绘制）→ 调用方 present。
    // 合成前再排空一轮输入，避免 IRQ/轮询与取样之间存在竞态导致本帧光标滞后一整帧。
    const input_hub = @import("../../drivers/input/input_hub.zig");
    input_hub.pollAll();
    panic_ctx.setPhase(0x0002_0010);

    // VirtIO-Input / PS/2 均在 mouse 状态中更新坐标；非 x86 也必须每帧同步到 desktop_ctx，
    // 否则光标停留在 syncCursorFromMouse 的初值（VirtIO 事件无法驱动绘制）。
    const mouse = @import("../../drivers/input/mouse.zig");

    // 开始菜单打开时仍保留适度插值步数，避免重绘帧后光标长时间「追赶」指针（原 2 步过苛）。
    const interp_limit: u32 = if (isWindowDragging() or ctx_menu_visible or startmenu.isVisible() or aero_tray_flyout_visible) 5 else 8;
    var interp_steps: u32 = 0;
    while (mouse.isInterpolating() and interp_steps < interp_limit) : (interp_steps += 1) {
        mouse.interpolateStep();
    }

    const raw_x = mouse.getX();
    const raw_y = mouse.getY();

    updateSmoothCursor(raw_x, raw_y);
    desktop_ctx.cursor_x = desktop_ctx.smooth_cursor.display_x;
    desktop_ctx.cursor_y = desktop_ctx.smooth_cursor.display_y;
    panic_ctx.setPhase(0x0002_0020);

    const mouse_debug = @import("../../drivers/input/mouse_debug.zig");
    const md_enabled = @import("build_options").mouse_debug;

    var path_kind: mouse_debug.DesktopRenderPathKind = .cursor_fast;

    if (scene_dirty) {
        path_kind = .full;
        panic_ctx.setPhase(0x0002_0030);
        renderSceneWithoutSoftwareCursorFlip3dAware(true);
        panic_ctx.setPhase(0x0002_0040);
        cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
    } else if (drag_repaint) {
        path_kind = .drag_layer;
        syncAeroGlassFastPath();
        renderer_aero.renderFrameEx(false);
        panic_ctx.setPhase(0x0002_0041);
        cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
    } else if (shell_geometry_repaint) {
        path_kind = .drag_layer;
        syncAeroGlassFastPath();
        renderer_aero.renderFrameEx(false);
        panic_ctx.setPhase(0x0002_0042);
        cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
    } else if (startmenu_repaint and startmenu.isVisible()) {
        if (renderer_aero.startMenuRepaintCanPatchWallpaper()) {
            path_kind = .startmenu_partial;
            cursor_plane.restoreSaveUnderIfPlaced();
            syncAeroGlassFastPath();
            theme_mod.setTheme(.aero);
            const scr_w: i32 = @intCast(fb.getWidth());
            const scr_h: i32 = @intCast(fb.getHeight());
            const t = theme_mod.getActiveTheme();
            const tb_h = theme_mod.getTaskbarHeight();
            renderer_aero.redrawStartMenuRegionOnly(scr_w, scr_h, t, tb_h);
            panic_ctx.setPhase(0x0002_0043);
            cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
            cursor_plane.markMotionDirty(
                desktop_ctx.smooth_cursor.prev_x,
                desktop_ctx.smooth_cursor.prev_y,
                desktop_ctx.cursor_x,
                desktop_ctx.cursor_y,
            );
        } else {
            path_kind = .full;
            panic_ctx.setPhase(0x0002_0031);
            renderSceneWithoutSoftwareCursorFlip3dAware(true);
            panic_ctx.setPhase(0x0002_0044);
            cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
        }
    } else if (caption_chrome_only) {
        path_kind = .caption_partial;
        cursor_plane.restoreSaveUnderIfPlaced();
        syncAeroGlassFastPath();
        renderer_aero.redrawCaptionBandsOnly();
        panic_ctx.setPhase(0x0002_0045);
        cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
        cursor_plane.markMotionDirty(
            desktop_ctx.smooth_cursor.prev_x,
            desktop_ctx.smooth_cursor.prev_y,
            desktop_ctx.cursor_x,
            desktop_ctx.cursor_y,
        );
    } else {
        // 壳层打开时：场景已在上一整帧写入缓冲（含菜单/托盘），仅指针移动可走 moveOnly，避免每帧全屏 DWM。
        if (ctx_menu_visible or startmenu.isVisible() or aero_tray_flyout_visible) {
            panic_ctx.setPhase(0x0002_0050);
            if (cursor_plane.moveOnly(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_ctx.smooth_cursor.prev_x, desktop_ctx.smooth_cursor.prev_y, desktop_cursor_kind, renderCursor)) {
                path_kind = .cursor_fast;
            } else {
                path_kind = .full;
                panic_ctx.setPhase(0x0002_0032);
                renderSceneWithoutSoftwareCursorFlip3dAware(false);
                panic_ctx.setPhase(0x0002_0046);
                cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
            }
        } else {
            panic_ctx.setPhase(0x0002_0051);
            if (!cursor_plane.moveOnly(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_ctx.smooth_cursor.prev_x, desktop_ctx.smooth_cursor.prev_y, desktop_cursor_kind, renderCursor)) {
                path_kind = .full;
                panic_ctx.setPhase(0x0002_0033);
                renderSceneWithoutSoftwareCursorFlip3dAware(false);
                panic_ctx.setPhase(0x0002_0047);
                cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
            }
        }
    }
    if (flip3d_overlay_active) {
        panic_ctx.setPhase(0x0002_0067);
        renderFlip3dOverlay(@intCast(fb.getWidth()), @intCast(fb.getHeight()));
        cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
    }
    panic_ctx.setPhase(0x0002_0060);
    syncDwmCompositorShellMetadata(@intCast(fb.getWidth()), @intCast(fb.getHeight()));
    switch (path_kind) {
        .full => desktop_compose_full_scene_frames +%= 1,
        else => desktop_compose_partial_frames +%= 1,
    }
    if (md_enabled) {
        mouse_debug.noteDesktopRenderPath(path_kind);
    }
    mouse.clearCursorMoved();

    if (shell_blur_cooldown_frames > 0) {
        shell_blur_cooldown_frames -= 1;
    }
    dwm_mod.flushBlurFrameStatsDebug();
}

fn updateSmoothCursor(raw_x: i32, raw_y: i32) void {
    const sc = &desktop_ctx.smooth_cursor;
    sc.target_x = raw_x;
    sc.target_y = raw_y;

    sc.prev_x = sc.display_x;
    sc.prev_y = sc.display_y;

    const w_i32: i32 = @intCast(fb.getWidth());
    const h_i32: i32 = @intCast(fb.getHeight());
    // 先钳位再算 sub_x=sub_y*256，避免 ABS/异常坐标下 i32 乘法在 Debug 下 panic。
    var dx = raw_x;
    var dy = raw_y;
    if (dx < 0) dx = 0;
    if (dy < 0) dy = 0;
    if (w_i32 > 0) {
        if (dx >= w_i32) dx = w_i32 - 1;
    } else {
        dx = 0;
    }
    if (h_i32 > 0) {
        if (dy >= h_i32) dy = h_i32 - 1;
    } else {
        dy = 0;
    }

    sc.display_x = dx;
    sc.display_y = dy;

    const P: i32 = 256;
    sc.sub_x = @truncate(@as(i64, dx) * @as(i64, P));
    sc.sub_y = @truncate(@as(i64, dy) * @as(i64, P));

    sc.is_moving = (sc.display_x != sc.prev_x or sc.display_y != sc.prev_y);
}

pub fn toggleStartMenu() void {
    startmenu.toggle(.aero);
    // 下一帧优先走整场景或 composeAfterScene，避免沿用仅指针路径下的旧 save-under。
    cursor_plane.invalidate();
}

pub fn isStartMenuVisible() bool {
    return startmenu.isVisible();
}

pub fn hideStartMenu() void {
    startmenu.hide();
    cursor_plane.invalidate();
}

/// 键盘快捷键（如 Ctrl+Shift+Esc → 任务管理器；Ctrl+Alt+F9 → 循环壁纸预设；Alt+Tab → Flip3D 近似）。返回 true 时需整屏重绘。
pub fn handleDesktopHotkeys() bool {
    const arch = @import("../../arch.zig");
    const nt61_aero = @import("nt61_aero_defaults");
    // 单消费：`consumeFlip3dHotkey` 仅在键盘 IRQ 路径置位；此处为壳层唯一读取点（与矩阵 §4.1 Flip3D 一致）。
    if (nt61_aero.KernelCompositor.flip3d_enabled and arch.consumeFlip3dHotkey()) {
        flip3d_overlay_active = !flip3d_overlay_active;
        flip3d_needs_scene_refresh = flip3d_overlay_active;
        cursor_plane.invalidate();
        return true;
    }
    if (arch.consumeTaskMgrHotkey()) {
        bringTaskManagerToFront();
        return true;
    }
    if (arch.consumeWallpaperCycleHotkey()) {
        renderer_aero.cycleWallpaperPreset();
        return true;
    }
    return false;
}

pub fn bringTaskManagerToFront() void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    taskmgr_shell_state = .normal;
    const scr_w: i32 = @intCast(fb.getWidth());
    const scr_h: i32 = @intCast(fb.getHeight());
    const tm_w = taskmgr_w;
    const tm_h = taskmgr_h;
    const tb = getTaskbarHeight();
    const pad: i32 = 12;
    taskmgr_x = @divTrunc(scr_w - tm_w, 2);
    taskmgr_y = scr_h - tb - tm_h - pad;
    if (taskmgr_y < pad) taskmgr_y = pad;
    if (taskmgr_x < pad) taskmgr_x = pad;
    if (taskmgr_x + tm_w > scr_w - pad) taskmgr_x = scr_w - tm_w - pad;
}

fn isStartButtonClick(click_x: i32, click_y: i32, scr_w: i32, scr_h: i32) bool {
    _ = scr_w;
    const tb_h = getTaskbarHeight();
    const tb_y = clampI32FromI64(@as(i64, scr_h) - @as(i64, tb_h));
    if (click_y >= scr_h or click_y < tb_y) return false;

    const o = aeroTaskbarStartOrb(tb_y, tb_h);
    const dx = click_x - o.cx;
    const dy = click_y - o.cy;
    const hit_r = o.r + 2;
    const dx64 = @as(i64, dx);
    const dy64 = @as(i64, dy);
    const hr = @as(i64, hit_r);
    return dx64 * dx64 + dy64 * dy64 <= hr * hr;
}

fn taskMgrWindowContains(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    if (taskmgr_shell_state == .minimized) return false;
    initTaskMgrPosition(scr_w, scr_h);
    return pointInRectI32(px, py, taskmgr_x, taskmgr_y, taskmgr_w, taskmgr_h);
}

fn taskMgrTitlebarHit(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    initTaskMgrPosition(scr_w, scr_h);
    const cap = shellTitlebarH();
    return pointInRectI32(px, py, taskmgr_x, taskmgr_y, taskmgr_w, cap);
}

fn explorerClientRect(scr_w: i32, scr_h: i32) struct { x: i32, y: i32, w: i32, h: i32 } {
    const wr = getWindowRect(scr_w, scr_h);
    return .{
        .x = wr.x + AERO_CLIENT_INSET,
        .y = wr.y + AERO_TITLEBAR_H,
        .w = wr.w - 2 * AERO_CLIENT_INSET,
        .h = wr.h - AERO_TITLEBAR_H - AERO_CLIENT_INSET,
    };
}

/// Aero 壳窗口客户端布局与 renderer_aero.renderExplorerContent 一致。
fn aeroExplorerClientClick(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    const cr = explorerClientRect(scr_w, scr_h);
    if (!pointInRectI32(px, py, cr.x, cr.y, cr.w, cr.h)) return false;
    const lx = px - cr.x;
    const ly = py - cr.y;
    const cmd_h: i32 = AERO_EXPLORER_CMD_H;
    const addr_h: i32 = AERO_EXPLORER_ADDR_H;
    const status_h: i32 = 22;
    const body_top_off: i32 = cmd_h + 1 + addr_h;
    if (ly < body_top_off) return true;
    if (ly >= cr.h - status_h) return true;
    const nav_w = @min(160, @max(100, @divTrunc(cr.w, 4)));
    _ = lx;
    _ = nav_w;
    return true;
}

pub fn handleClick(x: i32, y: i32) bool {
    const panic_ctx = @import("../../rtl/panic_context.zig");
    panic_ctx.setPhase(0x0003_0001);
    defer panic_ctx.setPhase(0);
    const h: i32 = @intCast(fb.getHeight());
    const w: i32 = @intCast(fb.getWidth());

    if (ctx_menu_visible) {
        if (!isInsideContextMenu(x, y)) {
            hideContextMenu();
            return true;
        }
        return handleContextMenuLeftClick(x, y);
    }

    if (isStartButtonClick(x, y, w, h)) {
        toggleStartMenu();
        return true;
    }

    if (startmenu.isVisible()) {
        const menu_r = startmenu.getInteractiveBounds(w, h);
        if (!menu_r.contains(x, y)) {
            startmenu.hide();
            return true;
        }
        const act = startmenu.handleMenuClick(x, y, w, h);
        switch (act) {
            .none => return true,
            .shutdown => {
                startmenu.hide();
                @import("../../arch.zig").shutdown();
            },
            .restart => {
                startmenu.hide();
                @import("../../arch.zig").reset();
            },
            .standby => {
                startmenu.hide();
                klog.info("Start menu: Sleep (standby)", .{});
                @import("../../arch.zig").standby();
            },
            .logoff => {
                startmenu.hide();
                klog.info("Start menu: Log Off (stub)", .{});
                return true;
            },
            .lock_workstation => {
                startmenu.hide();
                klog.info("Start menu: Lock workstation (stub)", .{});
                return true;
            },
            .hibernate => {
                startmenu.hide();
                klog.info("Start menu: Hibernate (stub)", .{});
                return true;
            },
            .switch_user => {
                startmenu.hide();
                klog.info("Start menu: Switch user (stub)", .{});
                return true;
            },
        }
    }

    const tb_h = getTaskbarHeight();
    const tb_y = clampI32FromI64(@as(i64, h) - @as(i64, tb_h));
    if (aero_tray_flyout_visible and y >= tb_y) {
        const hit = aero_tray.hitTest(x, y, w, h, tb_h);
        if (hit == .chevron) {
            aero_tray_flyout_visible = false;
            return true;
        }
        if (hit == .network or hit == .volume or hit == .settings) {
            aero_tray_flyout_visible = false;
            klog.info("Tray: %s", .{switch (hit) {
                .network => "network",
                .volume => "volume",
                .settings => "settings",
                else => "tray",
            }});
            return true;
        }
    }
    if (aero_tray_flyout_visible) {
        const fr = aeroTrayFlyoutRect(w, h);
        if (pointInRectI32(x, y, fr.x, fr.y, fr.w, fr.h)) {
            if (aeroTrayFlyoutPick(x, y, w, h)) |idx| {
                const item = aero_tray_flyout_items[idx];
                if (!(item.len == 3 and item[0] == '-')) {
                    aero_tray_flyout_visible = false;
                    klog.info("Tray flyout: %s", .{item});
                }
            }
            return true;
        }
        aero_tray_flyout_visible = false;
        return true;
    }
    if (y >= tb_y and y < h) {
        if (tryTaskbarRestoreMinimizedWindows(x, y, w, h)) {
            return true;
        }
        const hit = aero_tray.hitTest(x, y, w, h, tb_h);
        if (hit == .chevron) {
            aero_tray_flyout_visible = !aero_tray_flyout_visible;
            return true;
        }
        if (hit == .network or hit == .volume or hit == .settings) {
            klog.info("Tray: %s", .{switch (hit) {
                .network => "network",
                .volume => "volume",
                .settings => "settings",
                else => "tray",
            }});
            return true;
        }
    }

    if (builtin_apps.handleClick(x, y, w, h, getTaskbarHeight())) {
        return true;
    }

    initTaskMgrPosition(w, h);
    if (taskMgrWindowContains(x, y, w, h)) {
        if (taskmgr_shell_state == .normal) {
            const tedge = hitTestFrameResizeEdge(x, y, taskmgr_x, taskmgr_y, taskmgr_w, taskmgr_h);
            if (tedge != .none) {
                taskmgr_edge_resize = tedge;
                return true;
            }
        }
        if (taskMgrTitlebarHit(x, y, w, h)) {
            const cap = shellTitlebarH();
            switch (hitTestAeroCaptionButtons(x, y, taskmgr_x, taskmgr_y, taskmgr_w, cap)) {
                .close => {
                    klog.info("Task Manager: close (stub)", .{});
                    return true;
                },
                .minimize => {
                    taskmgr_shell_state = .minimized;
                    taskmgr_edge_resize = .none;
                    return true;
                },
                .maximize => {
                    if (taskmgr_shell_state == .maximized) {
                        taskmgr_shell_state = .normal;
                        taskmgr_x = taskmgr_restore.x;
                        taskmgr_y = taskmgr_restore.y;
                        taskmgr_w = taskmgr_restore.w;
                        taskmgr_h = taskmgr_restore.h;
                    } else {
                        taskmgr_restore = .{ .x = taskmgr_x, .y = taskmgr_y, .w = taskmgr_w, .h = taskmgr_h };
                        const wa = desktopWorkArea(w, h);
                        taskmgr_x = wa.x;
                        taskmgr_y = wa.y;
                        taskmgr_w = wa.w;
                        taskmgr_h = wa.h;
                        taskmgr_shell_state = .maximized;
                    }
                    return true;
                },
                .none => {
                    if (taskmgr_shell_state == .maximized) return true;
                    taskmgr_drag_active = true;
                    taskmgr_drag_off_x = x - taskmgr_x;
                    taskmgr_drag_off_y = y - taskmgr_y;
                    taskmgr_drag_prev_rect = .{ .x = taskmgr_x, .y = taskmgr_y, .w = taskmgr_w, .h = taskmgr_h };
                    return true;
                },
            }
        }
        return false;
    }
    const wr = getWindowRect(w, h);
    const cap_h = shellTitlebarH();
    if (wr.w > 0 and wr.h > 0 and explorer_shell_state == .normal) {
        const ex_edge = hitTestFrameResizeEdge(x, y, wr.x, wr.y, wr.w, wr.h);
        if (ex_edge != .none) {
            explorer_edge_resize = ex_edge;
            return true;
        }
    }
    if (pointInRectI32(x, y, wr.x, wr.y, wr.w, cap_h)) {
        switch (hitTestAeroCaptionButtons(x, y, wr.x, wr.y, wr.w, cap_h)) {
            .close => {
                klog.info("Explorer: close (stub)", .{});
                return true;
            },
            .minimize => {
                explorer_shell_state = .minimized;
                explorer_edge_resize = .none;
                return true;
            },
            .maximize => {
                if (explorer_shell_state == .maximized) {
                    explorer_shell_state = .normal;
                    window_x = explorer_restore_snap.x;
                    window_y = explorer_restore_snap.y;
                    explorer_custom_frame = explorer_restore_snap.custom;
                    if (explorer_restore_snap.custom) {
                        explorer_frame_w = explorer_restore_snap.w;
                        explorer_frame_h = explorer_restore_snap.h;
                    }
                } else {
                    const dim = explorerFrameDims(w, h);
                    explorer_restore_snap = .{
                        .x = window_x,
                        .y = window_y,
                        .w = dim.w,
                        .h = dim.h,
                        .custom = explorer_custom_frame,
                    };
                    explorer_shell_state = .maximized;
                }
                return true;
            },
            .none => {
                if (explorer_shell_state == .maximized) return true;
                drag_active = true;
                drag_offset_x = x - window_x;
                drag_offset_y = y - window_y;
                explorer_drag_prev_rect = .{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h };
                return true;
            },
        }
    }
    if (pointInRectI32(x, y, wr.x, wr.y, wr.w, wr.h)) {
        if (aeroExplorerClientClick(x, y, w, h)) return true;
    }
    return false;
}

pub fn handleRightClick(x: i32, y: i32) bool {
    const h: i32 = @intCast(fb.getHeight());
    const tb_h = getTaskbarHeight();
    const tb_y = clampI32FromI64(@as(i64, h) - @as(i64, tb_h));

    if (startmenu.isVisible()) {
        startmenu.hide();
        return true;
    }

    if (aero_tray_flyout_visible) {
        aero_tray_flyout_visible = false;
        return true;
    }

    if (y < tb_y) {
        showContextMenu(x, y);
        return true;
    }
    return false;
}

/// 资源管理器窗口拖动：先算理想位置，钳位后若被挡在边缘则重算抓取偏移，避免标题栏与指针「滑脱」。
fn applyExplorerDrag(x: i32, y: i32, scr_w: i32, scr_h: i32) void {
    if (explorer_shell_state != .normal) return;
    if (explorer_edge_resize != .none) return;
    const dim = explorerFrameDims(scr_w, scr_h);
    const pad: i32 = 2;
    const cap = shellTitlebarH();
    const tb = getTaskbarHeight();

    const nx = x - drag_offset_x;
    const ny = y - drag_offset_y;
    const cx = @max(pad, @min(nx, scr_w - pad - dim.w));
    const cy = @max(0, @min(ny, scr_h - tb - cap));
    if (cx != nx or cy != ny) {
        drag_offset_x = x - cx;
        drag_offset_y = y - cy;
    }
    window_x = cx;
    window_y = cy;
}

/// 任务管理器拖动：同上，贴边时保持抓取点与指针一致。
fn applyTaskMgrDrag(x: i32, y: i32, scr_w: i32, scr_h: i32) void {
    if (taskmgr_shell_state != .normal) return;
    if (taskmgr_edge_resize != .none) return;
    const tm_w = taskmgr_w;
    const tm_h = taskmgr_h;
    const pad: i32 = 2;
    const tb = getTaskbarHeight();

    const nx = x - taskmgr_drag_off_x;
    const ny = y - taskmgr_drag_off_y;
    const cx = @max(pad, @min(nx, scr_w - pad - tm_w));
    const cy = @max(pad, @min(ny, scr_h - tb - tm_h - pad));
    if (cx != nx or cy != ny) {
        taskmgr_drag_off_x = x - cx;
        taskmgr_drag_off_y = y - cy;
    }
    taskmgr_x = cx;
    taskmgr_y = cy;
}

/// 鼠标移动对桌面合成的提示：`needs_full_scene` 开始菜单悬停等须整场景；`needs_drag_repaint` 拖窗位移（不计入整场景）；`needs_caption_chrome_only` 仅标题栏带；`cursor_shape_changed` 光标快速路径。
pub const MouseMovePaintHint = struct {
    needs_full_scene: bool = false,
    /// 开始菜单悬停行变化：仅重绘菜单脏区（避免整屏壁纸+毛玻璃）。
    needs_startmenu_repaint: bool = false,
    needs_drag_repaint: bool = false,
    /// 边框拖拽改变 Explorer / 任务管理器几何：走 `renderer_aero.renderFrameEx` 非拖动态全壳层（非 `scene_dirty`）。
    needs_shell_frame_repaint: bool = false,
    /// 左键释放在标题栏拖放结束：同上壳层全帧，但不 `scene_dirty`（不 `cursor_plane.invalidate`）。
    needs_post_drag_composite: bool = false,
    needs_caption_chrome_only: bool = false,
    cursor_shape_changed: bool = false,

    pub fn merge(a: MouseMovePaintHint, b: MouseMovePaintHint) MouseMovePaintHint {
        return .{
            .needs_full_scene = a.needs_full_scene or b.needs_full_scene,
            .needs_startmenu_repaint = a.needs_startmenu_repaint or b.needs_startmenu_repaint,
            .needs_drag_repaint = a.needs_drag_repaint or b.needs_drag_repaint,
            .needs_shell_frame_repaint = a.needs_shell_frame_repaint or b.needs_shell_frame_repaint,
            .needs_post_drag_composite = a.needs_post_drag_composite or b.needs_post_drag_composite,
            .needs_caption_chrome_only = a.needs_caption_chrome_only or b.needs_caption_chrome_only,
            .cursor_shape_changed = a.cursor_shape_changed or b.cursor_shape_changed,
        };
    }
};

pub fn handleMouseMove(x: i32, y: i32) MouseMovePaintHint {
    desktop_ctx.smooth_cursor.target_x = x;
    desktop_ctx.smooth_cursor.target_y = y;

    var startmenu_hover = false;
    if (startmenu.isVisible()) {
        const w: i32 = @intCast(fb.getWidth());
        const h: i32 = @intCast(fb.getHeight());
        startmenu_hover = startmenu.updatePointerHover(x, y, w, h);
    }

    const scr_w: i32 = @intCast(fb.getWidth());
    const scr_h: i32 = @intCast(fb.getHeight());
    const mouse = @import("../input/mouse.zig");
    var shell_geometry_changed = false;
    if (explorer_edge_resize != .none and mouse.isLeftPressed()) {
        shell_geometry_changed = applyExplorerFrameResize(x, y, scr_w, scr_h) or shell_geometry_changed;
    }
    if (taskmgr_edge_resize != .none and mouse.isLeftPressed()) {
        shell_geometry_changed = applyTaskMgrFrameResize(x, y, scr_w, scr_h) or shell_geometry_changed;
    }

    const wx0 = window_x;
    const wy0 = window_y;
    const tmx0 = taskmgr_x;
    const tmy0 = taskmgr_y;

    if (drag_active) {
        applyExplorerDrag(x, y, scr_w, scr_h);
    }
    if (taskmgr_drag_active) {
        initTaskMgrPosition(scr_w, scr_h);
        applyTaskMgrDrag(x, y, scr_w, scr_h);
    }
    const tb_h_move = getTaskbarHeight();
    const builtin_moved = builtin_apps.onMouseMove(x, y, scr_w, scr_h, tb_h_move);
    const explorer_moved = drag_active and (window_x != wx0 or window_y != wy0);
    const taskmgr_moved = taskmgr_drag_active and (taskmgr_x != tmx0 or taskmgr_y != tmy0);

    const prev_expl = explorer_caption_btn_hover;
    const prev_tm = taskmgr_caption_btn_hover;
    explorer_caption_btn_hover = .none;
    taskmgr_caption_btn_hover = .none;
    const wr = getWindowRect(scr_w, scr_h);
    const cap_h = shellTitlebarH();
    initTaskMgrPosition(scr_w, scr_h);
    const tm_w = taskmgr_w;

    // 指针在开始菜单或桌面右键菜单上时，不做顶层窗标题栏三键命中：否则与壳层叠加时热态会抖动，
    // 且旧逻辑曾把「壳层打开 + caption 热态」强升为整场景（每帧全屏毛玻璃），在 UEFI GOP 高分辨率下等同卡死。
    var skip_top_window_caption_hit = false;
    if (startmenu.isVisible()) {
        const sm_r = startmenu.getInteractiveBounds(scr_w, scr_h);
        if (sm_r.contains(x, y)) skip_top_window_caption_hit = true;
    }
    if (ctx_menu_visible and isInsideContextMenu(x, y)) skip_top_window_caption_hit = true;

    if (skip_top_window_caption_hit) {
        // 保持 .none，依赖 startmenu / context 局部重绘路径。
    } else if (builtin_apps.captionHoverForTopmost(x, y) != .none) {
        explorer_caption_btn_hover = .none;
        taskmgr_caption_btn_hover = .none;
    } else if (taskMgrWindowContains(x, y, scr_w, scr_h) and taskMgrTitlebarHit(x, y, scr_w, scr_h)) {
        // 任务管理器盖住 Explorer 时，标题栏命中优先算顶层窗。
        taskmgr_caption_btn_hover = hitTestAeroCaptionButtonsHysteresis(x, y, taskmgr_x, taskmgr_y, tm_w, cap_h, prev_tm);
    } else if (pointInRectI32(x, y, wr.x, wr.y, wr.w, cap_h)) {
        explorer_caption_btn_hover = hitTestAeroCaptionButtonsHysteresis(x, y, wr.x, wr.y, wr.w, cap_h, prev_expl);
    }
    const caption_hover_changed = prev_expl != explorer_caption_btn_hover or prev_tm != taskmgr_caption_btn_hover;

    const startmenu_hover_changed = startmenu_hover;
    const needs_startmenu_repaint = startmenu.isVisible() and startmenu_hover_changed;
    const needs_drag_repaint = explorer_moved or taskmgr_moved or builtin_moved;
    // 开始菜单/托盘飞出打开时仍允许 `caption_chrome_only`：`redrawCaptionBandsOnly` 会重画上下文菜单；
    // 勿再因「壳层 + caption 热态」强升整场景（NT 6.1 风格 DWM 在 CPU 上的致命路径）。
    const needs_caption_chrome_only = caption_hover_changed and !explorer_moved and !taskmgr_moved and !startmenu_hover_changed and !shell_geometry_changed;

    const prev_kind = desktop_cursor_kind;
    updateDesktopCursorKind(x, y, prev_kind);
    const cursor_shape_changed = prev_kind != desktop_cursor_kind;

    maybeRefreshExplorerTaskbarThumb(x, y, scr_w, scr_h);

    return .{
        .needs_full_scene = false,
        .needs_startmenu_repaint = needs_startmenu_repaint,
        .needs_drag_repaint = needs_drag_repaint,
        .needs_shell_frame_repaint = shell_geometry_changed,
        .needs_post_drag_composite = false,
        .needs_caption_chrome_only = needs_caption_chrome_only,
        .cursor_shape_changed = cursor_shape_changed,
    };
}

/// `expand_each_side > 0`：地址栏命中区各边外扩（迟滞「保持 I-beam」）；`< 0`：内缩（迟滞「进入 I-beam」）。
fn pointInExplorerAddressBarEx(px: i32, py: i32, scr_w: i32, scr_h: i32, expand_each_side: i32) bool {
    const wr = getWindowRect(scr_w, scr_h);
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    const rx = @as(i64, wr.x);
    const ry = @as(i64, wr.y);
    const rw = @as(i64, wr.w);
    const rh = @as(i64, wr.h);
    if (pxi < rx or pyi < ry or pxi >= rx + rw or pyi >= ry + rh) return false;
    const cx: i64 = rx + 2;
    const cy: i64 = ry + AERO_TITLEBAR_H;
    const cw: i64 = rw - 4;
    const cmd_h: i64 = AERO_EXPLORER_CMD_H;
    const addr_h: i64 = AERO_EXPLORER_ADDR_H;
    const addr_y = cy + cmd_h + 1;
    const e = @as(i64, expand_each_side);

    if (explorer_shell_view_state == .libraries) {
        const search_w = @as(i64, AERO_EXPLORER_LIB_SEARCH_W);
        const search_x = cx + cw - 8 - search_w;
        const bread_left = cx + @as(i64, AERO_EXPLORER_LIB_ADDR_FIELD_X);
        var addr_field_x: i64 = bread_left;
        var addr_field_w: i64 = @max(@as(i64, 48), search_x - 4 - addr_field_x);
        var ady: i64 = addr_y;
        var adh: i64 = addr_h;
        var sx: i64 = search_x;
        var sw: i64 = search_w;
        addr_field_x -= e;
        addr_field_w += 2 * e;
        ady -= e;
        adh += 2 * e;
        sx -= e;
        sw += 2 * e;
        const in_bread = pxi >= addr_field_x and pxi < addr_field_x + addr_field_w and pyi >= ady and pyi < ady + adh;
        const in_search = pxi >= sx and pxi < sx + sw and pyi >= ady and pyi < ady + adh;
        return in_bread or in_search;
    }

    const go_x = cx + cw - @as(i64, AERO_EXPLORER_GO_MARGIN_END) - @as(i64, AERO_EXPLORER_GO_BTN_W);
    var addr_field_x: i64 = cx + 52;
    var addr_field_w: i64 = @max(@as(i64, 64), go_x - 4 - addr_field_x);
    var ady: i64 = addr_y;
    var adh: i64 = addr_h;
    addr_field_x -= e;
    addr_field_w += 2 * e;
    ady -= e;
    adh += 2 * e;
    if (addr_field_w < 8 or adh < 4) return false;
    return pxi >= addr_field_x and pxi < addr_field_x + addr_field_w and pyi >= ady and pyi < ady + adh;
}

fn pointInExplorerAddressBarHysteresis(px: i32, py: i32, scr_w: i32, scr_h: i32, was_ibeam: bool) bool {
    // 略不对称：退出 I-beam 时多留 1px 包络，减少边界上箭头/I-beam 每帧翻转带来的 `cursor_shape_changed` 抖动。
    const expand_each_side: i32 = if (was_ibeam) 3 else -1;
    return pointInExplorerAddressBarEx(px, py, scr_w, scr_h, expand_each_side);
}

fn updateDesktopCursorKind(px: i32, py: i32, prev_kind: aero_cursor_shape.CursorKind) void {
    if (isWindowDragging()) {
        desktop_cursor_kind = .move;
        return;
    }
    const scr_w: i32 = @intCast(fb.getWidth());
    const scr_h: i32 = @intCast(fb.getHeight());
    if (startmenu.isVisible() and startmenu.pointerHoverIndex() >= 0) {
        desktop_cursor_kind = .hand;
        return;
    }
    if (builtin_apps.captionHoverForTopmost(px, py) != .none) {
        desktop_cursor_kind = .hand;
        return;
    }
    if (pointInExplorerAddressBarHysteresis(px, py, scr_w, scr_h, prev_kind == .ibeam)) {
        desktop_cursor_kind = .ibeam;
        return;
    }
    if (explorer_caption_btn_hover != .none or taskmgr_caption_btn_hover != .none) {
        desktop_cursor_kind = .hand;
        return;
    }
    desktop_cursor_kind = .arrow;
}

/// 拖动资源管理器或任务管理器标题栏时，仅在指针实际移动时需要重绘（见 main 循环）。
pub fn isWindowDragging() bool {
    return drag_active or taskmgr_drag_active or builtin_apps.isDragging();
}

/// 左键释放：`needs_full_scene` 与 `MouseMovePaintHint.needs_full_scene` 合并后驱动 `scene_dirty`；`needs_post_drag_composite` 仅壳层全帧、不 invalidate。
pub const MouseReleasePaintHint = struct {
    needs_full_scene: bool = false,
    needs_post_drag_composite: bool = false,
};

/// 边框缩放结束须 `scene_dirty`（`invalidate`）；仅标题栏拖放结束用 `needs_post_drag_composite`，避免松手整屏 save-under 失效导致卡顿。
pub fn handleMouseRelease() MouseReleasePaintHint {
    const was_explorer = drag_active;
    const was_taskmgr = taskmgr_drag_active;
    const was_resize = (explorer_edge_resize != .none) or (taskmgr_edge_resize != .none);
    drag_active = false;
    taskmgr_drag_active = false;
    explorer_edge_resize = .none;
    taskmgr_edge_resize = .none;
    const was_builtin_drag = builtin_apps.onMouseRelease();
    const drag_shell = was_explorer or was_taskmgr or was_builtin_drag;
    return .{
        .needs_full_scene = was_resize,
        .needs_post_drag_composite = drag_shell and !was_resize,
    };
}

pub fn renderAeroDesktop() void {
    dwm_mod.beginFrameBlurBudget();
    syncAeroGlassFastPath();
    renderer_aero.renderFrameEx(false);
    cursor_plane.composeAfterScene(desktop_ctx.cursor_visible, desktop_ctx.cursor_x, desktop_ctx.cursor_y, desktop_cursor_kind, renderCursor);
    dwm_mod.flushBlurFrameStatsDebug();
}

/// Harmony-style wallpaper (Zircon brand: deep blue + soft bloom + edge vignette; Aero 7 氛围)
fn renderHarmonyStyleWallpaper(w: i32, h: i32) void {
    fb.drawGradientV(0, 0, w, h, rgb(0x08, 0x1E, 0x42), rgb(0x04, 0x12, 0x28));
    fb.blendTintRect(@divTrunc(w, 4), @divTrunc(h, 10), @divTrunc(w, 2), @divTrunc(h * 2, 5), rgb(0x28, 0x58, 0x90), 20, 255);
    const mx = @divTrunc(w, 2);
    const my = @divTrunc(h * 2, 5);
    fb.blendTintRect(mx - 200, my - 130, 400, 300, rgb(0x38, 0x68, 0xA0), 16, 255);
    // 次要光晕（Harmony 壁纸预设常见：中上偏左的淡青高光）
    fb.blendTintRect(@divTrunc(w, 8), @divTrunc(h, 6), @divTrunc(w, 3), @divTrunc(h, 4), rgb(0x50, 0x78, 0xA8), 12, 255);
    // 四边暗角，增强景深与任务栏玻璃对比
    const vstrip: i32 = 28;
    fb.blendTintRect(0, 0, w, vstrip, rgb(0x00, 0x04, 0x12), 38, 255);
    fb.blendTintRect(0, clampI32FromI64(@as(i64, h) - @as(i64, vstrip)), w, vstrip, rgb(0x00, 0x02, 0x0A), 48, 255);
    fb.blendTintRect(0, 0, vstrip, h, rgb(0x00, 0x04, 0x10), 32, 255);
    fb.blendTintRect(clampI32FromI64(@as(i64, w) - @as(i64, vstrip)), 0, vstrip, h, rgb(0x00, 0x04, 0x10), 32, 255);
}

fn renderAeroBackground(w: i32, h: i32, t: *const ThemeColors) void {
    _ = t;
    renderHarmonyStyleWallpaper(w, h);
}

/// Aero 任务栏唯一绘制入口（`renderer_aero` 全帧与壳层共用，避免两套像素分叉）。
pub fn renderDesktopAeroTaskbar(scr_w: i32, scr_h: i32, t: *const ThemeColors, tb_h: i32) void {
    const panic_ctx = @import("../../rtl/panic_context.zig");
    const tb_y = clampI32FromI64(@as(i64, scr_h) - @as(i64, tb_h));
    taskmgr_tray_chip_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const drag_fast = isDragging();

    panic_ctx.setPhase(0x0002_0090);
    if (drag_fast) {
        fb.drawGradientV(0, tb_y, scr_w, tb_h, t.taskbar_top, t.taskbar_bottom);
    } else if (dwm_initialized and dwm_config.glass_enabled) {
        // 任务栏全宽 × 多遍 boxBlur 在宽屏（如 1600px）下 CPU 昂贵，且盒式模糊内层在部分边界组合下易触发 Debug 整数异常。
        // 条带视觉以 tint + 高光 + chrome 为主；全场景磨砂感仍可由壁纸/标题栏等路径承担。
        renderGlassTintOnly(0, tb_y, scr_w, tb_h, rgb(0x34, 0x52, 0x72), .taskbar);
    } else {
        fb.drawGradientV(0, tb_y, scr_w, tb_h, t.taskbar_top, t.taskbar_bottom);
    }
    fb.drawHLine(0, tb_y, scr_w, rgb(0xB0, 0xD0, 0xF0));
    const tb_y_line2 = clampI32FromI64(@as(i64, tb_y) + 1);
    fb.drawHLine(0, tb_y_line2, scr_w, rgb(0x40, 0x5C, 0x78));

    const peek_w: i32 = aero_tray.TASKBAR_PEEK_STRIP_W;
    const icon_s: u32 = 2;
    const icon_px: i32 = icons.getIconTotalSize(icon_s);
    const icon_s_apps: u32 = 1;
    const app_icon_px: i32 = icons.getIconTotalSize(icon_s_apps);
    const tile: i32 = 34;
    const pill_h: i32 = tile;

    panic_ctx.setPhase(0x0002_0091);
    const orb = aeroTaskbarStartOrb(tb_y, tb_h);
    // 阴影 + 球体 + 高光（Aero 玻璃球体感）
    const orb_cy1 = clampI32FromI64(@as(i64, orb.cy) + 1);
    const orb_r1 = clampI32FromI64(@as(i64, orb.r) + 1);
    fb.fillCircle(orb.cx, orb_cy1, orb_r1, rgb(0x04, 0x12, 0x28));
    fb.fillCircle(orb.cx, orb.cy, orb_r1, rgb(0x10, 0x2C, 0x50));
    fb.fillCircle(orb.cx, orb.cy, orb.r, rgb(0x1C, 0x44, 0x78));
    const orb_sheen_r = @max(0, orb.r - 1);
    fb.aeroSheenDisk(orb.cx, orb.cy, orb_sheen_r, rgb(0xF4, 0xFA, 0xFF));
    renderZirconLogo(clampI32FromI64(@as(i64, orb.cx) - 7), clampI32FromI64(@as(i64, orb.cy) - 7));

    panic_ctx.setPhase(0x0002_0092);
    const ql_ids = [_]icons.IconId{ .browser, .terminal, .documents };
    var qx: i32 = clampI32FromI64(@as(i64, orb.slot_w) + 6);
    const ql_y = clampI32FromI64(@as(i64, tb_y) + @divTrunc(@as(i64, tb_h) - @as(i64, icon_px), 2));
    const ql_pad: i32 = 3;
    for (ql_ids) |iid| {
        const bg_w = clampI32FromI64(@as(i64, icon_px) + 2 * @as(i64, ql_pad));
        const bg_h = clampI32FromI64(@as(i64, icon_px) + 2 * @as(i64, ql_pad));
        const bg_x = clampI32FromI64(@as(i64, qx) - @as(i64, ql_pad));
        const bg_y = clampI32FromI64(@as(i64, ql_y) - @as(i64, ql_pad));
        const bg_ix = clampI32FromI64(@as(i64, bg_x) + 1);
        const bg_iy = clampI32FromI64(@as(i64, bg_y) + 1);
        const bg_iw = @max(0, clampI32FromI64(@as(i64, bg_w) - 2));
        const bg_ih_grad = @max(1, clampI32FromI64(@as(i64, bg_h) - 3));
        fb.fillRoundedRect(bg_x, bg_y, bg_w, bg_h, 6, rgb(0x16, 0x2A, 0x42));
        fb.drawGradientV(bg_ix, bg_iy, bg_iw, bg_ih_grad, rgb(0x42, 0x5E, 0x82), rgb(0x12, 0x22, 0x36));
        const tint_h_ql: i32 = @max(0, @as(i32, @intCast(@divTrunc(@as(i64, bg_h) - 2, 2))));
        fb.blendTintRect(bg_ix, bg_iy, bg_iw, tint_h_ql, rgb(0xA8, 0xD0, 0xF5), 45, 170);
        fb.drawRect(bg_x, bg_y, bg_w, bg_h, rgb(0x58, 0x7C, 0xA0));
        icons.drawThemedIcon(iid, qx, ql_y, icon_s, .aero);
        qx = clampI32FromI64(@as(i64, qx) + @as(i64, icon_px) + 2 * @as(i64, ql_pad) + 6);
    }
    const vline_x = clampI32FromI64(@as(i64, qx) + 2);
    const vline_y = clampI32FromI64(@as(i64, tb_y) + 6);
    const vline_len = @max(0, clampI32FromI64(@as(i64, tb_h) - 12));
    fb.drawVLine(vline_x, vline_y, vline_len, rgb(0x58, 0x78, 0x98));

    panic_ctx.setPhase(0x0002_0093);
    const app_items = [_]struct { id: icons.IconId, active: bool }{
        .{ .id = .computer, .active = true },
        .{ .id = .folder, .active = false },
        .{ .id = .terminal, .active = false },
    };
    var ax = clampI32FromI64(@as(i64, qx) + 8);
    const ay = clampI32FromI64(@as(i64, tb_y) + @divTrunc(@as(i64, tb_h) - @as(i64, pill_h), 2));
    const pill_r: i32 = 8;
    for (app_items) |app| {
        const pill_inner_x = clampI32FromI64(@as(i64, ax) + 2);
        const pill_inner_y = clampI32FromI64(@as(i64, ay) + 2);
        const pill_inner_w = @max(0, clampI32FromI64(@as(i64, tile) - 4));
        const pill_inner_h = @max(0, clampI32FromI64(@as(i64, pill_h) - 4));
        if (app.active) {
            fb.fillRoundedRect(ax, ay, tile, pill_h, pill_r, rgb(0x38, 0x5C, 0x88));
            fb.drawGradientV(pill_inner_x, pill_inner_y, pill_inner_w, pill_inner_h, rgb(0x82, 0xB0, 0xE0), rgb(0x38, 0x5C, 0x88));
            const tint_h_act: i32 = @max(0, @as(i32, @intCast(@divTrunc(@as(i64, pill_h) - 4, 2))));
            fb.blendTintRect(pill_inner_x, pill_inner_y, pill_inner_w, tint_h_act, rgb(0xE0, 0xF2, 0xFF), 50, 200);
            fb.drawRect(ax, ay, tile, pill_h, rgb(0xA0, 0xCC, 0xF0));
        } else {
            fb.fillRoundedRect(ax, ay, tile, pill_h, pill_r, rgb(0x1A, 0x2E, 0x46));
            fb.drawGradientV(pill_inner_x, pill_inner_y, pill_inner_w, pill_inner_h, rgb(0x3A, 0x54, 0x72), rgb(0x12, 0x20, 0x34));
            const tint_h_inact: i32 = @max(0, @as(i32, @intCast(@divTrunc(@as(i64, pill_h) - 4, 2))));
            fb.blendTintRect(pill_inner_x, pill_inner_y, pill_inner_w, tint_h_inact, rgb(0x88, 0xB0, 0xD8), 38, 160);
            fb.drawRect(ax, ay, tile, pill_h, rgb(0x46, 0x64, 0x84));
        }
        const ix = clampI32FromI64(@as(i64, ax) + @divTrunc(@as(i64, tile) - @as(i64, app_icon_px), 2));
        const iy = clampI32FromI64(@as(i64, ay) + @divTrunc(@as(i64, pill_h) - @as(i64, app_icon_px), 2));
        icons.drawThemedIcon(app.id, ix, iy, icon_s_apps, .aero);
        ax = clampI32FromI64(@as(i64, ax) + @as(i64, tile) + 5);
    }

    if (taskmgr_shell_state == .minimized) {
        const chip_x = clampI32FromI64(@as(i64, ax) + 6);
        const chip_w: i32 = 78;
        const chip_y = ay;
        const chip_h = pill_h;
        const chip_right = @as(i64, chip_x) + @as(i64, chip_w);
        const chip_limit = @as(i64, scr_w) - @as(i64, peek_w) - 80;
        if (chip_right < chip_limit) {
            fb.fillRoundedRect(chip_x, chip_y, chip_w, chip_h, pill_r, rgb(0x30, 0x50, 0x78));
            fb.drawRect(chip_x, chip_y, chip_w, chip_h, rgb(0xA0, 0xCC, 0xF0));
            const chip_ty = clampI32FromI64(@as(i64, chip_y) + @divTrunc(@as(i64, pill_h) - 14, 2));
            fb.drawTextTransparentUi(clampI32FromI64(@as(i64, chip_x) + 6), chip_ty, "TaskMgr", rgb(0xE8, 0xF0, 0xFF));
            taskmgr_tray_chip_rect = .{ .x = chip_x, .y = chip_y, .w = chip_w, .h = chip_h };
        }
    }

    panic_ctx.setPhase(0x0002_0094);
    const tray = aero_tray.layout(scr_w, scr_h, tb_h);
    if (tray.shelf_w > 4 and tray.shelf_h > 4) {
        fb.fillRoundedRect(tray.shelf_x, tray.shelf_y, tray.shelf_w, tray.shelf_h, 6, rgb(0x18, 0x28, 0x3C));
        fb.blendTintRect(tray.shelf_x, tray.shelf_y, tray.shelf_w, tray.shelf_h, rgb(0x78, 0x98, 0xB8), 28, 120);
        fb.drawRect(tray.shelf_x, tray.shelf_y, tray.shelf_w, tray.shelf_h, rgb(0x50, 0x70, 0x90));
    }
    icons.drawThemedIcon(.network, tray.net_x, tray.tray_icons_y, tray.icon_s, .aero);
    icons.drawThemedIcon(.browser, tray.vol_x, tray.tray_icons_y, tray.icon_s, .aero);
    icons.drawThemedIcon(.settings, tray.set_x, tray.tray_icons_y, tray.icon_s, .aero);
    fb.drawTextTransparentUi(tray.chevron_x, tray.chevron_y, "^", rgb(0xC0, 0xD8, 0xF0));

    const line_time = "12:00 PM";
    const line_date = "2026/3/21";
    const line_h_clk: i32 = 14;
    fb.drawTextTransparentUi(tray.clk_x, tray.clk_y, line_time, t.clock_text);
    const date_y = clampI32FromI64(@as(i64, tray.clk_y) + @as(i64, line_h_clk) + 1);
    fb.drawTextTransparentUi(tray.clk_x, date_y, line_date, rgb(0xE0, 0xEC, 0xF8));

    panic_ctx.setPhase(0x0002_0095);
    renderAeroTrayFlyout(scr_w, scr_h);

    panic_ctx.setPhase(0x0002_0096);
    const peek_x = clampI32FromI64(@as(i64, scr_w) - @as(i64, peek_w));
    fb.drawGradientV(peek_x, tb_y, peek_w, tb_h, rgb(0x68, 0x88, 0xA8), rgb(0x30, 0x48, 0x64));
    fb.drawVLine(peek_x, tb_y, tb_h, rgb(0x90, 0xB0, 0xD0));
    const right_rail_x = clampI32FromI64(@as(i64, scr_w) - 1);
    fb.drawVLine(right_rail_x, tb_y, tb_h, rgb(0x20, 0x30, 0x44));
    paintExplorerTaskbarThumbnailPreview(scr_w, scr_h);
}

pub fn initAeroDwm() void {
    if (!dwm_initialized) {
        // DesktopManagerSpec.md §8：backdrop → 盒式模糊（多遍≈高斯）→ blendTint 染色 → 顶区高光。
        // 任务栏全宽但高度小，renderGlassEffect 内对 .taskbar 使用较小半径 + 1 遍。
        // present() 在 Aero 下整帧 flip，减轻指针移动时与 flipDirty 矩形顺序相关的块状撕裂。
        // 半径×遍数过大时首帧会长时间阻塞，双缓冲下在首次 flip 前屏幕可能一直黑屏或旧内容。
        // 默认用较轻模糊（仍可见毛玻璃），需要画质再调大 glass_blur_*。
        const cfg = DwmConfig{};
        initDwm(cfg);
        klog.debug("AeroDWM: compositor_config_epoch=%u (config handshake trace)", .{dwm_mod.compositor_config_epoch});

        dwm_mod.init(cfg);
        dwm_mod.syncPolicyFromRegistry();
        if (fb.isInitialized()) {
            dwm_mod.applyPlatformAndResolutionTuning(fb.getWidth(), fb.getHeight());
        }
        const tuned = dwm_mod.getConfig().*;
        dwm_config = tuned;
        desktop_ctx.dwm_active = tuned.composition_enabled and tuned.glass_enabled;

        mat.init(.glass);
        mat.configureGlass(.{
            .blur_radius = tuned.glass_blur_radius,
            .blur_passes = tuned.glass_blur_passes,
            .tint_color = tuned.glass_tint_color,
            .tint_opacity = tuned.glass_tint_opacity,
            .saturation = tuned.glass_saturation,
            .specular_intensity = tuned.specular_intensity,
        });

        dwm_comp.initAero(.{});

        const hz = config.getTickRateHz();
        dwm_comp.thumb_refresh_min_ticks = @max(4, (hz *% 120) / 1000);
        virtio_gpu_pci.bringupMmioIfProbed();
        // 可选 GPU 路径：VirtIO 2D scratch 与帧缓冲子矩形恒等往返（失败仅打日志，合成仍走 CPU）。
        if (fb.isInitialized() and virtio_gpu_pci.compositorOffloadAvailable()) {
            const w = @min(@as(u32, 4), fb.getWidth());
            const h = @min(@as(u32, 4), fb.getHeight());
            if (w > 0 and h > 0) {
                if (virtio_gpu_pci.compositorTryRoundTripFramebufferRect(0, 0, w, h)) {
                    klog.info("VirtIO-GPU: display ↔ scratch TRANSFER round-trip ok ({d}×{d})", .{ w, h });
                } else {
                    klog.warn("VirtIO-GPU: display ↔ scratch round-trip failed (CPU compositor only; check 32bpp)", .{});
                }
            }
        }
    }
}

// ── Desktop Window Manager (DWM) Compositor ──
// 默认字段来自 `nt61_aero_defaults`（经 `dwm_mod.DwmConfig`）

pub const DwmConfig = dwm_mod.DwmConfig;

/// Chrome drawn after blur+tint (taskbar has side rails; caption only divider to client)
pub const GlassChrome = dwm_mod.GlassChrome;

var dwm_config: DwmConfig = .{};
var dwm_initialized: bool = false;

pub fn initDwm(cfg: DwmConfig) void {
    dwm_config = cfg;
    dwm_initialized = true;
    desktop_ctx.dwm_active = cfg.composition_enabled and cfg.glass_enabled;
    desktop_ctx.smooth_cursor.lerp_factor = cfg.cursor_lerp_factor;
}

pub fn isDwmEnabled() bool {
    return dwm_initialized and dwm_config.composition_enabled;
}

pub fn getDwmConfig() *const DwmConfig {
    return &dwm_config;
}

pub fn setDwmGlass(enabled: bool) void {
    dwm_mod.setGlass(enabled);
    dwm_config = dwm_mod.getConfig().*;
    desktop_ctx.dwm_active = dwm_config.composition_enabled and dwm_config.glass_enabled;
}

pub fn setSmoothCursorFactor(factor: i32) void {
    desktop_ctx.smooth_cursor.lerp_factor = if (factor < 64) 64 else if (factor > 255) 255 else factor;
}

/// Aero Glass（NT 6.1 DWM 概念）: 委托 `dwm.zig`（每帧模糊预算、`glass_lite`、任务栏半径上限与 `nt61_aero_defaults` 一致）。
pub fn renderGlassEffect(x: i32, y: i32, w: i32, h: i32, tint: color_nt61.KernelBgr888Low24, chrome: GlassChrome) void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    if (!dwm_initialized or !dwm_config.glass_enabled) {
        fb.fillRect(x, y, w, h, if (tint != 0) tint else dwm_config.glass_tint_color);
        return;
    }
    dwm_mod.renderGlassEffect(x, y, w, h, tint, chrome);
}

/// 无盒式模糊（小菜单、拖窗标题栏等）；仍走 tint + 高光 + `GlassChrome` 边框。
pub fn renderGlassTintOnly(x: i32, y: i32, w: i32, h: i32, tint: color_nt61.KernelBgr888Low24, chrome: GlassChrome) void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    if (!dwm_initialized or !dwm_config.glass_enabled) {
        fb.fillRect(x, y, w, h, if (tint != 0) tint else dwm_config.glass_tint_color);
        return;
    }
    dwm_mod.renderGlassTintOnly(x, y, w, h, tint, chrome);
}

pub fn renderAeroGlassBar(x: i32, y: i32, w: i32, h: i32) void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    const t = active_theme;

    if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassEffect(x, y, w, h, dwm_config.glass_tint_color, .taskbar);
        fb.drawHLine(x, y, w, t.tray_border);
    } else {
        fb.drawGradientV(x, y, w, h, t.taskbar_top, t.taskbar_bottom);
        fb.drawHLine(x, y, w, t.tray_border);
    }
}

pub fn renderAeroTitlebar(x: i32, y: i32, w: i32, h: i32, is_active: bool) void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    const t = active_theme;

    if (dwm_initialized and dwm_config.glass_enabled and is_active) {
        renderGlassEffect(x, y, w, h, t.titlebar_active_left, .caption);
    } else if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassEffect(x, y, w, h, rgb(0x80, 0x90, 0xA0), .caption);
    } else {
        fb.drawGradientH(x, y, w, h, t.titlebar_active_left, t.titlebar_active_right);
    }
}

pub fn renderShadow(x: i32, y: i32, w: i32, h: i32, size: i32) void {
    if (!use_framebuffer or !dwm_config.shadow_enabled) return;
    if (size <= 0) return;

    // Multi-layer soft shadow with true alpha blending: each successive
    // layer has a smaller offset and decreasing opacity for soft edges.
    var layer: i32 = 0;
    while (layer < 4) : (layer += 1) {
        const offset = size - layer * 2;
        if (offset <= 0) break;
        // Darken the existing background by a small alpha (outer = darker, inner = lighter)
        const shadow_alpha: u8 = @intCast(@as(u32, @intCast(25 - layer * 5)));
        fb.blendTintRect(
            clampI32FromI64(@as(i64, x) + @as(i64, offset)),
            clampI32FromI64(@as(i64, y) + @as(i64, offset)),
            w,
            h,
            rgb(0x00, 0x00, 0x00),
            shadow_alpha,
            255,
        );
    }
}

// ── Desktop Background ──

pub fn renderDesktopBackground(color: u32) void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    desktop_ctx.background_color = color;
    fb.clearScreen(color);
}

// ── Desktop Icons (with pixel art) ──

const IconDef = struct {
    label: []const u8,
    id: icons.IconId,
    shortcut: bool = false,
};

const desktop_icon_list_aero = [_]IconDef{
    .{ .label = "Computer", .id = .computer },
    .{ .label = "Recycle Bin", .id = .recycle_bin },
    .{ .label = "Documents", .id = .documents },
    .{ .label = "Network", .id = .network },
    .{ .label = "Control Panel", .id = .control_panel, .shortcut = true },
    .{ .label = "Browser", .id = .browser, .shortcut = true },
    .{ .label = "Terminal", .id = .terminal, .shortcut = true },
    .{ .label = "Calculator", .id = .calculator },
    .{ .label = "User", .id = .user, .shortcut = true },
};

pub fn renderDesktopIcons(scr_w: i32, scr_h: i32, t: *const ThemeColors) void {
    _ = scr_w;
    const base_x: i32 = 20;
    var base_y: i32 = 16;
    const avail_h: i32 = clampI32FromI64(@as(i64, scr_h) - @as(i64, getTaskbarHeight()) - 16);
    const icon_scale: u32 = 2;

    const icon_style: icons.ThemeStyle = .aero;
    const icon_defs: []const IconDef = desktop_icon_list_aero[0..];

    for (icon_defs) |icon_def| {
        if (base_y + ICON_GRID_Y > avail_h) break;
        renderOneIcon(base_x, base_y, icon_def, icon_scale, t, icon_style);
        base_y += ICON_GRID_Y;
    }
}

fn getActiveIconStyle() icons.ThemeStyle {
    return .aero;
}

pub fn drawThemedIconForActiveTheme(id: icons.IconId, x: i32, y: i32, scale: u32) void {
    icons.drawThemedIcon(id, x, y, scale, getActiveIconStyle());
}

fn renderOneIcon(x: i32, y: i32, icon_def: IconDef, scale: u32, t: *const ThemeColors, style: icons.ThemeStyle) void {
    const icon_drawn_size = icons.getIconTotalSize(scale);
    const ix = x + @divTrunc(ICON_GRID_X - icon_drawn_size, 2);
    const iy = y;

    icons.drawThemedIcon(icon_def.id, ix, iy, scale, style);

    if (icon_def.shortcut) {
        const ax = ix + icon_drawn_size - 10;
        const ay = iy + icon_drawn_size - 9;
        fb.drawHLine(ax, ay + 6, 7, t.icon_text);
        fb.drawVLine(ax + 6, ay, 7, t.icon_text);
        fb.drawHLine(ax + 4, ay, 3, t.icon_text);
    }

    const label = icon_def.label;
    const label_w = fb.textWidth(label);
    const tx = x + @divTrunc(ICON_GRID_X - label_w, 2);
    const ty = iy + icon_drawn_size + 4;

    fb.drawTextTransparent(tx + 1, ty + 1, label, t.icon_text_shadow);
    fb.drawTextTransparent(tx, ty, label, t.icon_text);
}

// ── Taskbar ──

fn renderTaskbar(scr_w: i32, scr_h: i32, t: *const ThemeColors) void {
    const tb_y = scr_h - TASKBAR_H;

    if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassEffect(0, tb_y, scr_w, TASKBAR_H, dwm_config.glass_tint_color, .taskbar);
    } else {
        fb.drawGradientV(0, tb_y, scr_w, TASKBAR_H, t.taskbar_top, t.taskbar_bottom);
    }
    fb.drawHLine(0, tb_y, scr_w, t.tray_border);

    renderStartButton(0, tb_y, START_BTN_W, TASKBAR_H, t);
    renderSystemTray(scr_w, tb_y, t);
}

fn renderStartButton(x: i32, y: i32, w: i32, h: i32, t: *const ThemeColors) void {
    fb.fillRoundedRect(x + 1, y + 1, w, h - 1, 6, t.start_btn_bottom);
    fb.fillRoundedRect(x, y, w, h - 1, 6, t.start_btn_top);
    fb.drawGradientV(x + 6, y + 2, w - 12, h - 4, t.start_btn_top, t.start_btn_bottom);

    renderZirconLogo(x + 8, y + 7);

    fb.drawTextTransparent(x + 28, y + 7, t.start_label, t.start_btn_text);
}

pub fn renderZirconLogo(x: i32, y: i32) void {
    const blue = rgb(0x3F, 0xA3, 0xD8);
    const dark = rgb(0x0A, 0x3A, 0x6A);
    const white = rgb(0xFF, 0xFF, 0xFF);
    fb.fillRect(x, y, 14, 14, blue);
    fb.fillRect(clampI32FromI64(@as(i64, x) + 1), clampI32FromI64(@as(i64, y) + 1), 12, 12, dark);
    fb.drawHLine(clampI32FromI64(@as(i64, x) + 3), clampI32FromI64(@as(i64, y) + 3), 8, white);
    var i: i32 = 0;
    while (i < 8) : (i += 1) {
        const pxi = @as(i64, x) + 10 - @as(i64, i);
        const pyi = @as(i64, y) + 4 + @as(i64, i);
        const pxc = clampI32FromI64(pxi);
        const pyc = clampI32FromI64(pyi);
        if (pxc >= 0 and pyc >= 0) {
            fb.putPixel32(@intCast(pxc), @intCast(pyc), white);
        }
    }
    fb.drawHLine(clampI32FromI64(@as(i64, x) + 3), clampI32FromI64(@as(i64, y) + 11), 8, white);
}

fn renderSystemTray(scr_w: i32, tb_y: i32, t: *const ThemeColors) void {
    const tray_w: i32 = TRAY_CLOCK_W + 40;
    const tray_x = scr_w - tray_w;
    const tray_y = tb_y + @divTrunc(TASKBAR_H - TRAY_H, 2);

    fb.fillRect(tray_x, tray_y, tray_w, TRAY_H, t.tray_bg);
    fb.drawVLine(tray_x, tray_y, TRAY_H, t.tray_border);

    fb.drawTextTransparent(tray_x + 8, tray_y + 3, "12:00 PM", t.clock_text);
}

// ── Windows 2000 Classic: Explorer + Task Manager (kernel-rendered shell) ──

var taskmgr_x: i32 = 0;
var taskmgr_y: i32 = 0;
var taskmgr_placed: bool = false;
var taskmgr_drag_active: bool = false;
var taskmgr_drag_off_x: i32 = 0;
var taskmgr_drag_off_y: i32 = 0;
var taskmgr_shell_state: ShellWindowState = .normal;
var taskmgr_w: i32 = 320;
var taskmgr_h: i32 = 260;
var taskmgr_restore: struct { x: i32, y: i32, w: i32, h: i32 } = .{ .x = 0, .y = 0, .w = 320, .h = 260 };
/// 任务管理器最小化时任务栏上的可点击恢复条带（每帧由 `renderDesktopAeroTaskbar` 更新）。
var taskmgr_tray_chip_rect: ShellRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// 资源管理器导航：C: 根（大图标）、WINNT\\System32 详细列表、单文件浏览页。
const W2kExLoc = enum { c_drive, c_winnt_system32, file_page };
var explorer_w2k_loc: W2kExLoc = .c_drive;
var explorer_w2k_file_page_name: []const u8 = "";

const W2kSysRow = struct { name: []const u8, size: []const u8, kind: []const u8 };

const w2k_path_system32 = "C:\\WINNT\\System32";
/// 仅含已编译的 NT 兼容二进制（示意），路径与 Windows 2000 一致（WINNT）。
const w2k_system32_entries = [_]W2kSysRow{
    .{ .name = "ntdll.dll", .size = "1,842 KB", .kind = "Application Extension" },
    .{ .name = "kernel32.dll", .size = "1,128 KB", .kind = "Application Extension" },
    .{ .name = "kernelbase.dll", .size = "2,312 KB", .kind = "Application Extension" },
    .{ .name = "user32.dll", .size = "1,028 KB", .kind = "Application Extension" },
    .{ .name = "gdi32.dll", .size = "412 KB", .kind = "Application Extension" },
    .{ .name = "advapi32.dll", .size = "688 KB", .kind = "Application Extension" },
    .{ .name = "shell32.dll", .size = "14,128 KB", .kind = "Application Extension" },
    .{ .name = "ole32.dll", .size = "1,408 KB", .kind = "Application Extension" },
    .{ .name = "comctl32.dll", .size = "612 KB", .kind = "Application Extension" },
    .{ .name = "shlwapi.dll", .size = "456 KB", .kind = "Application Extension" },
    .{ .name = "explorer.exe", .size = "412 KB", .kind = "Application" },
    .{ .name = "winlogon.exe", .size = "532 KB", .kind = "Application" },
    .{ .name = "csrss.exe", .size = "6 KB", .kind = "Application" },
    .{ .name = "services.exe", .size = "108 KB", .kind = "Application" },
    .{ .name = "lsass.exe", .size = "32 KB", .kind = "Application" },
};

fn explorerW2kWindowTitle() []const u8 {
    return switch (explorer_w2k_loc) {
        .c_drive => shell_strings.en.w2k_title_c_drive,
        .c_winnt_system32 => w2k_path_system32,
        .file_page => explorer_w2k_file_page_name,
    };
}

pub fn initTaskMgrPosition(scr_w: i32, scr_h: i32) void {
    if (taskmgr_placed) return;
    const tb = getTaskbarHeight();
    const pad: i32 = 12;
    taskmgr_x = scr_w - taskmgr_w - pad;
    taskmgr_y = scr_h - tb - taskmgr_h - pad;
    taskmgr_placed = true;
}

pub fn renderClassicShellWindows(scr_w: i32, scr_h: i32, t: *const ThemeColors) void {
    renderExplorerW2kWindow(scr_w, scr_h, t);
    renderTaskManagerW2kWindow(scr_w, scr_h, t);
}

pub fn renderTaskManagerWin(scr_w: i32, scr_h: i32, t: *const ThemeColors) void {
    renderTaskManagerW2kWindow(scr_w, scr_h, t);
}

fn renderExplorerW2kWindow(scr_w: i32, scr_h: i32, t: *const ThemeColors) void {
    if (explorer_shell_state == .minimized) return;
    const wr = getWindowRect(scr_w, scr_h);
    const win_w = wr.w;
    const win_h = wr.h;
    const win_x = wr.x;
    const win_y = wr.y;

    if (dwm_initialized and dwm_config.shadow_enabled) {
        renderShadow(win_x, win_y, win_w, win_h, 6);
    } else {
        fb.fillRect(win_x + 3, win_y + 3, win_w, win_h, rgb(0x40, 0x40, 0x40));
    }

    fb.fillRect(win_x, win_y + TITLEBAR_H, win_w, win_h - TITLEBAR_H, t.window_bg);

    if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassEffect(win_x, win_y, win_w, TITLEBAR_H, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, win_w, TITLEBAR_H, t.titlebar_active_left, t.titlebar_active_right);
    }

    renderTitlebarButtons(win_x, win_y, win_w, t);

    fb.drawTextTransparent(win_x + 8, win_y + 5, explorerW2kWindowTitle(), t.titlebar_text);

    drawAeroWindowFrameBorder(win_x, win_y, win_w, win_h);
    renderExplorerW2kContent(win_x + 2, win_y + TITLEBAR_H, win_w - 4, win_h - TITLEBAR_H - 2, t);
}

fn renderTaskManagerW2kWindow(scr_w: i32, scr_h: i32, t: *const ThemeColors) void {
    if (taskmgr_shell_state == .minimized) return;
    initTaskMgrPosition(scr_w, scr_h);
    const tm_w = taskmgr_w;
    const tm_h = taskmgr_h;
    const win_x = taskmgr_x;
    const win_y = taskmgr_y;
    const th = shellTitlebarH();

    if (dwm_initialized and dwm_config.shadow_enabled) {
        renderShadow(win_x, win_y, tm_w, tm_h, 6);
    } else {
        fb.fillRect(win_x + 3, win_y + 3, tm_w, tm_h, rgb(0x40, 0x40, 0x40));
    }
    fb.fillRect(win_x, win_y + th, tm_w, tm_h - th, t.window_bg);
    if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassEffect(win_x, win_y, tm_w, th, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, tm_w, th, t.titlebar_active_left, t.titlebar_active_right);
    }
    drawAeroCaptionButtons(win_x, win_y, tm_w, th, t, getTaskMgrCaptionBtnHover());
    fb.drawTextTransparent(win_x + 8, win_y + 5, "Zircon Task Manager", t.titlebar_text);
    drawAeroWindowFrameBorder(win_x, win_y, tm_w, tm_h);
    renderTaskMgrW2kContent(win_x + 2, win_y + th, tm_w - 4, tm_h - th - 2, t);
}

/// 拖动态：标题栏 TintOnly；客户区与 `renderTaskManagerW2kWindow` 一致（非白板）。
pub fn renderTaskManagerWinDragLight(scr_w: i32, scr_h: i32, t: *const ThemeColors) void {
    if (taskmgr_shell_state == .minimized) return;
    initTaskMgrPosition(scr_w, scr_h);
    const tm_w = taskmgr_w;
    const tm_h = taskmgr_h;
    const win_x = taskmgr_x;
    const win_y = taskmgr_y;
    const th = shellTitlebarH();

    if (dwm_initialized and dwm_config.shadow_enabled) {
        renderShadow(win_x, win_y, tm_w, tm_h, 6);
    } else {
        fb.fillRect(win_x + 3, win_y + 3, tm_w, tm_h, rgb(0x30, 0x30, 0x30));
    }
    fb.fillRect(win_x, win_y + th, tm_w, tm_h - th, t.window_bg);
    if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassTintOnly(win_x, win_y, tm_w, th, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, tm_w, th, t.titlebar_active_left, t.titlebar_active_right);
    }
    drawAeroCaptionButtons(win_x, win_y, tm_w, th, t, getTaskMgrCaptionBtnHover());
    fb.drawTextTransparent(win_x + 8, win_y + 5, "Zircon Task Manager", t.titlebar_text);
    drawAeroWindowFrameBorder(win_x, win_y, tm_w, tm_h);
    renderTaskMgrW2kContent(win_x + 2, win_y + th, tm_w - 4, tm_h - th - 2, t);
}

/// 大图标视图：标签在图标下方居中，并裁剪在右窗格与滚动条之间，避免中文溢出格子。
fn drawExplorerIconLabel(icx: i32, ic_step: i32, ic_icon_w: i32, split_x: i32, body_x: i32, body_w: i32, label_y: i32, text: []const u8, fg: u32) void {
    const tw = fb.textWidth(text);
    const cx = icx + @divTrunc(ic_icon_w, 2) - @divTrunc(tw, 2);
    const left = split_x + 6;
    const right = @min(icx + ic_step - 6, body_x + body_w - 20);
    fb.drawTextTransparentClipped(@max(cx, left), label_y, right, text, fg);
}

fn renderExplorerW2kContent(x: i32, y: i32, w: i32, h: i32, t: *const ThemeColors) void {
    const menu_h: i32 = 22;
    const tool1_h: i32 = 28;
    const tool2_h: i32 = 26;
    const addr_h: i32 = 24;
    const foot_h: i32 = 24;
    const body_top_off: i32 = menu_h + tool1_h + tool2_h + addr_h;

    fb.fillRect(x, y, w, menu_h, t.button_face);
    fb.drawHLine(x, y + menu_h, w, t.button_shadow);
    const menu_items = shell_strings.en.explorer_menu;
    var mtx: i32 = x + 8;
    for (menu_items) |item| {
        fb.drawTextTransparent(mtx, y + 3, item, rgb(0x00, 0x00, 0x00));
        mtx += fb.textWidth(item) + 12;
    }

    const tool1_y = y + menu_h;
    fb.fillRect(x, tool1_y, w, tool1_h, t.button_face);
    fb.drawHLine(x, tool1_y + tool1_h, w, t.button_shadow);
    var bx: i32 = x + 6;
    const tools1 = shell_strings.en.explorer_tools;
    for (tools1, 0..) |bl, ti| {
        const bw = fb.textWidth(bl) + 12;
        fb.draw3DRect(bx, tool1_y + 4, bw, 20, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x80));
        fb.fillRect(bx + 2, tool1_y + 6, bw - 4, 16, t.button_face);
        const tc = if (ti == 1) rgb(0x80, 0x80, 0x80) else rgb(0x00, 0x00, 0x00);
        fb.drawTextTransparent(bx + 5, tool1_y + 8, bl, tc);
        bx += bw + 4;
    }

    const tool2_y = tool1_y + tool1_h;
    fb.fillRect(x, tool2_y, w, tool2_h, t.button_face);
    fb.drawHLine(x, tool2_y + tool2_h, w, t.button_shadow);
    var ix: i32 = x + 8;
    var ii: i32 = 0;
    while (ii < 8) : (ii += 1) {
        fb.draw3DRect(ix, tool2_y + 4, 26, 18, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x80));
        fb.fillRect(ix + 2, tool2_y + 6, 22, 14, rgb(0xD4, 0xD0, 0xC8));
        ix += 30;
    }

    const addr_y = tool2_y + tool2_h;
    fb.fillRect(x, addr_y, w, addr_h, t.button_face);
    fb.drawHLine(x, addr_y + addr_h, w, t.button_shadow);
    fb.drawTextTransparent(x + 8, addr_y + 4, shell_strings.en.address_label, rgb(0x00, 0x00, 0x80));
    fb.draw3DRect(x + 56, addr_y + 3, w - 120, 18, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x80));
    fb.fillRect(x + 58, addr_y + 5, w - 124, 14, rgb(0xFF, 0xFF, 0xFF));

    const addr_text: []const u8 = switch (explorer_w2k_loc) {
        .c_drive => shell_strings.en.w2k_addr_c_drive,
        .c_winnt_system32 => w2k_path_system32,
        .file_page => w2k_path_system32,
    };
    fb.drawTextTransparentClipped(x + 62, addr_y + 6, x + w - 76, addr_text, rgb(0x00, 0x00, 0x00));
    if (explorer_w2k_loc == .file_page) {
        var ax: i32 = x + 62 + fb.textWidth(addr_text);
        fb.drawTextTransparent(ax, addr_y + 6, "\\", rgb(0x00, 0x00, 0x00));
        ax += fb.textWidth("\\");
        fb.drawTextTransparentClipped(ax, addr_y + 6, x + w - 76, explorer_w2k_file_page_name, rgb(0x00, 0x00, 0x00));
    }

    fb.draw3DRect(x + w - 72, addr_y + 3, 64, 18, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x80));
    fb.fillRect(x + w - 70, addr_y + 5, 60, 14, t.button_face);
    fb.drawTextTransparent(x + w - 58, addr_y + 6, shell_strings.en.go, rgb(0x00, 0x00, 0x00));

    const split_x = x + @min(200, @max(140, @divTrunc(w * 3, 10)));
    const body_top = y + body_top_off;
    const foot_y = y + h - foot_h;
    const body_h = foot_y - body_top;
    if (body_h <= 8) return;

    if (explorer_w2k_loc == .file_page) {
        fb.fillRect(x, body_top, w, body_h, rgb(0xFA, 0xFA, 0xFA));
        fb.drawTextTransparent(x + 12, body_top + 10, shell_strings.en.file_viewer_title, rgb(0x00, 0x00, 0x80));
        fb.drawTextTransparent(x + 12, body_top + 30, shell_strings.en.file_label, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(x + 52, body_top + 30, explorer_w2k_file_page_name, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(x + 12, body_top + 52, shell_strings.en.location_label, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(x + 52, body_top + 52, w2k_path_system32, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(x + 12, body_top + 80, shell_strings.en.file_page_note, rgb(0x40, 0x40, 0x40));
        fb.drawTextTransparent(x + 12, body_top + 98, shell_strings.en.file_page_hint, rgb(0x40, 0x40, 0x40));
        fb.drawTextTransparent(x + 12, body_top + 124, shell_strings.en.back_to_list, rgb(0x00, 0x00, 0x80));
    } else if (explorer_w2k_loc == .c_drive) {
        fb.fillRect(x, body_top, w, body_h, rgb(0xFA, 0xFA, 0xFA));
        fb.draw3DRect(x, body_top, split_x - x, 18, rgb(0x80, 0x80, 0x80), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(x + 1, body_top + 1, split_x - x - 2, 16, t.button_face);
        fb.drawTextTransparent(x + 6, body_top + 3, shell_strings.en.folder_pane_title, rgb(0x00, 0x00, 0x80));
        fb.drawTextTransparent(split_x - 18, body_top + 3, "X", rgb(0x00, 0x00, 0x00));

        const tree_x0 = x + 10;
        var ty: i32 = body_top + 22;
        fb.drawTextTransparent(tree_x0, ty, shell_strings.en.tree_desktop, rgb(0x00, 0x00, 0x00));
        ty += 18;
        fb.drawTextTransparent(tree_x0 + 8, ty, shell_strings.en.tree_my_documents, rgb(0x00, 0x00, 0x00));
        ty += 18;
        fb.drawTextTransparent(tree_x0 + 8, ty, shell_strings.en.tree_my_computer, rgb(0x00, 0x00, 0x00));
        ty += 18;
        fb.fillRect(tree_x0 + 18, ty - 2, split_x - x - 24, 16, rgb(0x00, 0x00, 0x80));
        fb.drawTextTransparentClipped(tree_x0 + 20, ty, split_x - 4, shell_strings.en.tree_local_disk_c, rgb(0xFF, 0xFF, 0xFF));
        ty += 18;
        fb.drawTextTransparentClipped(tree_x0 + 32, ty, split_x - 4, "Documents and Settings", rgb(0x00, 0x00, 0x00));
        ty += 18;
        fb.drawTextTransparentClipped(tree_x0 + 32, ty, split_x - 4, "Program Files", rgb(0x00, 0x00, 0x00));
        ty += 18;
        fb.drawTextTransparentClipped(tree_x0 + 32, ty, split_x - 4, "WINNT", rgb(0x00, 0x00, 0x00));

        var doty: i32 = body_top + 30;
        while (doty < body_top + body_h - 40) : (doty += 3) {
            fb.putPixel32(@intCast(split_x - 1), @intCast(doty), rgb(0x80, 0x80, 0x80));
        }

        fb.drawVLine(split_x, body_top, body_h, t.button_shadow);

        const ic_y: i32 = body_top + 36;
        const ic_s: u32 = 2;
        const ic_step: i32 = 130;
        const ic_icon_w = icons.getIconTotalSize(ic_s);
        const label_y = ic_y + 52;
        var icx: i32 = split_x + 24;
        drawThemedIconForActiveTheme(.documents, icx, ic_y, ic_s);
        drawExplorerIconLabel(icx, ic_step, ic_icon_w, split_x, x, w, label_y, "Documents and Settings", rgb(0x00, 0x00, 0x00));
        icx += ic_step;
        drawThemedIconForActiveTheme(.documents, icx, ic_y, ic_s);
        drawExplorerIconLabel(icx, ic_step, ic_icon_w, split_x, x, w, label_y, "Program Files", rgb(0x00, 0x00, 0x00));
        icx += ic_step;
        drawThemedIconForActiveTheme(.documents, icx, ic_y, ic_s);
        drawExplorerIconLabel(icx, ic_step, ic_icon_w, split_x, x, w, label_y, "WINNT", rgb(0x00, 0x00, 0x00));
    } else {
        fb.fillRect(x, body_top, w, body_h, rgb(0xFA, 0xFA, 0xFA));
        fb.draw3DRect(x, body_top, split_x - x, 18, rgb(0x80, 0x80, 0x80), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(x + 1, body_top + 1, split_x - x - 2, 16, t.button_face);
        fb.drawTextTransparent(x + 6, body_top + 3, shell_strings.en.folder_pane_title, rgb(0x00, 0x00, 0x80));
        fb.drawTextTransparent(split_x - 18, body_top + 3, "X", rgb(0x00, 0x00, 0x00));
        var doty2: i32 = body_top + 24;
        while (doty2 < body_top + body_h - 20) : (doty2 += 3) {
            fb.putPixel32(@intCast(split_x - 1), @intCast(doty2), rgb(0x80, 0x80, 0x80));
        }
        fb.drawVLine(split_x, body_top, body_h, t.button_shadow);

        fb.drawTextTransparent(split_x + 8, body_top + 4, shell_strings.en.col_name, rgb(0x00, 0x00, 0x80));
        fb.drawTextTransparent(split_x + 200, body_top + 4, shell_strings.en.col_size, rgb(0x00, 0x00, 0x80));
        fb.drawTextTransparent(split_x + 280, body_top + 4, shell_strings.en.col_type, rgb(0x00, 0x00, 0x80));
        fb.drawHLine(split_x + 4, body_top + 20, w - 144, t.button_shadow);

        var ry: i32 = body_top + 26;
        for (w2k_system32_entries) |row| {
            fb.drawTextTransparent(split_x + 8, ry, row.name, rgb(0x00, 0x00, 0x00));
            fb.drawTextTransparent(split_x + 200, ry, row.size, rgb(0x00, 0x00, 0x00));
            fb.drawTextTransparent(split_x + 280, ry, row.kind, rgb(0x00, 0x00, 0x00));
            ry += 18;
        }
    }

    const sb_x = x + w - 16;
    fb.fillRect(sb_x, body_top, 16, body_h, rgb(0xE8, 0xE8, 0xEB));
    fb.drawVLine(sb_x, body_top, body_h, t.button_shadow);

    fb.fillRect(x, foot_y, w, foot_h, t.button_face);
    fb.drawHLine(x, foot_y, w, t.button_shadow);
    const div1 = x + @divTrunc(w * 2, 5);
    const div2 = x + @divTrunc(w * 3, 5);
    fb.drawVLine(div1, foot_y, foot_h, t.button_shadow);
    fb.drawVLine(div2, foot_y, foot_h, t.button_shadow);

    if (explorer_w2k_loc == .c_drive) {
        fb.drawTextTransparent(x + 8, foot_y + 4, shell_strings.en.status_c_drive, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(div1 + 8, foot_y + 4, shell_strings.en.status_zero_bytes, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(div2 + 8, foot_y + 4, shell_strings.en.status_my_computer, rgb(0x00, 0x00, 0x00));
    } else if (explorer_w2k_loc == .c_winnt_system32) {
        const n_obj: u32 = w2k_system32_entries.len;
        var foot_buf: [96]u8 = undefined;
        const foot_msg = shell_strings.formatFooterObjects(foot_buf[0..], n_obj, w2k_path_system32);
        fb.drawTextTransparent(x + 8, foot_y + 4, foot_msg, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(div1 + 8, foot_y + 4, shell_strings.en.status_zero_bytes, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(div2 + 8, foot_y + 4, shell_strings.en.status_my_computer, rgb(0x00, 0x00, 0x00));
    } else {
        fb.drawTextTransparent(x + 8, foot_y + 4, shell_strings.en.status_file_props, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(div1 + 8, foot_y + 4, shell_strings.en.status_zero_bytes, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(div2 + 8, foot_y + 4, shell_strings.en.status_my_computer, rgb(0x00, 0x00, 0x00));
    }
}

/// NT 6.1 Aero 风格任务管理器：浅色标签条 + 选中项 + 列表区。
fn renderTaskMgrAeroContent(x: i32, y: i32, w: i32, h: i32, t: *const ThemeColors) void {
    _ = t;
    const tab_h: i32 = 28;
    fb.drawGradientH(x, y, w, tab_h, rgb(0xE8, 0xF0, 0xF8), rgb(0xD8, 0xE4, 0xF0));
    fb.drawHLine(x, y + tab_h, w, rgb(0xA8, 0xB8, 0xD0));
    fb.fillRect(x + 6, y + 4, 96, tab_h - 8, rgb(0xF0, 0xF6, 0xFC));
    fb.drawRect(x + 6, y + 4, 96, tab_h - 8, rgb(0x70, 0x98, 0xC8));
    fb.drawTextTransparent(x + 14, y + 8, "Applications", rgb(0x00, 0x00, 0x00));
    fb.drawTextTransparent(x + 110, y + 8, "Processes", rgb(0x80, 0x80, 0x80));
    fb.drawTextTransparent(x + 200, y + 8, "Services", rgb(0x80, 0x80, 0x80));
    fb.drawTextTransparent(x + 280, y + 8, "Performance", rgb(0x80, 0x80, 0x80));

    const hdr_y = y + tab_h + 4;
    fb.fillRect(x, hdr_y - 2, w, 22, rgb(0xF0, 0xF4, 0xFA));
    fb.drawHLine(x, hdr_y + 18, w, rgb(0xD0, 0xD8, 0xE4));
    fb.drawTextTransparent(x + 8, hdr_y, "Image Name", rgb(0x00, 0x00, 0x80));
    fb.drawTextTransparent(x + 160, hdr_y, "PID", rgb(0x00, 0x00, 0x80));
    fb.drawTextTransparent(x + 220, hdr_y, "CPU", rgb(0x00, 0x00, 0x80));
    fb.drawTextTransparent(x + 270, hdr_y, "Memory", rgb(0x00, 0x00, 0x80));

    const plist = process.getProcessList();
    var py: i32 = hdr_y + 22;
    if (plist.len == 0) {
        fb.drawTextTransparent(x + 8, py, "(no PS table — process.zig empty)", rgb(0x80, 0x40, 0x40));
        py += 16;
    } else {
        const max_rows: usize = 8;
        for (plist, 0..) |proc, i| {
            if (i >= max_rows) break;
            if (i % 2 == 1) {
                fb.fillRect(x + 2, py - 1, w - 4, 17, rgb(0xF5, 0xF8, 0xFC));
            }
            const nm = if (proc.name_len > 0) proc.name[0..proc.name_len] else @as([]const u8, "(noname)");
            fb.drawTextTransparent(x + 8, py, nm, rgb(0x00, 0x00, 0x00));
            var pid_buf: [12]u8 = undefined;
            const pid_s = std.fmt.bufPrint(&pid_buf, "{d}", .{proc.pid}) catch "0";
            fb.drawTextTransparent(x + 160, py, pid_s, rgb(0x00, 0x00, 0x00));
            fb.drawTextTransparent(x + 220, py, "0", rgb(0x00, 0x00, 0x00));
            fb.drawTextTransparent(x + 270, py, "-", rgb(0x60, 0x60, 0x60));
            py += 16;
        }
        if (plist.len > max_rows) {
            var cnt_buf: [24]u8 = undefined;
            const tail = std.fmt.bufPrint(&cnt_buf, "+{d} more", .{plist.len - max_rows}) catch "+more";
            fb.drawTextTransparent(x + 8, py, tail, rgb(0x60, 0x60, 0x70));
        }
    }

    const btn_y = y + h - 28;
    fb.fillRoundedRect(x + 8, btn_y, 72, 22, 3, rgb(0xE8, 0xEC, 0xF2));
    fb.drawRect(x + 8, btn_y, 72, 22, rgb(0xA8, 0xB8, 0xCC));
    fb.drawTextTransparent(x + 18, btn_y + 5, "End Task", rgb(0x00, 0x00, 0x00));

    fb.fillRoundedRect(x + 88, btn_y, 80, 22, 3, rgb(0xE8, 0xEC, 0xF2));
    fb.drawRect(x + 88, btn_y, 80, 22, rgb(0xA8, 0xB8, 0xCC));
    fb.drawTextTransparent(x + 98, btn_y + 5, "Switch To", rgb(0x00, 0x00, 0x00));
}

fn renderTaskMgrW2kContent(x: i32, y: i32, w: i32, h: i32, t: *const ThemeColors) void {
    renderTaskMgrAeroContent(x, y, w, h, t);
}

// ── Sample Window ──

fn renderSampleWindow(scr_w: i32, scr_h: i32, t: *const ThemeColors) void {
    const wr = getWindowRect(scr_w, scr_h);
    const win_w = wr.w;
    const win_h = wr.h;
    const win_x = wr.x;
    const win_y = wr.y;

    if (dwm_initialized and dwm_config.shadow_enabled) {
        renderShadow(win_x, win_y, win_w, win_h, 6);
    } else {
        fb.fillRect(win_x + 4, win_y + 4, win_w, win_h, rgb(0x00, 0x00, 0x00) & 0x20000000);
    }

    // Client area only — titlebar keeps backdrop for true Aero glass (DesktopManagerSpec)
    fb.fillRect(win_x, win_y + TITLEBAR_H, win_w, win_h - TITLEBAR_H, t.window_bg);

    if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassEffect(win_x, win_y, win_w, TITLEBAR_H, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, win_w, TITLEBAR_H, t.titlebar_active_left, t.titlebar_active_right);
    }

    renderTitlebarButtons(win_x, win_y, win_w, t);

    fb.drawTextTransparent(win_x + 8, win_y + 5, "Computer", t.titlebar_text);

    drawAeroWindowFrameBorder(win_x, win_y, win_w, win_h);
    renderWindowContent(win_x + 2, win_y + TITLEBAR_H, win_w - 4, win_h - TITLEBAR_H - 2, t);
}

fn renderTitlebarButtons(win_x: i32, win_y: i32, win_w: i32, t: *const ThemeColors) void {
    if (dwm_initialized and dwm_config.glass_enabled) {
        drawAeroCaptionButtons(win_x, win_y, win_w, TITLEBAR_H, t, .none);
        return;
    }

    const btn_y = win_y + @divTrunc(TITLEBAR_H - BTN_SIZE, 2);
    const close_x = clampI32FromI64(@as(i64, win_x) + @as(i64, win_w) - @as(i64, BTN_SIZE) - 4);
    const max_x = clampI32FromI64(@as(i64, close_x) - @as(i64, BTN_SIZE) - 2);
    const min_x = clampI32FromI64(@as(i64, max_x) - @as(i64, BTN_SIZE) - 2);

    fb.fillRoundedRect(close_x, btn_y, BTN_SIZE, BTN_SIZE, 3, t.btn_close_top);
    drawCloseSymbol(close_x, btn_y, BTN_SIZE);

    fb.fillRoundedRect(max_x, btn_y, BTN_SIZE, BTN_SIZE, 3, t.btn_minmax_top);
    drawMaxSymbol(max_x, btn_y, BTN_SIZE);

    fb.fillRoundedRect(min_x, btn_y, BTN_SIZE, BTN_SIZE, 3, t.btn_minmax_top);
    drawMinSymbol(min_x, btn_y, BTN_SIZE);
}

fn drawAeroCaptionMinGlyph(bx: i32, by: i32, bw: i32, bh: i32, fg: u32) void {
    if (bw < 8 or bh < 8) return;
    const bar_w = @max(10, bw - 18);
    const bar_h: i32 = 2;
    const sx = bx + @divTrunc(bw - bar_w, 2);
    const sy = by + @divTrunc(bh - bar_h, 2) + 1;
    fb.fillRect(sx, sy, bar_w, bar_h, fg);
}

fn drawAeroCaptionMaxGlyph(bx: i32, by: i32, bw: i32, bh: i32, fg: u32) void {
    if (bw < 10 or bh < 10) return;
    const m = @max(5, @min(8, @divTrunc(@min(bw, bh), 5)));
    const sz = @max(7, @min(bw, bh) - 2 * m);
    const ox = bx + @divTrunc(bw - sz, 2);
    const oy = by + @divTrunc(bh - sz, 2);
    fb.drawRect(ox, oy, sz, sz, fg);
    fb.drawHLine(ox, oy + 1, sz, fg);
}

fn drawAeroCaptionCloseGlyph(bx: i32, by: i32, bw: i32, bh: i32, fg: u32) void {
    if (bw < 8 or bh < 8) return;
    const cx = bx + @divTrunc(bw, 2);
    const cy = by + @divTrunc(bh, 2);
    const arm: i32 = @min(5, @max(3, @divTrunc(@min(bw, bh), 2) - 3));
    var d: i32 = -arm;
    while (d <= arm) : (d += 1) {
        fb.putPixel32(@intCast(cx + d), @intCast(cy + d), fg);
        fb.putPixel32(@intCast(cx + d), @intCast(cy - d), fg);
    }
}

/// Windows 7 DWM Aero：三键为贴标题栏全高的等宽列；默认无方块描边、关闭键默认非红；细竖线分隔；悬停时 Min/Max 微亮、Close 为珊瑚红。
pub fn drawAeroCaptionButtons(win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32, _: *const ThemeColors, hover: AeroCaptionBtnHover) void {
    if (titlebar_h < 8 or win_w < 96) return;

    const L = aeroCaptionButtonLayout(win_x, win_y, win_w, titlebar_h);
    const min_x = L.min_x;
    const max_x = L.max_x;
    const close_x = L.close_x;
    const btn_w = L.btn_w;
    const btn_w_close = L.btn_w_close;
    const btn_y = L.btn_y;
    const btn_h = L.btn_h;

    const div_dark = rgb(0x3A, 0x5A, 0x78);
    const div_light = rgb(0xB8, 0xD0, 0xE8);
    const glyph_idle = rgb(0xE8, 0xF2, 0xFA);
    const glyph_on_red = rgb(0xFF, 0xFF, 0xFF);

    // 标题区 | 按钮组：Aero 常见双线竖隔
    if (L.group_sep_x > win_x + 4) {
        fb.drawVLine(L.group_sep_x, win_y + 1, titlebar_h - 2, div_light);
        fb.drawVLine(L.group_sep_x + 1, win_y + 2, titlebar_h - 4, div_dark);
    }
    // 列与列之间单竖线（贴顶底）
    fb.drawVLine(max_x, win_y + 1, titlebar_h - 2, div_dark);
    fb.drawVLine(close_x, win_y + 1, titlebar_h - 2, div_dark);

    // 悬停底衬（关闭键仅在悬停时铺红，符合 Aero 约定）
    if (hover == .minimize) {
        fb.blendTintRect(min_x, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
    }
    if (hover == .maximize) {
        fb.blendTintRect(max_x, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
    }
    if (hover == .close) {
        fb.fillRect(close_x, btn_y, btn_w_close, btn_h, rgb(0xE8, 0x11, 0x23));
    }

    drawAeroCaptionMinGlyph(min_x, btn_y, btn_w, btn_h, glyph_idle);
    drawAeroCaptionMaxGlyph(max_x, btn_y, btn_w, btn_h, glyph_idle);
    drawAeroCaptionCloseGlyph(close_x, btn_y, btn_w_close, btn_h, if (hover == .close) glyph_on_red else glyph_idle);
}

pub fn drawCloseSymbol(bx: i32, by: i32, bs: i32) void {
    drawCloseSymbolColored(bx, by, bs, rgb(0xFF, 0xFF, 0xFF));
}

pub fn drawCloseSymbolColored(bx: i32, by: i32, bs: i32, fg: u32) void {
    const cx = bx + @divTrunc(bs, 2);
    const cy = by + @divTrunc(bs, 2);
    var i: i32 = -3;
    while (i <= 3) : (i += 1) {
        fb.putPixel32(@intCast(cx + i), @intCast(cy + i), fg);
        fb.putPixel32(@intCast(cx + i), @intCast(cy - i), fg);
        if (i > -3 and i < 3) {
            fb.putPixel32(@intCast(cx + i + 1), @intCast(cy + i), fg);
            fb.putPixel32(@intCast(cx + i + 1), @intCast(cy - i), fg);
        }
    }
}

pub fn drawMaxSymbol(bx: i32, by: i32, bs: i32) void {
    drawMaxSymbolColored(bx, by, bs, rgb(0xFF, 0xFF, 0xFF));
}

pub fn drawMaxSymbolColored(bx: i32, by: i32, bs: i32, fg: u32) void {
    const ox = bx + 5;
    const oy = by + 5;
    const sz = bs - 10;
    if (sz <= 0) return;
    fb.drawRect(ox, oy, sz, sz, fg);
    fb.drawHLine(ox, oy + 1, sz, fg);
}

pub fn drawMinSymbol(bx: i32, by: i32, bs: i32) void {
    drawMinSymbolColored(bx, by, bs, rgb(0xFF, 0xFF, 0xFF));
}

pub fn drawMinSymbolColored(bx: i32, by: i32, bs: i32, fg: u32) void {
    if (bs <= 10) return;
    fb.fillRect(bx + 5, by + bs - 8, bs - 10, 3, fg);
}

/// Windows 7 Aero：双层 3D 窗框（外亮/内深）+ 顶缘高光，替代单层 `drawRect`。
pub fn drawAeroWindowFrameBorder(win_x: i32, win_y: i32, win_w: i32, win_h: i32) void {
    if (win_w < 4 or win_h < 4) return;
    const outer_hi = rgb(0xC0, 0xD8, 0xF0);
    const outer_lo = rgb(0x48, 0x60, 0x80);
    const inner_hi = rgb(0xA0, 0xC0, 0xE0);
    const inner_lo = rgb(0x38, 0x50, 0x70);
    fb.draw3DRect(win_x, win_y, win_w, win_h, outer_hi, outer_lo);
    fb.draw3DRect(win_x + 1, win_y + 1, win_w - 2, win_h - 2, inner_hi, inner_lo);
    if (win_w > 8) {
        fb.drawHLine(win_x + 3, win_y + 2, win_w - 6, rgb(0xF0, 0xF8, 0xFF));
    }
}

fn renderWindowContent(x: i32, y: i32, w: i32, h: i32, t: *const ThemeColors) void {
    fb.fillRect(x, y, w, 24, t.button_face);
    fb.drawHLine(x, y + 24, w, t.button_shadow);

    const toolbar_items = [_][]const u8{ "File", "Edit", "View", "Favorites", "Tools", "Help" };
    var tx: i32 = x + 8;
    for (toolbar_items) |item| {
        fb.drawTextTransparent(tx, y + 4, item, rgb(0x00, 0x00, 0x00));
        tx += fb.textWidth(item) + 16;
    }

    const addr_y = y + 25;
    fb.fillRect(x, addr_y, w, 22, t.button_face);
    fb.drawHLine(x, addr_y + 22, w, t.button_shadow);
    fb.drawTextTransparent(x + 8, addr_y + 3, "Address: Z:\\", rgb(0x00, 0x00, 0x00));

    const content_y = addr_y + 23;
    const content_h = h - 47;
    if (content_h > 0) {
        fb.fillRect(x, content_y, w, content_h, rgb(0xFF, 0xFF, 0xFF));

        const items = [_]struct { name: []const u8, icon_id: icons.IconId }{
            .{ .name = "Users", .icon_id = .documents },
            .{ .name = "Programs", .icon_id = .documents },
            .{ .name = "System", .icon_id = .documents },
            .{ .name = "resources", .icon_id = .documents },
            .{ .name = "boot.cfg", .icon_id = .computer },
            .{ .name = "zloader", .icon_id = .computer },
        };

        var iy: i32 = content_y + 8;
        for (items) |item| {
            if (iy + 20 > content_y + content_h) break;

            drawThemedIconForActiveTheme(item.icon_id, x + 10, iy + 1, 1);

            fb.drawTextTransparent(x + 32, iy + 2, item.name, rgb(0x00, 0x00, 0x00));
            iy += 22;
        }

        // Font info line (bundled UI font / theme typeface)
        if (iy + 20 <= content_y + content_h) {
            fb.drawTextTransparent(x + 10, iy + 4, "Font: Noto Sans (embedded)", rgb(0x80, 0x80, 0x80));
            iy += 20;
        }

        const sb_x = x + w - 17;
        fb.fillRect(sb_x, content_y, 17, content_h, rgb(0xE8, 0xE8, 0xEB));
        fb.drawVLine(sb_x, content_y, content_h, t.button_shadow);
        fb.fillRect(sb_x + 1, content_y + 17, 16, 40, rgb(0xC1, 0xC1, 0xC6));
    }

    fb.fillRect(x, y + h - 22, w, 22, t.button_face);
    fb.drawHLine(x, y + h - 22, w, t.button_shadow);

    const status_text = "6 objects | Aero | ZirconOSAero resources";

    fb.drawTextTransparent(x + 8, y + h - 18, status_text, rgb(0x00, 0x00, 0x00));
}

// ── Window Drag / Shell 几何（Explorer + 任务管理器）──

var drag_active: bool = false;
var drag_offset_x: i32 = 0;
var drag_offset_y: i32 = 0;
var window_x: i32 = 0;
var window_y: i32 = 0;
var window_placed: bool = false;

var explorer_shell_state: ShellWindowState = .normal;
var explorer_restore_snap: struct { x: i32, y: i32, w: i32, h: i32, custom: bool } = .{
    .x = 0,
    .y = 0,
    .w = 0,
    .h = 0,
    .custom = false,
};
var explorer_custom_frame: bool = false;
var explorer_frame_w: i32 = 0;
var explorer_frame_h: i32 = 0;
var explorer_edge_resize: FrameResizeEdge = .none;
var taskmgr_edge_resize: FrameResizeEdge = .none;

var explorer_dwm_surface_id: ?u16 = null;
var taskmgr_dwm_surface_id: ?u16 = null;

/// Explorer client size scales with resolution (fraction of work area). Font/glyph scale is unchanged.
fn computeSampleWindowDims(scr_w: i32, scr_h: i32) ShellFrameDims {
    const tb = getTaskbarHeight();
    const margin: i32 = 16;
    const max_h_i = @as(i64, scr_h) - @as(i64, tb) - @as(i64, margin) * 2;
    const max_w_i = @as(i64, scr_w) - @as(i64, margin) * 2;
    const max_h = clampI32FromI64(max_h_i);
    const max_w = clampI32FromI64(max_w_i);
    if (max_w < 160 or max_h < 120) {
        return .{ .w = @max(120, max_w), .h = @max(96, max_h) };
    }

    // ~72% of work area (NT 6.1 Aero-style large Explorer); floors keep modest minimums on huge panels.
    var win_w: i32 = clampI32FromI64(@divTrunc(max_w_i * 18, 25));
    var win_h: i32 = clampI32FromI64(@divTrunc(max_h_i * 18, 25));
    win_w = @max(480, @min(max_w, win_w));
    win_h = @max(400, @min(max_h, win_h));

    return .{ .w = win_w, .h = win_h };
}

fn initWindowPosition(scr_w: i32, scr_h: i32) void {
    if (!window_placed) {
        const dim = computeSampleWindowDims(scr_w, scr_h);
        const tb = getTaskbarHeight();
        const pad: i32 = 12;
        window_x = @divTrunc(scr_w - dim.w, 2);
        if (window_x < pad) window_x = pad;
        const wy64 = @divTrunc(@as(i64, scr_h) - @as(i64, tb) - @as(i64, dim.h), 2);
        window_y = clampI32FromI64(wy64);
        if (window_y < pad) window_y = pad;
        const bottom = @as(i64, window_y) + @as(i64, dim.h);
        const limit = @as(i64, scr_h) - @as(i64, tb) - 2;
        if (bottom > limit) {
            window_y = clampI32FromI64(limit - @as(i64, dim.h));
        }
        if (window_y < pad) window_y = pad;
        window_placed = true;
    }
}

fn desktopWorkArea(scr_w: i32, scr_h: i32) ShellRect {
    const tb = getTaskbarHeight();
    const m: i32 = 2;
    const mi = @as(i64, m);
    return .{
        .x = m,
        .y = m,
        .w = clampRectDimI64(@as(i64, scr_w) - 2 * mi),
        .h = clampRectDimI64(@as(i64, scr_h) - @as(i64, tb) - 2 * mi),
    };
}

fn explorerFrameDims(scr_w: i32, scr_h: i32) ShellFrameDims {
    if (explorer_custom_frame and explorer_frame_w >= explorer_min_frame_w and explorer_frame_h >= explorer_min_frame_h) {
        return .{ .w = explorer_frame_w, .h = explorer_frame_h };
    }
    return computeSampleWindowDims(scr_w, scr_h);
}

pub fn isExplorerWindowMinimized() bool {
    return explorer_shell_state == .minimized;
}

pub fn isTaskMgrWindowMinimized() bool {
    return taskmgr_shell_state == .minimized;
}

pub fn getTaskMgrSize() struct { w: i32, h: i32 } {
    return .{ .w = taskmgr_w, .h = taskmgr_h };
}

pub fn getWindowRect(scr_w: i32, scr_h: i32) struct { x: i32, y: i32, w: i32, h: i32 } {
    if (explorer_shell_state == .minimized) {
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }
    initWindowPosition(scr_w, scr_h);
    if (explorer_shell_state == .maximized) {
        const wa = desktopWorkArea(scr_w, scr_h);
        return .{ .x = wa.x, .y = wa.y, .w = wa.w, .h = wa.h };
    }
    const dim = explorerFrameDims(scr_w, scr_h);
    return .{ .x = window_x, .y = window_y, .w = dim.w, .h = dim.h };
}

fn hitTestFrameResizeEdge(px: i32, py: i32, rx: i32, ry: i32, rw: i32, rh: i32) FrameResizeEdge {
    if (rw < frame_resize_hit_px * 3 or rh < frame_resize_hit_px * 3) return .none;
    if (!pointInRectI32(px, py, rx, ry, rw, rh)) return .none;
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    const rx64 = @as(i64, rx);
    const ry64 = @as(i64, ry);
    const rw64 = @as(i64, rw);
    const rh64 = @as(i64, rh);
    const hit = @as(i64, frame_resize_hit_px);
    const in_left = pxi < rx64 + hit;
    const in_right = pxi >= rx64 + rw64 - hit;
    const in_top = pyi < ry64 + hit;
    const in_bottom = pyi >= ry64 + rh64 - hit;
    if (!(in_left or in_right or in_top or in_bottom)) return .none;
    if (in_top and in_left) return .nw;
    if (in_top and in_right) return .ne;
    if (in_bottom and in_left) return .sw;
    if (in_bottom and in_right) return .se;
    if (in_top) return .n;
    if (in_bottom) return .s;
    if (in_left) return .w;
    if (in_right) return .e;
    return .none;
}

fn clampShellFrameToWorkArea(nx: *i32, ny: *i32, nw: *i32, nh: *i32, wa: ShellRect, min_w: i32, min_h: i32) void {
    if (nw.* < min_w) nw.* = min_w;
    if (nh.* < min_h) nh.* = min_h;
    if (nx.* < wa.x) {
        const d = wa.x - nx.*;
        nx.* = wa.x;
        nw.* -= d;
    }
    if (ny.* < wa.y) {
        const d = wa.y - ny.*;
        ny.* = wa.y;
        nh.* -= d;
    }
    if (nx.* + nw.* > wa.x + wa.w) {
        nw.* = wa.x + wa.w - nx.*;
    }
    if (ny.* + nh.* > wa.y + wa.h) {
        nh.* = wa.y + wa.h - ny.*;
    }
    nw.* = @max(min_w, nw.*);
    nh.* = @max(min_h, nh.*);
}

fn applyExplorerFrameResize(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    if (explorer_edge_resize == .none) return false;
    const wa = desktopWorkArea(scr_w, scr_h);
    var nx = window_x;
    var ny = window_y;
    const dim0 = explorerFrameDims(scr_w, scr_h);
    var nw = dim0.w;
    var nh = dim0.h;

    switch (explorer_edge_resize) {
        .none => return false,
        .e => nw = px - nx,
        .s => nh = py - ny,
        .se => {
            nw = px - nx;
            nh = py - ny;
        },
        .w => {
            const right = nx + nw;
            nw = right - px;
            nx = px;
        },
        .n => {
            const bottom = ny + nh;
            nh = bottom - py;
            ny = py;
        },
        .ne => {
            const bottom = ny + nh;
            nh = bottom - py;
            ny = py;
            nw = px - nx;
        },
        .nw => {
            const right = nx + nw;
            const bottom = ny + nh;
            nw = right - px;
            nx = px;
            nh = bottom - py;
            ny = py;
        },
        .sw => {
            const right = nx + nw;
            nw = right - px;
            nx = px;
            nh = py - ny;
        },
    }
    clampShellFrameToWorkArea(&nx, &ny, &nw, &nh, wa, explorer_min_frame_w, explorer_min_frame_h);
    const changed = nx != window_x or ny != window_y or nw != dim0.w or nh != dim0.h;
    window_x = nx;
    window_y = ny;
    explorer_frame_w = nw;
    explorer_frame_h = nh;
    explorer_custom_frame = true;
    return changed;
}

fn applyTaskMgrFrameResize(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    if (taskmgr_edge_resize == .none) return false;
    const wa = desktopWorkArea(scr_w, scr_h);
    var nx = taskmgr_x;
    var ny = taskmgr_y;
    var nw = taskmgr_w;
    var nh = taskmgr_h;

    switch (taskmgr_edge_resize) {
        .none => return false,
        .e => nw = px - nx,
        .s => nh = py - ny,
        .se => {
            nw = px - nx;
            nh = py - ny;
        },
        .w => {
            const right = nx + nw;
            nw = right - px;
            nx = px;
        },
        .n => {
            const bottom = ny + nh;
            nh = bottom - py;
            ny = py;
        },
        .ne => {
            const bottom = ny + nh;
            nh = bottom - py;
            ny = py;
            nw = px - nx;
        },
        .nw => {
            const right = nx + nw;
            const bottom = ny + nh;
            nw = right - px;
            nx = px;
            nh = bottom - py;
            ny = py;
        },
        .sw => {
            const right = nx + nw;
            nw = right - px;
            nx = px;
            nh = py - ny;
        },
    }
    clampShellFrameToWorkArea(&nx, &ny, &nw, &nh, wa, taskmgr_min_frame_w, taskmgr_min_frame_h);
    const changed = nx != taskmgr_x or ny != taskmgr_y or nw != taskmgr_w or nh != taskmgr_h;
    taskmgr_x = nx;
    taskmgr_y = ny;
    taskmgr_w = nw;
    taskmgr_h = nh;
    return changed;
}

/// 与 `renderDesktopAeroTaskbar` 中第一个应用磁贴（Computer）几何一致，用于最小化恢复命中。
fn taskbarComputerPillRect(scr_w: i32, scr_h: i32) ?ShellRect {
    const tb_h = getTaskbarHeight();
    const tb_y = clampI32FromI64(@as(i64, scr_h) - @as(i64, tb_h));
    const orb = aeroTaskbarStartOrb(tb_y, tb_h);
    const icon_s: u32 = 2;
    const icon_px = icons.getIconTotalSize(icon_s);
    const ql_pad: i32 = 3;
    var qx: i32 = orb.slot_w + 6;
    for (0..3) |_| {
        qx += icon_px + 2 * ql_pad + 6;
    }
    const tile: i32 = 34;
    const pill_h: i32 = tile;
    const ax = qx + 8;
    const ay = tb_y + @divTrunc(tb_h - pill_h, 2);
    if (ax + tile > scr_w - 8) return null;
    return ShellRect{ .x = ax, .y = ay, .w = tile, .h = pill_h };
}

fn hitTestTaskbarComputerPill(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    const r = taskbarComputerPillRect(scr_w, scr_h) orelse return false;
    return pointInRectI32(px, py, r.x, r.y, r.w, r.h);
}

/// 任务栏「计算机」磁贴悬停缩略：当前采样 **Explorer 客户区帧缓冲**（与 `syncDwmCompositorShellMetadata` 中 `explorer_dwm_surface_id` 元数据并行，非第三方 HWND 枚举）。
fn maybeRefreshExplorerTaskbarThumb(px: i32, py: i32, scr_w: i32, scr_h: i32) void {
    const pill = taskbarComputerPillRect(scr_w, scr_h) orelse {
        taskbar_explorer_thumb_valid = false;
        return;
    };
    if (!pointInRectI32(px, py, pill.x, pill.y, pill.w, pill.h)) {
        taskbar_explorer_thumb_valid = false;
        return;
    }
    if (explorer_shell_state == .minimized) {
        taskbar_explorer_thumb_valid = false;
        return;
    }
    const sched = @import("../../ke/scheduler.zig");
    const now = sched.getTicks();
    if (taskbar_explorer_thumb_valid and now -% taskbar_explorer_thumb_last_tick < dwm_comp.thumb_refresh_min_ticks) return;
    taskbar_explorer_thumb_last_tick = now;

    const wr = getWindowRect(scr_w, scr_h);
    const tw: u32 = 20;
    const th: u32 = 15;
    const sw: u32 = @intCast(@max(1, wr.w));
    const sh: u32 = @intCast(@max(1, wr.h));
    const wx: u32 = @intCast(wr.x);
    const wy: u32 = @intCast(wr.y);
    var ty: u32 = 0;
    while (ty < th) : (ty += 1) {
        var tx: u32 = 0;
        while (tx < tw) : (tx += 1) {
            const sx = wx + (tx *% sw) / tw;
            const sy = wy + (ty *% sh) / th;
            taskbar_explorer_thumb[ty * tw + tx] = fb.getPixel32(sx, sy);
        }
    }
    taskbar_explorer_thumb_valid = true;
    dwm_comp.enqueueIconicThumbnailRequest(0);
    user32.broadcastDwmIconicThumbnailRequested(dwm_comp.surface_thumb_w, dwm_comp.surface_thumb_h);
}

fn paintExplorerTaskbarThumbnailPreview(scr_w: i32, scr_h: i32) void {
    if (!taskbar_explorer_thumb_valid) return;
    const pr = taskbarComputerPillRect(scr_w, scr_h) orelse return;
    const tw: i32 = 20;
    const th: i32 = 15;
    const scale: i32 = 3;
    const ox = pr.x + pr.w + 6;
    var oy = pr.y - th * scale - 8;
    if (oy < 4) oy = pr.y + pr.h + 4;
    var j: i32 = 0;
    while (j < th) : (j += 1) {
        var i: i32 = 0;
        while (i < tw) : (i += 1) {
            const c = taskbar_explorer_thumb[@intCast(@as(usize, @intCast(j)) * 20 + @as(usize, @intCast(i)))];
            fb.fillRect(ox + i * scale, oy + j * scale, scale, scale, c);
        }
    }
    fb.drawRect(ox - 1, oy - 1, tw * scale + 2, th * scale + 2, rgb(0xE0, 0xF0, 0xFF));
}

/// 将 `dwm_compositor` 表面缩略图以简单列偏移「梯形」近似贴到 Flip3D 卡片（CPU；与用户态 `compositor.flip3d_preview_enabled` 同为预览语义）。
fn flip3dPaintSurfaceThumb(dst_x: i32, dst_y: i32, scale: i32, sid_opt: ?u16) void {
    if (scale < 1) return;
    const sid = sid_opt orelse return;
    const px = dwm_comp.getSurfaceThumbPixels(sid) orelse return;
    const tw = dwm_comp.surface_thumb_w;
    const th = dwm_comp.surface_thumb_h;
    const wpl: i32 = @as(i32, @intCast(tw)) * scale;
    const hpl: i32 = @as(i32, @intCast(th)) * scale;
    var ix: i32 = 0;
    while (ix < wpl) : (ix += 1) {
        const col: u32 = @intCast(@divTrunc(ix, scale));
        if (col >= tw) continue;
        const skew = @divTrunc(ix * 4, wpl + 1);
        var iy: i32 = 0;
        while (iy < hpl) : (iy += 1) {
            const row: u32 = @intCast(@divTrunc(iy, scale));
            if (row >= th) continue;
            const c = px[row * tw + col];
            fb.fillRect(dst_x + ix, dst_y + iy + skew, 1, 1, c);
        }
    }
}

/// Flip3D 覆盖层：**专用合成模式** — 激活时 `renderSceneWithoutSoftwareCursorFlip3dAware` 在 `flip3d_needs_scene_refresh==false` 下冻结壁纸采样，仅叠本层 + 光标；首帧打开或需刷新背景时置 `flip3d_needs_scene_refresh`。
/// **性能模型**：仍走桌面主合成节拍（非独立 Win7 级帧预算）；冻结壁纸主要为减采样而非停调度。
/// CPU 预算：本函数内多卡片为 O(缩略像素×scale)；勿在此调用全屏 `boxBlur`。
fn renderFlip3dOverlay(scr_w: i32, scr_h: i32) void {
    const nt61_aero = @import("nt61_aero_defaults");
    if (!nt61_aero.KernelCompositor.flip3d_enabled) return;
    const t = theme_mod.getActiveTheme();
    fb.blendTintRect(0, 0, scr_w, scr_h, rgb(0x08, 0x10, 0x20), 165, 220);
    const wr = getWindowRect(scr_w, scr_h);
    const cx = @divTrunc(scr_w, 2) - 120;
    const cy = @divTrunc(scr_h, 2) - 100;
    fb.fillRoundedRect(cx + 28, cy + 24, 220, 160, 10, rgb(0x20, 0x30, 0x48));
    fb.fillRoundedRect(cx, cy, 220, 160, 10, t.window_bg);
    fb.drawRect(cx, cy, 220, 160, rgb(0xA8, 0xC8, 0xE8));
    fb.drawTextTransparentUi(cx + 10, cy + 8, "Explorer", t.titlebar_text);
    flip3dPaintSurfaceThumb(cx + 14, cy + 40, 3, explorer_dwm_surface_id);
    _ = wr;
    initTaskMgrPosition(scr_w, scr_h);
    if (taskmgr_shell_state != .minimized) {
        const w2 = @divTrunc(taskmgr_w * 2, 3);
        const h2 = @divTrunc(taskmgr_h * 2, 3);
        fb.fillRoundedRect(cx + 40, cy + 40, w2, h2, 8, t.window_bg);
        fb.drawRect(cx + 40, cy + 40, w2, h2, rgb(0x88, 0xA8, 0xC8));
        fb.drawTextTransparentUi(cx + 48, cy + 48, "TaskMgr", t.titlebar_text);
        flip3dPaintSurfaceThumb(cx + 48, cy + 56, 2, taskmgr_dwm_surface_id);
    }
    // `collectShellWindowSurfaceIds`：多表面缩略条（与 user32 窗体表面并存；降级为 0 张时仅保留上方面孔卡片）。
    var shell_sids: [dwm_comp.flip3d_shell_sid_buffer_cap]u16 = undefined;
    const n_shell = dwm_comp.collectShellWindowSurfaceIds(&shell_sids);
    var si: usize = 0;
    const max_preview = @min(dwm_comp.flip3d_shell_thumb_paint_max, n_shell);
    while (si < max_preview) : (si += 1) {
        flip3dPaintSurfaceThumb(cx - 70 + @as(i32, @intCast(si * 52)), cy + 118, 2, shell_sids[si]);
    }
    fb.drawTextTransparentUi(@divTrunc(scr_w, 2) - 60, 24, "Flip3D (Alt+Tab) — CPU preview", rgb(0xE8, 0xF0, 0xFF));
}

fn hitTestTaskMgrTrayChip(px: i32, py: i32) bool {
    const r = taskmgr_tray_chip_rect;
    if (r.w <= 0 or r.h <= 0) return false;
    return pointInRectI32(px, py, r.x, r.y, r.w, r.h);
}

fn tryTaskbarRestoreMinimizedWindows(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    if (explorer_shell_state == .minimized and hitTestTaskbarComputerPill(px, py, scr_w, scr_h)) {
        explorer_shell_state = .normal;
        return true;
    }
    if (taskmgr_shell_state == .minimized and hitTestTaskMgrTrayChip(px, py)) {
        taskmgr_shell_state = .normal;
        return true;
    }
    return false;
}

fn syncDwmCompositorShellMetadata(scr_w: i32, scr_h: i32) void {
    if (!dwm_comp.isInitialized()) return;
    if (explorer_dwm_surface_id == null) {
        explorer_dwm_surface_id = dwm_comp.createSurface(0, 0, 400, 300, 1);
    }
    if (taskmgr_dwm_surface_id == null) {
        taskmgr_dwm_surface_id = dwm_comp.createSurface(0, 0, 320, 260, 2);
    }
    if (explorer_dwm_surface_id) |sid| {
        if (explorer_shell_state == .minimized) {
            dwm_comp.moveSurface(sid, -4096, -4096);
            dwm_comp.resizeSurface(sid, 4, 4);
        } else {
            const wr = getWindowRect(scr_w, scr_h);
            dwm_comp.moveSurface(sid, wr.x, wr.y);
            dwm_comp.resizeSurface(sid, @intCast(@max(1, wr.w)), @intCast(@max(1, wr.h)));
        }
        dwm_comp.markSurfaceDirty(sid);
    }
    if (taskmgr_dwm_surface_id) |sid| {
        if (taskmgr_shell_state == .minimized) {
            dwm_comp.moveSurface(sid, -4096, -4096);
            dwm_comp.resizeSurface(sid, 4, 4);
        } else {
            dwm_comp.moveSurface(sid, taskmgr_x, taskmgr_y);
            dwm_comp.resizeSurface(sid, @intCast(@max(1, taskmgr_w)), @intCast(@max(1, taskmgr_h)));
        }
        dwm_comp.markSurfaceDirty(sid);
    }
}

// ── Aero 托盘「显示隐藏的图标」弹出菜单（纵向列表，避免与网络/设置图标同一行重叠）──

var aero_tray_flyout_visible: bool = false;

const aero_tray_flyout_items = [_][]const u8{
    "Network",
    "Open Network and Sharing Center",
    "---",
    "Settings",
};

const AERO_TRAY_FLYOUT_ROW: i32 = 24;
const AERO_TRAY_FLYOUT_W: i32 = 212;
const AERO_TRAY_FLYOUT_PAD: i32 = 4;

fn aeroTrayFlyoutMenuHeight() i32 {
    var h: i32 = AERO_TRAY_FLYOUT_PAD * 2;
    for (aero_tray_flyout_items) |item| {
        if (item.len == 3 and item[0] == '-') {
            h += 10;
        } else {
            h += AERO_TRAY_FLYOUT_ROW;
        }
    }
    return h;
}

fn aeroTrayFlyoutRect(scr_w: i32, scr_h: i32) struct { x: i32, y: i32, w: i32, h: i32 } {
    const tb_h = getTaskbarHeight();
    const tray = aero_tray.layout(scr_w, scr_h, tb_h);
    const menu_h = aeroTrayFlyoutMenuHeight();
    const fw = @as(i64, AERO_TRAY_FLYOUT_W);
    var fx64 = @as(i64, tray.chevron_x) - fw + 24;
    if (fx64 < 4) fx64 = 4;
    const sw = @as(i64, scr_w);
    if (fx64 + fw > sw - 4) fx64 = sw - 4 - fw;
    const fy64 = @as(i64, tray.tb_y) - @as(i64, menu_h) - 4;
    const fy = @max(4, clampI32FromI64(fy64));
    return .{ .x = clampI32FromI64(fx64), .y = fy, .w = AERO_TRAY_FLYOUT_W, .h = menu_h };
}

/// 由 `renderer_aero` 在任务栏之后绘制（与托盘命中几何一致）。
pub fn renderAeroTrayFlyout(scr_w: i32, scr_h: i32) void {
    if (!aero_tray_flyout_visible) return;
    if (!use_framebuffer or !fb.isInitialized()) return;

    const t = active_theme;
    const r = aeroTrayFlyoutRect(scr_w, scr_h);
    if (dwm_initialized and dwm_config.shadow_enabled) {
        renderShadow(r.x, r.y, r.w, r.h, 4);
    } else {
        fb.fillRect(r.x + 2, r.y + 2, r.w, r.h, rgb(0x18, 0x18, 0x18));
    }
    fb.fillRect(r.x, r.y, r.w, r.h, t.window_bg);
    if (dwm_initialized and dwm_config.glass_enabled) {
        // 小面板与右键菜单一致：tint-only，避免托盘飞出打开时盒式模糊拖慢壳层。
        renderGlassTintOnly(r.x, r.y, r.w, r.h, t.titlebar_active_left, .caption);
    }
    fb.drawRect(r.x, r.y, r.w, r.h, t.window_border);

    const text_color = rgb(0xFF, 0xFF, 0xFF);
    const sep_color = rgb(0x60, 0x60, 0x70);
    var iy: i32 = r.y + AERO_TRAY_FLYOUT_PAD;
    for (aero_tray_flyout_items) |item| {
        if (item.len == 3 and item[0] == '-') {
            fb.drawHLine(r.x + 6, iy + 4, r.w - 12, sep_color);
            iy += 10;
        } else {
            fb.drawTextTransparent(r.x + 10, iy + 5, item, text_color);
            iy += AERO_TRAY_FLYOUT_ROW;
        }
    }
}

fn aeroTrayFlyoutPick(px: i32, py: i32, scr_w: i32, scr_h: i32) ?usize {
    const r = aeroTrayFlyoutRect(scr_w, scr_h);
    if (!pointInRectI32(px, py, r.x, r.y, r.w, r.h)) return null;
    const pyi = @as(i64, py);
    var iy: i64 = @as(i64, r.y) + AERO_TRAY_FLYOUT_PAD;
    const row = @as(i64, AERO_TRAY_FLYOUT_ROW);
    for (aero_tray_flyout_items, 0..) |item, i| {
        if (item.len == 3 and item[0] == '-') {
            iy += 10;
            continue;
        }
        if (pyi >= iy and pyi < iy + row) return i;
        iy += row;
    }
    return null;
}

// ── Right-Click Context Menu ──

var ctx_menu_visible: bool = false;
var ctx_menu_x: i32 = 0;
var ctx_menu_y: i32 = 0;
/// 关闭壳层弹出后若干帧内跳过盒式模糊（减轻首帧后第一次整场景重绘在 Debug 下的整数/负载尖峰；与 AeroDesktopRuntime 右键菜单路径相关）。
var shell_blur_cooldown_frames: u8 = 0;

const ctx_menu_items = [_][]const u8{
    "View",
    "Sort By",
    "Refresh",
    "---",
    "New",
    "---",
    "Display Settings",
    "Personalize",
};

const CTX_ITEM_H: i32 = 24;
const CTX_MENU_W: i32 = 180;
const CTX_SEP_H: i32 = 8;

fn ctxMenuHeight() i32 {
    var h: i32 = 8;
    for (ctx_menu_items) |item| {
        if (item.len == 3 and item[0] == '-') {
            h += CTX_SEP_H;
        } else {
            h += CTX_ITEM_H;
        }
    }
    return h + 4;
}

pub fn showContextMenu(x: i32, y: i32) void {
    const h: i32 = @intCast(fb.getHeight());
    const w: i32 = @intCast(fb.getWidth());
    const menu_h: i32 = ctxMenuHeight();
    const tb_h: i32 = getTaskbarHeight();
    // 菜单锚点用 i64 计算，避免 `x+CTX_MENU_W` / `y+menu_h` 在 i32 上 Debug 溢出 panic（异常指针坐标或极端分辨率）。
    const wx = @as(i64, w);
    const hx = @as(i64, h);
    const xi = @as(i64, x);
    const yi = @as(i64, y);
    const mw = @as(i64, CTX_MENU_W);
    const mh = @as(i64, menu_h);
    const tb = @as(i64, tb_h);
    var mx = xi;
    if (mx + mw > wx) mx = wx - mw - 2;
    const work_bottom = hx - tb;
    var my = yi;
    if (my + mh > work_bottom) my = work_bottom - mh - 2;
    ctx_menu_x = clampI32FromI64(mx);
    ctx_menu_y = clampI32FromI64(my);
    ctx_menu_visible = true;
    cursor_plane.invalidate();
}

pub fn hideContextMenu() void {
    ctx_menu_visible = false;
    // 略长于 3 帧：关闭右键/壳层后多几帧跳过任务栏盒式模糊，减轻 Refresh 等与全帧叠加之 CPU 尖峰。
    shell_blur_cooldown_frames = 6;
    cursor_plane.invalidate();
}

pub fn isContextMenuVisible() bool {
    return ctx_menu_visible;
}

pub fn getContextMenuPaintRect() ShellRect {
    if (!ctx_menu_visible) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return .{ .x = ctx_menu_x, .y = ctx_menu_y, .w = CTX_MENU_W, .h = ctxMenuHeight() };
}

pub fn renderContextMenu() void {
    if (!ctx_menu_visible) return;
    const t = active_theme;
    const menu_h = ctxMenuHeight();

    // DWM shadow (soft offset)
    if (dwm_initialized and dwm_config.shadow_enabled) {
        renderShadow(ctx_menu_x, ctx_menu_y, CTX_MENU_W, menu_h, 4);
    } else {
        fb.fillRect(
            clampI32FromI64(@as(i64, ctx_menu_x) + 2),
            clampI32FromI64(@as(i64, ctx_menu_y) + 2),
            CTX_MENU_W,
            menu_h,
            rgb(0x20, 0x20, 0x20),
        );
    }

    fb.fillRect(ctx_menu_x, ctx_menu_y, CTX_MENU_W, menu_h, t.window_bg);
    if (dwm_initialized and dwm_config.glass_enabled) {
        // 小矩形避免盒式模糊，减轻右键菜单打开后整壳层路径的 CPU 压力。
        renderGlassTintOnly(ctx_menu_x, ctx_menu_y, CTX_MENU_W, menu_h, t.titlebar_active_left, .caption);
    }

    fb.drawRect(ctx_menu_x, ctx_menu_y, CTX_MENU_W, menu_h, t.window_border);

    const text_color: u32 = t.titlebar_text;
    const sep_color: u32 = rgb(0xB8, 0xB8, 0xC0);

    var iy: i32 = clampI32FromI64(@as(i64, ctx_menu_y) + 4);
    for (ctx_menu_items) |item| {
        if (item.len == 3 and item[0] == '-') {
            fb.drawHLine(clampI32FromI64(@as(i64, ctx_menu_x) + 4), iy + 3, CTX_MENU_W - 8, sep_color);
            iy += CTX_SEP_H;
        } else {
            fb.drawTextTransparent(clampI32FromI64(@as(i64, ctx_menu_x) + 28), iy + 4, item, text_color);
            iy += CTX_ITEM_H;
        }
    }
}

fn isInsideContextMenu(x: i32, y: i32) bool {
    if (!ctx_menu_visible) return false;
    const menu_h = ctxMenuHeight();
    return pointInRectI32(x, y, ctx_menu_x, ctx_menu_y, CTX_MENU_W, menu_h);
}

/// 左键在桌面上下文菜单内：可点项执行占位并关闭；分隔条不关闭；边距内点击关闭（与常见 Shell 一致）。
fn handleContextMenuLeftClick(px: i32, py: i32) bool {
    if (!ctx_menu_visible) return false;
    if (!isInsideContextMenu(px, py)) return false;

    const py_i = @as(i64, py);
    var iy: i64 = @as(i64, ctx_menu_y) + 4;
    for (ctx_menu_items) |item| {
        if (item.len == 3 and item[0] == '-') {
            if (py_i >= iy and py_i < iy + CTX_SEP_H) return true;
            iy += CTX_SEP_H;
            continue;
        }
        if (py_i >= iy and py_i < iy + CTX_ITEM_H) {
            if (std.mem.eql(u8, item, "Refresh")) {
                renderer_aero.cycleWallpaperPreset();
            }
            hideContextMenu();
            klog.info("Desktop context menu: %s", .{item});
            return true;
        }
        iy += CTX_ITEM_H;
    }
    hideContextMenu();
    return true;
}

// ── Cursor Rendering (Aero crystal style) ──
// The cursor uses a crystal/glass design with:
//   - Dark teal outline for sharp definition
//   - White fill for high visibility
//   - Glass highlight for upper-left interior (Aero reflective effect)
//   - Inner glow tint for depth perception
//   - Optional drop shadow when DWM is active

pub fn renderCursor(x: i32, y: i32) void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    if (!desktop_ctx.cursor_visible) return;

    const w_i32: i32 = @intCast(fb.getWidth());
    const h_i32: i32 = @intCast(fb.getHeight());
    const fw: i64 = @intCast(w_i32);
    const fh: i64 = @intCast(h_i32);

    // 0=transparent, 1=fill, 2=outline, 3=glass_highlight, 4=inner_glow（与 Aero `aero_cursor_shape.zig` 同源）
    const cursor_shape = aero_cursor_shape.pixels(desktop_cursor_kind).*;

    const scale: i32 = 1;
    const outline = rgb(0x00, 0x00, 0x00);
    const fill = rgb(0xFF, 0xFF, 0xFF);
    const glass_hi = rgb(0xC0, 0xE8, 0xF0);
    const inner_glow = rgb(0x40, 0x90, 0xA0);

    if (dwm_initialized and dwm_config.shadow_enabled) {
        for (cursor_shape, 0..) |row, dy| {
            for (row, 0..) |pixel, dx| {
                if (pixel == 2) {
                    const base_sx = @as(i64, x) + @as(i64, @intCast(dx)) * scale + scale;
                    const base_sy = @as(i64, y) + @as(i64, @intCast(dy)) * scale + scale;
                    var sy: i32 = 0;
                    while (sy < scale) : (sy += 1) {
                        var sx: i32 = 0;
                        while (sx < scale) : (sx += 1) {
                            const px64 = base_sx + sx;
                            const py64 = base_sy + sy;
                            if (px64 >= 0 and px64 < fw and py64 >= 0 and py64 < fh) {
                                fb.blendPixel(@intCast(px64), @intCast(py64), 0x00000000, 80);
                            }
                        }
                    }
                }
            }
        }
    }

    for (cursor_shape, 0..) |row, dy| {
        for (row, 0..) |pixel, dx| {
            if (pixel != 0) {
                const base_px = @as(i64, x) + @as(i64, @intCast(dx)) * scale;
                const base_py = @as(i64, y) + @as(i64, @intCast(dy)) * scale;
                const color: u32 = switch (pixel) {
                    1 => fill,
                    2 => outline,
                    3 => glass_hi,
                    4 => inner_glow,
                    else => fill,
                };
                var sy: i32 = 0;
                while (sy < scale) : (sy += 1) {
                    var sx: i32 = 0;
                    while (sx < scale) : (sx += 1) {
                        const px64 = base_px + sx;
                        const py64 = base_py + sy;
                        if (px64 >= 0 and px64 < fw and py64 >= 0 and py64 < fh) {
                            fb.putPixel32(@intCast(px64), @intCast(py64), color);
                        }
                    }
                }
            }
        }
    }
}

// ── Software cursor：实现位于 `cursor_plane.zig`（与主帧合成的概念分离，见 docs/cn/AeroDesktopRuntime.md §9、docs/cn/PointerPolicy_NT61.md） ──

/// 拖拽等局部 `flipDirty` 路径：并入旧/新指针矩形，避免漏拷贝光标区（与 dwm_compositor 表面脏标记互补）。
pub fn markCursorMotionDirtyRegions() void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    cursor_plane.markMotionDirty(
        desktop_ctx.smooth_cursor.prev_x,
        desktop_ctx.smooth_cursor.prev_y,
        desktop_ctx.cursor_x,
        desktop_ctx.cursor_y,
    );
}

pub fn softwareCursorInvalidate() void {
    cursor_plane.invalidate();
}

/// 预留：仅接 **公开** 硬件/固件文档中的 sprite/overlay（如 SoC 显示控制器、厂商数据手册），
/// 非 WDDM `DxgkDdiSetPointerShape` 等专有栈。`display.hardware_cursor=false` 时不做事。
pub fn notifyHardwareCursorIfAvailable() void {
    if (!config.isHardwareCursorEnabled()) return;
}

// ── Legacy Render Functions (backward compatibility) ──

pub fn renderGradientBackground(top_color: u32, bottom_color: u32) void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    fb.drawGradientV(0, 0, @intCast(desktop_ctx.surface.width), @intCast(desktop_ctx.surface.height), top_color, bottom_color);
    desktop_ctx.frame_count += 1;
}

pub fn renderLegacyTaskbar(x: i32, y: i32, w: i32, h: i32, top_color: u32, bottom_color: u32) void {
    if (!use_framebuffer) return;
    fb.drawGradientV(x, y, w, h, top_color, bottom_color);
}

pub fn renderLegacyStartButton(x: i32, y: i32, w: i32, h: i32, top_color: u32, bottom_color: u32) void {
    if (!use_framebuffer) return;
    fb.drawGradientV(x, y, w, h, top_color, bottom_color);
    fb.drawRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));
}

pub fn renderWindow(x: i32, y: i32, w: i32, h: i32, titlebar_left: u32, titlebar_right: u32, border_color: u32, bg_color: u32, titlebar_height: i32) void {
    if (!use_framebuffer) return;
    fb.fillRect(x, y + titlebar_height, w, h - titlebar_height, bg_color);
    fb.drawGradientH(x, y, w, titlebar_height, titlebar_left, titlebar_right);
    fb.drawRect(x, y, w, h, border_color);
}

pub fn renderDesktopIcon(x: i32, y: i32, icon_size: i32, icon_color: u32, selected: bool) void {
    if (!use_framebuffer) return;
    fb.fillRect(x + 4, y + 4, icon_size - 8, icon_size - 8, icon_color);
    fb.drawRect(x + 4, y + 4, icon_size - 8, icon_size - 8, rgb(0x80, 0x80, 0x80));
    if (selected) {
        fb.drawRect(x, y, icon_size, icon_size, rgb(0x31, 0x6A, 0xC5));
    }
}

pub fn renderStartMenu(x: i32, y: i32, w: i32, h: i32, bg_color: u32, header_color: u32, header_height: i32) void {
    if (!use_framebuffer) return;
    fb.fillRect(x, y, w, h, bg_color);
    fb.fillRect(x, y, w, header_height, header_color);
    fb.drawRect(x, y, w, h, rgb(0x80, 0x80, 0x80));
}

pub fn renderLoginScreen(width: u32, height: u32, top_color: u32, bottom_color: u32, panel_color: u32) void {
    if (!use_framebuffer) return;
    fb.drawGradientV(0, 0, @intCast(width), @intCast(height), top_color, bottom_color);
    const pw: i32 = 400;
    const ph: i32 = 300;
    const px: i32 = @intCast((width - @as(u32, @intCast(pw))) / 2);
    const py: i32 = @intCast((height - @as(u32, @intCast(ph))) / 2);
    fb.fillRect(px, py, pw, ph, panel_color);
    fb.drawRect(px, py, pw, ph, rgb(0x80, 0x80, 0x80));
}

// ── Present / VSync ──
//
// **诚实边界**：`desktop_ctx.vsync_enabled` 与 `config.isVsyncEnabled()` 仅表达策略位；当前帧节奏由调度器 tick /
// 壳层泵循环决定，**非** WDDM 垂直空白硬件等待。未来若在真实显示 miniport 上实现 `DxgkDdiPresent` 类路径，
// 应在此调用 HAL 级 `waitForVerticalBlank`（WDK 行为级描述），与下列辅助函数对接。
// Ref: https://learn.microsoft.com/windows-hardware/drivers/display/vsync-propagation-in-windows-vista-and-later

/// 方案 A 演进：在 `present()` 之前登记本帧脏区，并入 `framebuffer` 脏矩形列表（相交合并策略见 `addDirtyRect`）。
/// 用户态/Win32k 未来经 IOCTL 或 LPC 载荷提交等价矩形时，应调用此入口或共享同一合并路径，避免双轨脏区。
/// 帧序号：`present()` 后 `getFrameCount()` 递增；`dwm_compositor.notifyFramePresented()` 在 `present()` 内推进 `getFrameNumber()`。
/// Ref: docs/cn/DesktopManagerSpec.md §1.1
pub fn submitCompositorPresentHints(dirty_opt: ?fb.Rect) void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    if (dirty_opt) |r| {
        if (r.w > 0 and r.h > 0) fb.addDirtyRect(r);
    }
}

/// 只读：桌面 present 计数与 DWM 合成器帧序号（`present()` 末尾两者均会更新，调用顺序见 `submitCompositorPresentHints` 文档）。
pub fn getPresentTelemetry() struct { desktop_frames: u64, compositor_frames: u64 } {
    return .{
        .desktop_frames = desktop_ctx.frame_count,
        .compositor_frames = dwm_comp.getFrameNumber(),
    };
}

pub fn getDesktopComposeTelemetry() struct { full_scene_frames: u64, partial_frames: u64 } {
    return .{
        .full_scene_frames = desktop_compose_full_scene_frames,
        .partial_frames = desktop_compose_partial_frames,
    };
}

/// 合成是否**请求**软件 VSync 语义（与 `present()` 内实际等待分离，便于 bisect）。
pub fn isDesktopVsyncPolicyEnabled() bool {
    return desktop_ctx.vsync_enabled and config.isVsyncEnabled();
}

pub fn present() void {
    if (!use_framebuffer) return;
    // VirtIO-GPU：`flipDirty` 且脏外包 ≤32×32 时尝试 `trySubmitFramebufferDirtyRect`（PoC，与 init 4×4 往返同命令路径）；失败或非 offload 不影响 CPU 提交。
    // 首帧强制整幅 flip：LoongArch+QEMU 双缓冲下若脏矩形与合成路径偶发不同步，屏上可长期黑/花；后续帧仍可按配置走 flipDirty。
    const first_present = (desktop_ctx.present_count == 0);
    // 双缓冲：`present_full_flip` 默认整幅 memcpy（避免漏画光标区）；关则用脏矩形 flipDirty（须完整 mark dirty）。
    if (fb.isDoubleBuffered()) {
        if (config.isPresentFullFlipEnabled() or first_present) {
            fb.flip();
        } else {
            // VirtIO-GPU：小脏区可走 `trySubmitFramebufferDirtyRect`（≤32×32）做 PoC 级传输自检；主路径仍以 CPU flipDirty。
            if (virtio_gpu_pci.compositorOffloadAvailable()) {
                if (fb.peekDirtyUnionPx()) |r| {
                    const rw: u32 = @intCast(r.w);
                    const rh: u32 = @intCast(r.h);
                    if (rw > 0 and rh > 0 and rw <= 32 and rh <= 32) {
                        _ = virtio_gpu_pci.trySubmitFramebufferDirtyRect(fb.getWidth(), fb.getHeight(), @intCast(r.x), @intCast(r.y), rw, rh);
                    }
                }
            }
            fb.flipDirty();
        }
    } else {
        fb.flipDirty();
    }
    notifyHardwareCursorIfAvailable();
    if (dwm_comp.isInitialized()) {
        dwm_comp.notifyFramePresented();
    }
    desktop_ctx.present_count += 1;
    desktop_ctx.frame_count += 1;
    display_flip_journal.notePresentFlip();
}

pub fn presentFull() void {
    if (!use_framebuffer) return;
    fb.flip();
    notifyHardwareCursorIfAvailable();
    desktop_ctx.present_count += 1;
    desktop_ctx.frame_count += 1;
    display_flip_journal.notePresentFlip();
}

pub fn setCursorPosition(x: i32, y: i32) void {
    desktop_ctx.cursor_x = x;
    desktop_ctx.cursor_y = y;
}

// ── Public Accessors for Renderer Modules ──

pub const DragState = struct {
    explorer_active: bool,
    taskmgr_active: bool,
    builtin_active: bool,
    explorer_prev: ShellRect,
    taskmgr_prev: ShellRect,
    builtin_prev: ShellRect,
};

pub fn getDragState() DragState {
    const bd = builtin_apps.getDragState();
    return .{
        .explorer_active = drag_active,
        .taskmgr_active = taskmgr_drag_active,
        .builtin_active = bd.active,
        .explorer_prev = explorer_drag_prev_rect,
        .taskmgr_prev = taskmgr_drag_prev_rect,
        .builtin_prev = .{ .x = bd.prev.x, .y = bd.prev.y, .w = bd.prev.w, .h = bd.prev.h },
    };
}

pub fn isDragging() bool {
    return drag_active or taskmgr_drag_active;
}

pub fn getTaskMgrPos() struct { x: i32, y: i32 } {
    return .{ .x = taskmgr_x, .y = taskmgr_y };
}

pub fn setExplorerDragPrev(r: ShellRect) void {
    explorer_drag_prev_rect = r;
}

pub fn setTaskMgrDragPrev(r: ShellRect) void {
    taskmgr_drag_prev_rect = r;
}

pub fn renderCursorAt() void {
    const cx = desktop_ctx.cursor_x;
    const cy = desktop_ctx.cursor_y;
    renderCursor(cx, cy);
}

pub fn incFrameCount() void {
    desktop_ctx.frame_count += 1;
}

// ── IRP Dispatch ──

fn displayDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => return handleIoctl(irp),
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

fn handleIoctl(irp: *io.Irp) io.IoStatus {
    switch (irp.ioctl_code) {
        IOCTL_DISPLAY_GET_STATE => {
            irp.complete(.success, @intFromEnum(display_state));
            return .success;
        },
        IOCTL_DISPLAY_GET_SURFACE => {
            irp.buffer_ptr = desktop_ctx.surface.address;
            irp.bytes_transferred = desktop_ctx.surface.pitch * desktop_ctx.surface.height;
            irp.complete(.success, desktop_ctx.surface.width);
            return .success;
        },
        IOCTL_DISPLAY_SET_BG_COLOR => {
            const color: u32 = @truncate(irp.buffer_ptr);
            renderDesktopBackground(color);
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_DISPLAY_PRESENT => {
            present();
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_DISPLAY_ENUMERATE => {
            irp.complete(.success, if (use_hdmi) hdmi_driver.getOutputCount() else 1);
            return .success;
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

// ── State Query ──

pub fn getDisplayState() DisplayState {
    return display_state;
}

pub fn getDisplayMode() DisplayMode {
    return display_mode;
}

pub fn getSurface() *const Surface {
    return &desktop_ctx.surface;
}

pub fn getDesktopContext() *const DesktopContext {
    return &desktop_ctx;
}

pub fn getFrameCount() u64 {
    return desktop_ctx.frame_count;
}

pub fn getPresentCount() u64 {
    return desktop_ctx.present_count;
}

/// 多监视器 / 虚拟桌面外包（与 `framebuffer.MonitorLayoutNt61` 同步；单 GOP 时为单监视器）。
pub fn getDesktopMonitorLayoutCount() u32 {
    return fb.getMonitorLayoutCount();
}

pub fn getDesktopMonitorLayout(index: u32) ?fb.MonitorLayoutNt61 {
    return fb.getMonitorLayout(index);
}

pub fn getVirtualDesktopBoundsRect() fb.Rect {
    return fb.getVirtualDesktopBounds();
}

/// 主监视器 DPI 下物理像素 → 逻辑像素（无监视器信息时按 96 DPI）。
pub fn physicalToLogicalDesktopPx(physical_px: i32, physical_py: i32) struct { lx: i32, ly: i32 } {
    const m = fb.getMonitorLayout(0) orelse return .{ .lx = physical_px, .ly = physical_py };
    return .{
        .lx = fb.physicalToLogicalPx(m.effective_dpi_x, physical_px),
        .ly = fb.physicalToLogicalPx(m.effective_dpi_y, physical_py),
    };
}

/// Aero：在首次 `present()` 之前跳过盒式模糊，首屏尽快可见（DesktopManagerSpec 合成节拍）。
/// 拖窗时用轻量单遍模糊替代「完全跳过」，兼顾帧率与玻璃观感。
/// 与 `renderDesktopFrameEx` 内 `setGlassLiteBlurEnabled(shell_glass_lite)` 的关系：本函数在帧后期多次调用，**后写者优先**；预算仍只在 `boxBlurRect` 成功路径扣减（`dwm_blur_budget.zig`）。
fn syncAeroGlassFastPath() void {
    const during_drag = drag_active or taskmgr_drag_active or builtin_apps.isDragging();
    var first = desktop_ctx.present_count == 0;
    if (shell_blur_cooldown_frames > 0) first = true;
    dwm_mod.setSkipGlassBoxBlur(first);
    dwm_mod.setGlassLiteBlurEnabled(during_drag and !first);
}

pub fn isDesktopReady() bool {
    return display_state == .desktop_mode and use_framebuffer and fb.isInitialized();
}

pub fn isInitialized() bool {
    return driver_initialized;
}

// ── Initialization ──

pub fn init() void {
    vga_driver.init();
    hdmi_driver.init();
    use_hdmi = hdmi_driver.isInitialized();

    driver_idx = io.registerDriver("\\Driver\\Display", displayDispatch) orelse {
        klog.err("Display: Failed to register driver", .{});
        return;
    };

    device_idx = io.createDevice("\\Device\\Display0", .framebuffer, driver_idx) orelse {
        klog.err("Display: Failed to create device", .{});
        return;
    };

    driver_initialized = true;

    klog.info("Display Manager: initialized (VGA=%s, HDMI=%s)", .{
        if (vga_driver.isInitialized()) "ready" else "n/a",
        if (use_hdmi) "ready" else "n/a",
    });
}
