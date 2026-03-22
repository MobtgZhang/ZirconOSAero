//! Display Manager / Desktop Compositor — Windows 7 Aero (NT 6.1)
//!
//! Screen space (same as Windows / top-left origin): **(0,0) = top-left**, X increases
//! **right**, Y increases **down**. Taskbar occupies `y ∈ [scr_h - tb_h, scr_h)`.

const builtin = @import("builtin");
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

pub const theme_mod = @import("theme.zig");
pub const dwm_mod = @import("dwm.zig");
pub const renderer_aero = @import("renderer_aero.zig");

const is_x86 = (builtin.target.cpu.arch == .x86_64);

pub const ThemeColors = theme_mod.ThemeColors;

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
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

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;

var use_framebuffer: bool = false;
var use_hdmi: bool = false;

// ── Layout Constants ──

const TASKBAR_H: i32 = 30;
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
/// 双行标题（主标题 + 副标题）需 ≥34px，避免与客户端首行工具栏视觉重叠。
pub const AERO_TITLEBAR_H: i32 = 36;
pub const AERO_CLIENT_INSET: i32 = 2;
/// 与 renderer_aero.renderExplorerContent 中命令栏/地址栏高度一致（用于命中测试）。
pub const AERO_EXPLORER_CMD_H: i32 = 28;
pub const AERO_EXPLORER_ADDR_H: i32 = 26;

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
    fb.init(fb_addr, width, height, pitch, bpp, pixel_bgr);
    use_framebuffer = true;

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
}

pub fn initTextMode() void {
    vga_driver.init();
    vga_driver.setTextMode();
    display_state = .text_mode;
    display_mode = .text;
}

// ══════════════════════════════════════════════════════════════
//  Desktop Rendering (theme-aware)
// ══════════════════════════════════════════════════════════════

pub fn clearFramebuffer() void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    fb.clearScreen(0x00000000);
}

pub const ShellRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub fn rectUnion(a: ShellRect, b: ShellRect) ShellRect {
    const x1 = @min(a.x, b.x);
    const y1 = @min(a.y, b.y);
    const x2 = @max(a.x + a.w, b.x + b.w);
    const y2 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

pub fn rectInflate(r: ShellRect, p: i32) ShellRect {
    return .{ .x = r.x - p, .y = r.y - p, .w = r.w + 2 * p, .h = r.h + 2 * p };
}

pub fn rectClampToScreen(r: ShellRect, scr_w: i32, scr_h: i32) ShellRect {
    var x = r.x;
    var y = r.y;
    var rw = r.w;
    var rh = r.h;
    if (x < 0) {
        rw += x;
        x = 0;
    }
    if (y < 0) {
        rh += y;
        y = 0;
    }
    if (x + rw > scr_w) rw = scr_w - x;
    if (y + rh > scr_h) rh = scr_h - y;
    if (rw < 0) rw = 0;
    if (rh < 0) rh = 0;
    return .{ .x = x, .y = y, .w = rw, .h = rh };
}

pub fn rectIntersection(a: ShellRect, b: ShellRect) ?ShellRect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x + a.w, b.x + b.w);
    const y2 = @min(a.y + a.h, b.y + b.h);
    if (x2 <= x1 or y2 <= y1) return null;
    return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

pub fn patchVerticalGradientRegion(scr_w: i32, scr_h: i32, rx: i32, ry: i32, rw: i32, rh: i32, topc: u32, botc: u32) void {
    var r = ShellRect{ .x = rx, .y = ry, .w = rw, .h = rh };
    r = rectClampToScreen(r, scr_w, scr_h);
    if (r.w <= 0 or r.h <= 0 or scr_h <= 0) return;
    const gh: u32 = @intCast(scr_h);
    const t1 = @as(u32, @intCast(@max(0, @min(r.y, scr_h - 1))));
    const t2 = @as(u32, @intCast(@max(0, @min(r.y + r.h - 1, scr_h - 1))));
    const c_top = fb.interpolateColor(topc, botc, t1, gh);
    const c_bot = fb.interpolateColor(topc, botc, t2, gh);
    fb.drawGradientV(r.x, r.y, r.w, r.h, c_top, c_bot);
}

/// Harmony wallpaper patch (gradient + bloom overlays) for drag-dirty rectangles only.
fn patchHarmonyWallpaperRegion(scr_w: i32, scr_h: i32, rx: i32, ry: i32, rw: i32, rh: i32) void {
    const topc = rgb(0x08, 0x1E, 0x42);
    const botc = rgb(0x04, 0x12, 0x28);
    patchVerticalGradientRegion(scr_w, scr_h, rx, ry, rw, rh, topc, botc);
    var r = ShellRect{ .x = rx, .y = ry, .w = rw, .h = rh };
    r = rectClampToScreen(r, scr_w, scr_h);
    if (r.w <= 0 or r.h <= 0) return;

    const bloom1 = ShellRect{ .x = @divTrunc(scr_w, 4), .y = @divTrunc(scr_h, 10), .w = @divTrunc(scr_w, 2), .h = @divTrunc(scr_h * 2, 5) };
    if (rectIntersection(r, bloom1)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x28, 0x58, 0x90), 20, 255);
    }
    const mx = @divTrunc(scr_w, 2);
    const my = @divTrunc(scr_h * 2, 5);
    const bloom2 = ShellRect{ .x = mx - 200, .y = my - 130, .w = 400, .h = 300 };
    if (rectIntersection(r, bloom2)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x38, 0x68, 0xA0), 16, 255);
    }
    const bloom3 = ShellRect{ .x = @divTrunc(scr_w, 8), .y = @divTrunc(scr_h, 6), .w = @divTrunc(scr_w, 3), .h = @divTrunc(scr_h, 4) };
    if (rectIntersection(r, bloom3)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x50, 0x78, 0xA8), 12, 255);
    }
    const vstrip: i32 = 28;
    const vig_top = ShellRect{ .x = 0, .y = 0, .w = scr_w, .h = vstrip };
    if (rectIntersection(r, vig_top)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x00, 0x04, 0x12), 38, 255);
    }
    const vig_bot = ShellRect{ .x = 0, .y = scr_h - vstrip, .w = scr_w, .h = vstrip };
    if (rectIntersection(r, vig_bot)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x00, 0x02, 0x0A), 48, 255);
    }
    const vig_left = ShellRect{ .x = 0, .y = 0, .w = vstrip, .h = scr_h };
    if (rectIntersection(r, vig_left)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x00, 0x04, 0x10), 32, 255);
    }
    const vig_right = ShellRect{ .x = scr_w - vstrip, .y = 0, .w = vstrip, .h = scr_h };
    if (rectIntersection(r, vig_right)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x00, 0x04, 0x10), 32, 255);
    }
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
        const cur = ShellRect{ .x = taskmgr_x, .y = taskmgr_y, .w = 320, .h = 260 };
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





fn renderCurrentDesktop() void {
    syncAeroGlassFastPath();
    renderer_aero.renderFrame();
}

/// Returns the taskbar height for the active theme.
pub fn getTaskbarHeight() i32 {
    return 40;
}

/// Align DWM smooth-cursor state with the PS/2 driver so the first painted frame
/// shows the pointer at the correct position (typically screen center).
pub fn syncCursorFromMouse() void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    if (!is_x86) return;
    const mouse = @import("../input/mouse.zig");
    const mx = mouse.getX();
    const my = mouse.getY();
    const P: i32 = 256;
    desktop_ctx.smooth_cursor.sub_x = mx * P;
    desktop_ctx.smooth_cursor.sub_y = my * P;
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

/// Bottom-right status line: theme + resolution + DWM (above taskbar, not top-left banner).
fn buildSystemInfoText() []const u8 {
    var buf: [96]u8 = undefined;
    var pos: usize = 0;
    const prefix = "ZirconOS | ";
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
    return buf[0..pos];
}

pub fn drawSystemInfoStrip(scr_w: i32, scr_h: i32, tb_h: i32) void {
    const text = buildSystemInfoText();
    const scale: u32 = 2;
    const tw = fb.textWidthScaled(text, scale);
    const pad: i32 = 12;
    const strip_h: i32 = @as(i32, @intCast(16 * scale)) + 8;
    const bar_y = scr_h - tb_h - strip_h;
    if (bar_y < 4) return;
    const bar_w = @min(scr_w - 16, tw + pad * 2);
    const bar_x = scr_w - bar_w - 8;

    fb.fillRect(bar_x, bar_y, bar_w, strip_h, rgb(0x18, 0x1A, 0x22));
    fb.drawRect(bar_x, bar_y, bar_w, strip_h, rgb(0x50, 0x5C, 0x70));
    fb.drawHLine(bar_x + 1, bar_y + 1, bar_w - 2, rgb(0x35, 0x3D, 0x4A));

    const tx = bar_x + bar_w - tw - pad;
    const ty = bar_y + @divTrunc(strip_h - @as(i32, @intCast(16 * scale)), 2);
    fb.drawTextTransparentScaled(tx, ty, text, rgb(0xE4, 0xE8, 0xF2), scale);
}

pub fn renderDesktopFrame() void {
    if (!use_framebuffer or !fb.isInitialized()) return;

    if (is_x86) {
        const mouse = @import("../../drivers/input/mouse.zig");

        while (mouse.isInterpolating()) {
            mouse.interpolateStep();
        }

        const raw_x = mouse.getX();
        const raw_y = mouse.getY();

        updateSmoothCursor(raw_x, raw_y);
        desktop_ctx.cursor_x = desktop_ctx.smooth_cursor.display_x;
        desktop_ctx.cursor_y = desktop_ctx.smooth_cursor.display_y;

        renderCurrentDesktop();
        mouse.clearCursorMoved();
    } else {
        renderCurrentDesktop();
    }
}

fn updateSmoothCursor(raw_x: i32, raw_y: i32) void {
    const sc = &desktop_ctx.smooth_cursor;
    sc.target_x = raw_x;
    sc.target_y = raw_y;

    sc.prev_x = sc.display_x;
    sc.prev_y = sc.display_y;

    // With double buffering, the entire frame (including cursor) is drawn
    // off-screen and presented atomically.  No interpolation lag needed.
    sc.display_x = raw_x;
    sc.display_y = raw_y;

    const P: i32 = 256;
    sc.sub_x = raw_x * P;
    sc.sub_y = raw_y * P;

    const w_i32: i32 = @intCast(fb.getWidth());
    const h_i32: i32 = @intCast(fb.getHeight());
    if (sc.display_x < 0) sc.display_x = 0;
    if (sc.display_y < 0) sc.display_y = 0;
    if (sc.display_x >= w_i32) sc.display_x = w_i32 - 1;
    if (sc.display_y >= h_i32) sc.display_y = h_i32 - 1;

    sc.is_moving = (sc.display_x != sc.prev_x or sc.display_y != sc.prev_y);
}

pub fn toggleStartMenu() void {
    startmenu.toggle(.aero);
}

pub fn isStartMenuVisible() bool {
    return startmenu.isVisible();
}

pub fn hideStartMenu() void {
    startmenu.hide();
}

/// PS/2 键盘快捷键（如 Ctrl+Shift+Esc → 任务管理器）。返回 true 时需整屏重绘。
pub fn handleDesktopHotkeys() bool {
    if (builtin.target.cpu.arch != .x86_64) return false;
    if (!@import("../../arch.zig").consumeTaskMgrHotkey()) return false;
    bringTaskManagerToFront();
    return true;
}

fn bringTaskManagerToFront() void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    const scr_w: i32 = @intCast(fb.getWidth());
    const scr_h: i32 = @intCast(fb.getHeight());
    const tm_w: i32 = 320;
    const tm_h: i32 = 260;
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
    const tb_y = scr_h - tb_h;
    if (click_y < tb_y or click_y >= scr_h) return false;

    // 与 renderer_aero renderTaskbar：orb_x=4, orb_sz=36
    const orb_x: i32 = 4;
    const orb_w: i32 = 36;
    return click_x >= orb_x - 2 and click_x < orb_x + orb_w + 6 and click_y < tb_y + tb_h;
}

fn taskMgrWindowContains(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    initTaskMgrPosition(scr_w, scr_h);
    const tm_w: i32 = 320;
    const tm_h: i32 = 260;
    return px >= taskmgr_x and px < taskmgr_x + tm_w and
        py >= taskmgr_y and py < taskmgr_y + tm_h;
}

fn taskMgrTitlebarHit(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    initTaskMgrPosition(scr_w, scr_h);
    const tm_w: i32 = 320;
    const cap = shellTitlebarH();
    return px >= taskmgr_x and px < taskmgr_x + tm_w and
        py >= taskmgr_y and py < taskmgr_y + cap;
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
    if (px < cr.x or px >= cr.x + cr.w or py < cr.y or py >= cr.y + cr.h) return false;
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
    const h: i32 = @intCast(fb.getHeight());
    const w: i32 = @intCast(fb.getWidth());

    if (ctx_menu_visible) {
        if (!isInsideContextMenu(x, y)) {
            hideContextMenu();
            return true;
        }
        return false;
    }

    if (isStartButtonClick(x, y, w, h)) {
        toggleStartMenu();
        return true;
    }

    if (startmenu.isVisible()) {
        const menu_r = startmenu.getMenuRect(w, h);
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
        }
    }

    const tb_h = getTaskbarHeight();
    const tb_y = h - tb_h;
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
        if (x >= fr.x and x < fr.x + fr.w and y >= fr.y and y < fr.y + fr.h) {
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

    initTaskMgrPosition(w, h);
    if (taskMgrWindowContains(x, y, w, h)) {
        if (taskMgrTitlebarHit(x, y, w, h)) {
            taskmgr_drag_active = true;
            taskmgr_drag_off_x = x - taskmgr_x;
            taskmgr_drag_off_y = y - taskmgr_y;
            taskmgr_drag_prev_rect = .{ .x = taskmgr_x, .y = taskmgr_y, .w = 320, .h = 260 };
            return true;
        }
        return false;
    }
    const wr = getWindowRect(w, h);
    const cap_h = shellTitlebarH();
    if (x >= wr.x and x < wr.x + wr.w and y >= wr.y and y < wr.y + cap_h) {
        drag_active = true;
        drag_offset_x = x - window_x;
        drag_offset_y = y - window_y;
        explorer_drag_prev_rect = .{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h };
        return true;
    }
    if (x >= wr.x and x < wr.x + wr.w and y >= wr.y and y < wr.y + wr.h) {
        if (aeroExplorerClientClick(x, y, w, h)) return true;
    }
    return false;
}

pub fn handleRightClick(x: i32, y: i32) bool {
    const h: i32 = @intCast(fb.getHeight());
    const tb_y = h - getTaskbarHeight();

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

/// 返回 true 表示开始菜单高亮变化，需要整屏重绘（与纯指针移动区分）。
pub fn handleMouseMove(x: i32, y: i32) bool {
    desktop_ctx.smooth_cursor.target_x = x;
    desktop_ctx.smooth_cursor.target_y = y;

    var hover_changed = false;
    if (is_x86 and startmenu.isVisible()) {
        const w: i32 = @intCast(fb.getWidth());
        const h: i32 = @intCast(fb.getHeight());
        hover_changed = startmenu.updatePointerHover(x, y, w, h);
    }

    if (drag_active) {
        const scr_w: i32 = @intCast(fb.getWidth());
        const scr_h: i32 = @intCast(fb.getHeight());
        window_x = x - drag_offset_x;
        window_y = y - drag_offset_y;
        const dim = computeSampleWindowDims(scr_w, scr_h);
        const pad: i32 = 2;
        if (window_x < pad) window_x = pad;
        if (window_x + dim.w > scr_w - pad) window_x = scr_w - dim.w - pad;
        if (window_y < 0) window_y = 0;
        {
            const cap = shellTitlebarH();
            if (window_y > scr_h - getTaskbarHeight() - cap) window_y = scr_h - getTaskbarHeight() - cap;
        }
    }
    if (taskmgr_drag_active) {
        const scr_w: i32 = @intCast(fb.getWidth());
        const scr_h: i32 = @intCast(fb.getHeight());
        initTaskMgrPosition(scr_w, scr_h);
        const tm_w: i32 = 320;
        const tm_h: i32 = 260;
        taskmgr_x = x - taskmgr_drag_off_x;
        taskmgr_y = y - taskmgr_drag_off_y;
        const pad: i32 = 2;
        if (taskmgr_x < pad) taskmgr_x = pad;
        if (taskmgr_y < pad) taskmgr_y = pad;
        if (taskmgr_x + tm_w > scr_w - pad) taskmgr_x = scr_w - tm_w - pad;
        if (taskmgr_y + tm_h > scr_h - getTaskbarHeight() - pad) {
            taskmgr_y = scr_h - getTaskbarHeight() - tm_h - pad;
        }
    }
    return hover_changed;
}

/// 拖动资源管理器或任务管理器标题栏时，仅在指针实际移动时需要重绘（见 main 循环）。
pub fn isWindowDragging() bool {
    return drag_active or taskmgr_drag_active;
}

pub fn handleMouseRelease() void {
    drag_active = false;
    taskmgr_drag_active = false;
}

pub fn renderAeroDesktop() void {
    syncAeroGlassFastPath();
    renderer_aero.render();
}

/// Harmony-style wallpaper (Zircon brand: deep blue + soft bloom + edge vignette; Aero 7 氛围)
fn renderHarmonyStyleWallpaper(w: i32, h: i32) void {
    fb.drawGradientV(0, 0, w, h, rgb(0x08, 0x1E, 0x42), rgb(0x04, 0x12, 0x28));
    fb.blendTintRect(@divTrunc(w, 4), @divTrunc(h, 10), @divTrunc(w, 2), @divTrunc(h * 2, 5), rgb(0x28, 0x58, 0x90), 20, 255);
    const mx = @divTrunc(w, 2);
    const my = @divTrunc(h * 2, 5);
    fb.blendTintRect(mx - 200, my - 130, 400, 300, rgb(0x38, 0x68, 0xA0), 16, 255);
    // 次要光晕（Win7 Harmony 常见：中上偏左的淡青高光）
    fb.blendTintRect(@divTrunc(w, 8), @divTrunc(h, 6), @divTrunc(w, 3), @divTrunc(h, 4), rgb(0x50, 0x78, 0xA8), 12, 255);
    // 四边暗角，增强景深与任务栏玻璃对比
    const vstrip: i32 = 28;
    fb.blendTintRect(0, 0, w, vstrip, rgb(0x00, 0x04, 0x12), 38, 255);
    fb.blendTintRect(0, h - vstrip, w, vstrip, rgb(0x00, 0x02, 0x0A), 48, 255);
    fb.blendTintRect(0, 0, vstrip, h, rgb(0x00, 0x04, 0x10), 32, 255);
    fb.blendTintRect(w - vstrip, 0, vstrip, h, rgb(0x00, 0x04, 0x10), 32, 255);
}

fn renderAeroGadgetCpu(w: i32, h: i32, tb_h: i32, t: *const ThemeColors) void {
    _ = tb_h;
    const cx = w - 110;
    const cy = @divTrunc(h, 4);
    const r: i32 = 46;
    const bx = cx - r;
    const by = cy - r;
    if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassEffect(bx, by, r * 2, r * 2, dwm_config.glass_tint_color, .panel);
    } else {
        fb.fillRoundedRect(bx, by, r * 2, r * 2, r, rgb(0x20, 0x34, 0x50));
    }
    fb.drawTextTransparent(bx + 30, by + 16, "23%", t.icon_text);
    fb.drawTextTransparent(bx + 26, by + 32, "0K/s", rgb(0xAA, 0xCC, 0xEE));
}

fn renderAeroBackground(w: i32, h: i32, t: *const ThemeColors) void {
    _ = t;
    renderHarmonyStyleWallpaper(w, h);
}

fn renderAeroTaskbar(scr_w: i32, scr_h: i32, t: *const ThemeColors, tb_h: i32) void {
    // y = scr_h - tb_h: bottom-aligned bar (Y downward, origin top-left)
    const tb_y = scr_h - tb_h;

    // Align with Sun Valley: when glass is on, tint the wallpaper under the bar (blur skipped
    // for .taskbar). A separate opaque gradient + caption-tint read as "invisible" on Harmony blue.
    if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassEffect(0, tb_y, scr_w, tb_h, rgb(0x28, 0x40, 0x60), .taskbar);
    } else {
        fb.drawGradientV(0, tb_y, scr_w, tb_h, t.taskbar_top, t.taskbar_bottom);
    }
    fb.drawHLine(0, tb_y, scr_w, rgb(0x58, 0x78, 0xA8));

    const peek_w: i32 = 12;
    // Quick launch + tray：与 aero_tray.layout 一致（Show Desktop 条宽度 = peek_w）。
    const icon_s: u32 = 2;
    const icon_px: i32 = icons.getIconTotalSize(icon_s);
    const icon_s_apps: u32 = 1;

    // Start orb — Zircon logo on glassy circle (resources/logo.svg style)
    const orb_x: i32 = 4;
    const orb_y = tb_y + 2;
    const orb_sz: i32 = 36;
    fb.fillRoundedRect(orb_x, orb_y, orb_sz, orb_sz, 18, rgb(0x24, 0x4A, 0x80));
    fb.drawGradientV(orb_x + 1, orb_y + 1, orb_sz - 2, @divTrunc(orb_sz - 2, 2), rgb(0x50, 0x82, 0xC0), rgb(0x28, 0x50, 0x88));
    fb.blendTintRect(orb_x + 6, orb_y + 4, orb_sz - 12, 8, rgb(0xE8, 0xF4, 0xFF), 55, 255);
    renderZirconLogo(orb_x + 11, orb_y + 11);

    // Quick launch — ZirconOSAero/resources/icons/*.svg → embedded Aero bitmaps
    const ql_ids = [_]icons.IconId{ .browser, .terminal, .documents };
    var qx: i32 = orb_x + orb_sz + 8;
    for (ql_ids) |iid| {
        const qy = tb_y + @divTrunc(tb_h - icon_px, 2);
        icons.drawThemedIcon(iid, qx, qy, icon_s, .aero);
        qx += icon_px + 6;
    }

    fb.drawVLine(qx + 2, tb_y + 5, tb_h - 10, rgb(0x50, 0x70, 0x90));

    const app_items = [_]struct { id: icons.IconId, text: []const u8, active: bool }{
        .{ .id = .computer, .text = "Computer", .active = true },
        .{ .id = .computer, .text = "Core", .active = false },
        .{ .id = .terminal, .text = "CMD", .active = false },
    };
    var ax = qx + 10;
    for (app_items) |app| {
        const ay = tb_y + @divTrunc(tb_h - 28, 2);
        const bw: i32 = 102;
        if (app.active) {
            fb.fillRoundedRect(ax, ay, bw, 28, 4, rgb(0x50, 0x80, 0xB8));
            fb.fillRect(ax + 2, ay + 2, bw - 4, 11, rgb(0x78, 0xA8, 0xD8));
            fb.drawRect(ax, ay, bw, 28, rgb(0x90, 0xB8, 0xE8));
        } else {
            fb.fillRoundedRect(ax, ay, bw, 28, 4, rgb(0x30, 0x48, 0x68));
            fb.drawRect(ax, ay, bw, 28, rgb(0x40, 0x58, 0x78));
        }
        icons.drawThemedIcon(app.id, ax + 4, ay + 6, icon_s_apps, .aero);
        fb.drawTextTransparent(ax + 22, ay + 8, app.text, rgb(0xFF, 0xFF, 0xFF));
        ax += bw + 6;
    }

    const tray = aero_tray.layout(scr_w, scr_h, tb_h);
    if (tray.shelf_w > 4 and tray.shelf_h > 4) {
        fb.fillRoundedRect(tray.shelf_x, tray.shelf_y, tray.shelf_w, tray.shelf_h, 5, rgb(0x10, 0x1C, 0x30));
        fb.blendTintRect(tray.shelf_x, tray.shelf_y, tray.shelf_w, tray.shelf_h, rgb(0x50, 0x70, 0x98), 22, 100);
        fb.drawRect(tray.shelf_x, tray.shelf_y, tray.shelf_w, tray.shelf_h, rgb(0x38, 0x50, 0x68));
    }
    icons.drawThemedIcon(.network, tray.net_x, tray.tray_icons_y, tray.icon_s, .aero);
    icons.drawThemedIcon(.browser, tray.vol_x, tray.tray_icons_y, tray.icon_s, .aero);
    icons.drawThemedIcon(.settings, tray.set_x, tray.tray_icons_y, tray.icon_s, .aero);
    fb.drawTextTransparent(tray.chevron_x, tray.chevron_y, "^", rgb(0xB0, 0xC8, 0xE8));

    const line_time = "12:00 PM";
    const line_date = "3/21/2026";
    const line_h_clk: i32 = 14;
    fb.drawTextTransparent(tray.clk_x, tray.clk_y, line_time, t.clock_text);
    fb.drawTextTransparent(tray.clk_x, tray.clk_y + line_h_clk + 1, line_date, rgb(0xC8, 0xD8, 0xE8));

    fb.drawGradientV(scr_w - peek_w, tb_y, peek_w, tb_h, rgb(0x50, 0x70, 0x90), rgb(0x28, 0x40, 0x60));
    fb.drawVLine(scr_w - peek_w, tb_y, tb_h, rgb(0x70, 0x90, 0xB0));
}

pub fn initAeroDwm() void {
    if (!dwm_initialized) {
        // ideas/win7Desktop.md §4：backdrop → 盒式模糊（多遍≈高斯）→ blendTint 染色 → 顶区高光。
        // 任务栏全宽但高度小，renderGlassEffect 内对 .taskbar 使用较小半径 + 1 遍。
        // present() 在 Aero 下整帧 flip，减轻指针移动时与 flipDirty 矩形顺序相关的块状撕裂。
        // 半径×遍数过大时首帧会长时间阻塞，双缓冲下在首次 flip 前屏幕可能一直黑屏或旧内容。
        // 默认用较轻模糊（仍可见毛玻璃），需要画质再调大 glass_blur_*。
        const cfg = DwmConfig{
            .glass_enabled = true,
            .glass_opacity = 210,
            .glass_blur_radius = 6,
            .glass_blur_passes = 2,
            .glass_saturation = 208,
            .glass_tint_color = 0x4068A0,
            .glass_tint_opacity = 62,
            .glass_taskbar_tint_opacity = 104,
            .specular_intensity = 42,
            .animation_enabled = true,
            .peek_enabled = true,
            .shadow_enabled = true,
            .vsync_compositor = true,
            .smooth_cursor = true,
            .cursor_lerp_factor = 255,
        };
        initDwm(cfg);

        dwm_mod.init(.{
            .glass_enabled = cfg.glass_enabled,
            .glass_opacity = cfg.glass_opacity,
            .glass_blur_radius = cfg.glass_blur_radius,
            .glass_blur_passes = cfg.glass_blur_passes,
            .glass_saturation = cfg.glass_saturation,
            .glass_tint_color = cfg.glass_tint_color,
            .glass_tint_opacity = cfg.glass_tint_opacity,
            .glass_taskbar_tint_opacity = cfg.glass_taskbar_tint_opacity,
            .specular_intensity = cfg.specular_intensity,
            .animation_enabled = cfg.animation_enabled,
            .peek_enabled = cfg.peek_enabled,
            .shadow_enabled = cfg.shadow_enabled,
            .vsync_compositor = cfg.vsync_compositor,
            .smooth_cursor = cfg.smooth_cursor,
            .cursor_lerp_factor = cfg.cursor_lerp_factor,
        });

        mat.init(.glass);
        mat.configureGlass(.{
            .blur_radius = cfg.glass_blur_radius,
            .blur_passes = cfg.glass_blur_passes,
            .tint_color = cfg.glass_tint_color,
            .tint_opacity = cfg.glass_tint_opacity,
            .saturation = cfg.glass_saturation,
            .specular_intensity = cfg.specular_intensity,
        });

        dwm_comp.initAero(.{
            .glass_enabled = true,
            .glass_opacity = cfg.glass_opacity,
            .blur_radius = cfg.glass_blur_radius,
            .blur_passes = cfg.glass_blur_passes,
            .saturation = cfg.glass_saturation,
            .tint_color = cfg.glass_tint_color,
            .tint_opacity = cfg.glass_tint_opacity,
            .specular_intensity = cfg.specular_intensity,
            .shadow_layers = 3,
            .shadow_offset = 6,
            .peek_enabled = true,
            .flip3d_enabled = true,
            .animation_speed = 250,
        });
    }
}

// ── Desktop Window Manager (DWM) Compositor ──

pub const DwmConfig = struct {
    glass_enabled: bool = true,
    /// Legacy overall strength (some UI paths); tint strength is `glass_tint_opacity`
    glass_opacity: u8 = 180,
    glass_blur_radius: u8 = 12,
    /// Separable box-blur passes (win7Desktop.md: multi-pass ≈ Gaussian)
    glass_blur_passes: u8 = 4,
    glass_saturation: u8 = 200,
    /// BGR 0x00BBGGRR style packed color (same as theme colorization)
    glass_tint_color: u32 = 0x4068A0,
    /// Step 3: alpha blend with theme tint (Aero Glass pipeline)
    glass_tint_opacity: u8 = 58,
    /// Taskbar band: stronger tint（与轻量 blur 叠加）
    glass_taskbar_tint_opacity: u8 = 100,
    specular_intensity: u8 = 38,
    animation_enabled: bool = true,
    peek_enabled: bool = true,
    shadow_enabled: bool = true,
    vsync_compositor: bool = true,
    smooth_cursor: bool = true,
    cursor_lerp_factor: i32 = 200,
};

/// Chrome drawn after blur+tint (taskbar has side rails; caption only divider to client)
pub const GlassChrome = enum { taskbar, caption, panel };

var dwm_config: DwmConfig = .{};
var dwm_initialized: bool = false;

pub fn initDwm(cfg: DwmConfig) void {
    dwm_config = cfg;
    dwm_initialized = true;
    desktop_ctx.dwm_active = cfg.glass_enabled;
    desktop_ctx.smooth_cursor.lerp_factor = cfg.cursor_lerp_factor;
}

pub fn isDwmEnabled() bool {
    return dwm_initialized and dwm_config.glass_enabled;
}

pub fn getDwmConfig() *const DwmConfig {
    return &dwm_config;
}

pub fn setDwmGlass(enabled: bool) void {
    dwm_config.glass_enabled = enabled;
    desktop_ctx.dwm_active = enabled;
}

pub fn setSmoothCursorFactor(factor: i32) void {
    desktop_ctx.smooth_cursor.lerp_factor = if (factor < 64) 64 else if (factor > 255) 255 else factor;
}

/// win7Desktop.md §4 Aero Glass: (1) sample backdrop (2) blur (3) tint blend (4) composite decorations
pub fn renderGlassEffect(x: i32, y: i32, w: i32, h: i32, tint: u32, chrome: GlassChrome) void {
    if (!use_framebuffer or !fb.isInitialized()) return;
    if (!dwm_config.glass_enabled) {
        fb.fillRect(x, y, w, h, if (tint != 0) tint else dwm_config.glass_tint_color);
        return;
    }

    const eff_tint = if (tint != 0) tint else dwm_config.glass_tint_color;
    const blur_r = @as(u32, dwm_config.glass_blur_radius);
    const passes = @as(u32, dwm_config.glass_blur_passes);
    const tint_alpha: u8 = switch (chrome) {
        .taskbar => dwm_config.glass_taskbar_tint_opacity,
        else => dwm_config.glass_tint_opacity,
    };

    // 与 dwm.zig 一致：任务栏薄带用 capped 半径 + 1 遍；其它区域多遍模糊。
    if (!dwm_mod.shouldSkipGlassBoxBlur() and blur_r > 0 and passes > 0) {
        if (chrome == .taskbar) {
            const tr = @min(blur_r, @as(u32, 3));
            fb.boxBlurRect(x, y, w, h, tr, 1);
        } else {
            fb.boxBlurRect(x, y, w, h, blur_r, if (passes < 1) 1 else passes);
        }
    }

    fb.blendTintRect(x, y, w, h, eff_tint, tint_alpha, dwm_config.glass_saturation);

    const spec = @as(u32, dwm_config.specular_intensity);
    if (spec > 0) {
        const shine_h = @divTrunc(h, 3);
        if (shine_h > 1) {
            fb.addSpecularBand(x, y, w, shine_h, spec);
            fb.drawHLine(x, y, w, rgb(0xFF, 0xFF, 0xFF));
        }
    }

    switch (chrome) {
        .taskbar => {
            fb.drawHLine(x, y + h - 1, w, rgb(0x18, 0x28, 0x40));
            fb.drawVLine(x, y, h, rgb(0x50, 0x70, 0x98));
            fb.drawVLine(x + w - 1, y, h, rgb(0x50, 0x70, 0x98));
        },
        .caption => {
            fb.drawHLine(x, y + h - 1, w, rgb(0x70, 0x90, 0xB8));
        },
        .panel => {
            fb.drawHLine(x, y + h - 1, w, rgb(0x40, 0x60, 0x88));
            fb.drawVLine(x, y, h, rgb(0x55, 0x75, 0x98));
            fb.drawVLine(x + w - 1, y, h, rgb(0x55, 0x75, 0x98));
        },
    }
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
        fb.blendTintRect(x + offset, y + offset, w, h, rgb(0x00, 0x00, 0x00), shadow_alpha, 255);
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
    .{ .label = "Network", .id = .network },
    .{ .label = "Control Panel", .id = .settings, .shortcut = true },
    .{ .label = "Browser", .id = .browser, .shortcut = true },
};

pub fn renderDesktopIcons(scr_w: i32, scr_h: i32, t: *const ThemeColors) void {
    _ = scr_w;
    const base_x: i32 = 20;
    var base_y: i32 = 16;
    const avail_h = scr_h - getTaskbarHeight() - 16;
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
    fb.fillRect(x + 1, y + 1, 12, 12, dark);
    fb.drawHLine(x + 3, y + 3, 8, white);
    var i: i32 = 0;
    while (i < 8) : (i += 1) {
        fb.putPixel32(@intCast(x + 10 - i), @intCast(y + 4 + i), white);
    }
    fb.drawHLine(x + 3, y + 11, 8, white);
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

fn initTaskMgrPosition(scr_w: i32, scr_h: i32) void {
    if (taskmgr_placed) return;
    const tm_w: i32 = 320;
    const tm_h: i32 = 260;
    const tb = getTaskbarHeight();
    const pad: i32 = 12;
    taskmgr_x = scr_w - tm_w - pad;
    taskmgr_y = scr_h - tb - tm_h - pad;
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
    initTaskMgrPosition(scr_w, scr_h);
    const tm_w: i32 = 320;
    const tm_h: i32 = 260;
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
    drawAeroCaptionButtons(win_x, win_y, tm_w, th, t);
    fb.drawTextTransparent(win_x + 8, win_y + 5, "Windows Task Manager", t.titlebar_text);
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

/// Win7 风格任务管理器：浅色标签条 + 选中项 + 列表区。
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

    const procs = [_]struct { name: []const u8, pid: []const u8, cpu: []const u8, mem: []const u8 }{
        .{ .name = "System Idle Process", .pid = "0", .cpu = "99", .mem = "4 K" },
        .{ .name = "System", .pid = "4", .cpu = "0", .mem = "0.1 MB" },
        .{ .name = "smss.exe", .pid = "...", .cpu = "0", .mem = "0.1 MB" },
        .{ .name = "csrss.exe", .pid = "...", .cpu = "0", .mem = "2.0 MB" },
        .{ .name = "explorer.exe", .pid = "...", .cpu = "0", .mem = "8.0 MB" },
        .{ .name = "taskmgr.exe", .pid = "...", .cpu = "0", .mem = "3.2 MB" },
    };

    var py: i32 = hdr_y + 22;
    for (procs, 0..) |p, i| {
        if (i % 2 == 1) {
            fb.fillRect(x + 2, py - 1, w - 4, 17, rgb(0xF5, 0xF8, 0xFC));
        }
        fb.drawTextTransparent(x + 8, py, p.name, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(x + 160, py, p.pid, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(x + 220, py, p.cpu, rgb(0x00, 0x00, 0x00));
        fb.drawTextTransparent(x + 270, py, p.mem, rgb(0x60, 0x60, 0x60));
        py += 16;
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

    // Client area only — titlebar keeps backdrop for true Aero glass (win7Desktop.md §4)
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
        drawAeroCaptionButtons(win_x, win_y, win_w, TITLEBAR_H, t);
        return;
    }

    const btn_y = win_y + @divTrunc(TITLEBAR_H - BTN_SIZE, 2);
    const close_x = win_x + win_w - BTN_SIZE - 4;
    const max_x = close_x - BTN_SIZE - 2;
    const min_x = max_x - BTN_SIZE - 2;

    fb.fillRoundedRect(close_x, btn_y, BTN_SIZE, BTN_SIZE, 3, t.btn_close_top);
    drawCloseSymbol(close_x, btn_y, BTN_SIZE);

    fb.fillRoundedRect(max_x, btn_y, BTN_SIZE, BTN_SIZE, 3, t.btn_minmax_top);
    drawMaxSymbol(max_x, btn_y, BTN_SIZE);

    fb.fillRoundedRect(min_x, btn_y, BTN_SIZE, BTN_SIZE, 3, t.btn_minmax_top);
    drawMinSymbol(min_x, btn_y, BTN_SIZE);
}

/// Windows 7 Aero：在整块标题栏玻璃已绘制后，为最小化/最大化/关闭绘制玻璃抬升、顶缘高光、分隔线与关闭键微暖色。
pub fn drawAeroCaptionButtons(win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32, _: *const ThemeColors) void {
    if (titlebar_h < 8 or win_w < 96) return;

    const btn_w: i32 = if (titlebar_h >= 28) 26 else @min(22, titlebar_h - 2);
    const btn_y = win_y + @divTrunc(titlebar_h - btn_w, 2);
    const close_x = win_x + win_w - btn_w;
    const max_x = close_x - btn_w;
    const min_x = max_x - btn_w;
    const sep_x = min_x - 1;

    const edge = rgb(0x50, 0x78, 0xA8);
    const div = rgb(0x78, 0xA0, 0xD0);
    const glyph = rgb(0xF8, 0xFA, 0xFF);

    // 标题区与按钮组之间的竖向分隔（高光 + 阴影边）
    if (sep_x > win_x + 4) {
        fb.drawVLine(sep_x, win_y + 2, titlebar_h - 4, rgb(0xFF, 0xFF, 0xFF));
        fb.drawVLine(sep_x + 1, win_y + 3, titlebar_h - 6, edge);
    }

    const slots = [_]struct { x: i32, close: bool }{
        .{ .x = min_x, .close = false },
        .{ .x = max_x, .close = false },
        .{ .x = close_x, .close = true },
    };

    for (slots) |s| {
        const rx = s.x;
        const ry = btn_y;
        if (s.close) {
            fb.blendTintRect(rx, ry, btn_w, btn_w, rgb(0xD8, 0x58, 0x48), 16, 255);
        }
        fb.blendTintRect(rx, ry, btn_w, btn_w, rgb(0xFF, 0xFF, 0xFF), 24, 255);
        if (dwm_initialized and dwm_config.glass_enabled) {
            const band = @max(2, @divTrunc(btn_w, 4));
            fb.addSpecularBand(rx, ry, btn_w, band, 10);
        }
        fb.drawRect(rx, ry, btn_w, btn_w, rgb(0xA0, 0xC8, 0xE8));
    }

    const div_len = btn_w - 4;
    if (div_len > 0) {
        fb.drawVLine(max_x, btn_y + 2, div_len, div);
        fb.drawVLine(close_x, btn_y + 2, div_len, div);
    }

    drawMinSymbolColored(min_x, btn_y, btn_w, glyph);
    drawMaxSymbolColored(max_x, btn_y, btn_w, glyph);
    drawCloseSymbolColored(close_x, btn_y, btn_w, glyph);
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

        // Font info line (rendered with ZirconOSFonts typeface)
        if (iy + 20 <= content_y + content_h) {
            fb.drawTextTransparent(x + 10, iy + 4, "Font: Noto Sans (ZirconOSFonts)", rgb(0x80, 0x80, 0x80));
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

// ── Window Drag State ──

var drag_active: bool = false;
var drag_offset_x: i32 = 0;
var drag_offset_y: i32 = 0;
var window_x: i32 = 0;
var window_y: i32 = 0;
var window_placed: bool = false;

/// Sample window size clamped to work area [0, scr_h - taskbar) so the shell is never covered.
fn computeSampleWindowDims(scr_w: i32, scr_h: i32) struct { w: i32, h: i32 } {
    const tb = getTaskbarHeight();
    const margin: i32 = 12;
    const max_h = scr_h - tb - margin * 2;
    const max_w = scr_w - margin * 2;

    var win_w: i32 = if (scr_w > 600) 520 else scr_w - 80;
    if (win_w > max_w) win_w = max_w;
    if (win_w < 120) win_w = @min(120, @max(80, scr_w - 16));

    var win_h: i32 = if (scr_h > 500) 380 else scr_h - tb - 96;
    if (win_h > max_h) win_h = max_h;
    if (win_h < 120) win_h = @min(120, @max(96, max_h));

    return .{ .w = win_w, .h = win_h };
}

fn initWindowPosition(scr_w: i32, scr_h: i32) void {
    if (!window_placed) {
        const dim = computeSampleWindowDims(scr_w, scr_h);
        const tb = getTaskbarHeight();
        const pad: i32 = 12;
        window_x = @divTrunc(scr_w - dim.w, 2);
        if (window_x < pad) window_x = pad;
        window_y = @divTrunc(scr_h - tb - dim.h, 2);
        if (window_y < pad) window_y = pad;
        if (window_y + dim.h > scr_h - tb - 2) {
            window_y = scr_h - tb - dim.h - 2;
        }
        if (window_y < pad) window_y = pad;
        window_placed = true;
    }
}

pub fn getWindowRect(scr_w: i32, scr_h: i32) struct { x: i32, y: i32, w: i32, h: i32 } {
    initWindowPosition(scr_w, scr_h);
    const dim = computeSampleWindowDims(scr_w, scr_h);
    return .{ .x = window_x, .y = window_y, .w = dim.w, .h = dim.h };
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
    var fx = tray.chevron_x - AERO_TRAY_FLYOUT_W + 24;
    if (fx < 4) fx = 4;
    if (fx + AERO_TRAY_FLYOUT_W > scr_w - 4) fx = scr_w - 4 - AERO_TRAY_FLYOUT_W;
    const fy = @max(4, tray.tb_y - menu_h - 4);
    return .{ .x = fx, .y = fy, .w = AERO_TRAY_FLYOUT_W, .h = menu_h };
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
        renderGlassEffect(r.x, r.y, r.w, r.h, t.titlebar_active_left, .caption);
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
    if (px < r.x or px >= r.x + r.w or py < r.y or py >= r.y + r.h) return null;
    var iy: i32 = r.y + AERO_TRAY_FLYOUT_PAD;
    for (aero_tray_flyout_items, 0..) |item, i| {
        if (item.len == 3 and item[0] == '-') {
            iy += 10;
            continue;
        }
        if (py >= iy and py < iy + AERO_TRAY_FLYOUT_ROW) return i;
        iy += AERO_TRAY_FLYOUT_ROW;
    }
    return null;
}

// ── Right-Click Context Menu ──

var ctx_menu_visible: bool = false;
var ctx_menu_x: i32 = 0;
var ctx_menu_y: i32 = 0;

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
    ctx_menu_x = if (x + CTX_MENU_W > w) w - CTX_MENU_W - 2 else x;
    const menu_h = ctxMenuHeight();
    const tb_h = getTaskbarHeight();
    ctx_menu_y = if (y + menu_h > h - tb_h) h - tb_h - menu_h - 2 else y;
    ctx_menu_visible = true;
}

pub fn hideContextMenu() void {
    ctx_menu_visible = false;
}

pub fn renderContextMenu() void {
    if (!ctx_menu_visible) return;
    const t = active_theme;
    const menu_h = ctxMenuHeight();

    // DWM shadow (soft offset)
    if (dwm_initialized and dwm_config.shadow_enabled) {
        renderShadow(ctx_menu_x, ctx_menu_y, CTX_MENU_W, menu_h, 4);
    } else {
        fb.fillRect(ctx_menu_x + 2, ctx_menu_y + 2, CTX_MENU_W, menu_h, rgb(0x20, 0x20, 0x20));
    }

    fb.fillRect(ctx_menu_x, ctx_menu_y, CTX_MENU_W, menu_h, t.window_bg);
    if (dwm_initialized and dwm_config.glass_enabled) {
        renderGlassEffect(ctx_menu_x, ctx_menu_y, CTX_MENU_W, menu_h, t.titlebar_active_left, .caption);
    }

    fb.drawRect(ctx_menu_x, ctx_menu_y, CTX_MENU_W, menu_h, t.window_border);

    const text_color: u32 = rgb(0xFF, 0xFF, 0xFF);
    const sep_color: u32 = rgb(0x60, 0x60, 0x70);

    var iy: i32 = ctx_menu_y + 4;
    for (ctx_menu_items) |item| {
        if (item.len == 3 and item[0] == '-') {
            fb.drawHLine(ctx_menu_x + 4, iy + 3, CTX_MENU_W - 8, sep_color);
            iy += CTX_SEP_H;
        } else {
            fb.drawTextTransparent(ctx_menu_x + 28, iy + 4, item, text_color);
            iy += CTX_ITEM_H;
        }
    }
}

fn isInsideContextMenu(x: i32, y: i32) bool {
    if (!ctx_menu_visible) return false;
    const menu_h = ctxMenuHeight();
    return x >= ctx_menu_x and x < ctx_menu_x + CTX_MENU_W and
        y >= ctx_menu_y and y < ctx_menu_y + menu_h;
}

// ── Cursor Rendering (ZirconOS Aero Crystal Style) ──
// The cursor uses a crystal/glass design with:
//   - Dark teal outline for sharp definition
//   - White fill for high visibility
//   - Glass highlight for upper-left interior (Aero reflective effect)
//   - Inner glow tint for depth perception
//   - Optional drop shadow when DWM is active

pub fn renderCursor(x: i32, y: i32) void {
    if (!use_framebuffer or !fb.isInitialized()) return;

    const w_i32: i32 = @intCast(fb.getWidth());
    const h_i32: i32 = @intCast(fb.getHeight());

    // 0=transparent, 1=fill, 2=outline, 3=glass_highlight, 4=inner_glow
    const cursor_shape = [_][14]u3{
        .{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 2, 3, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 2, 3, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 2, 3, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 2, 3, 3, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 2, 3, 3, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0 },
        .{ 2, 4, 3, 3, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0 },
        .{ 2, 4, 3, 3, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0 },
        .{ 2, 4, 4, 3, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0 },
        .{ 2, 4, 4, 3, 1, 1, 1, 1, 1, 1, 2, 0, 0, 0 },
        .{ 2, 4, 4, 3, 1, 1, 1, 2, 2, 2, 2, 2, 0, 0 },
        .{ 2, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0 },
        .{ 2, 1, 1, 2, 4, 1, 1, 2, 0, 0, 0, 0, 0, 0 },
        .{ 2, 1, 2, 0, 2, 4, 1, 1, 2, 0, 0, 0, 0, 0 },
        .{ 2, 2, 0, 0, 2, 4, 1, 1, 2, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 2, 4, 1, 1, 2, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 2, 4, 1, 1, 2, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 2, 1, 2, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0 },
    };

    const scale: i32 = 1;
    const outline = rgb(0x00, 0x00, 0x00);
    const fill = rgb(0xFF, 0xFF, 0xFF);
    const glass_hi = rgb(0xC0, 0xE8, 0xF0);
    const inner_glow = rgb(0x40, 0x90, 0xA0);

    if (dwm_initialized and dwm_config.shadow_enabled) {
        for (cursor_shape, 0..) |row, dy| {
            for (row, 0..) |pixel, dx| {
                if (pixel == 2) {
                    const base_sx = x + @as(i32, @intCast(dx)) * scale + scale;
                    const base_sy = y + @as(i32, @intCast(dy)) * scale + scale;
                    var sy: i32 = 0;
                    while (sy < scale) : (sy += 1) {
                        var sx: i32 = 0;
                        while (sx < scale) : (sx += 1) {
                            const px = base_sx + sx;
                            const py = base_sy + sy;
                            if (px >= 0 and px < w_i32 and py >= 0 and py < h_i32) {
                                fb.blendPixel(@intCast(px), @intCast(py), 0x00000000, 80);
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
                const base_px = x + @as(i32, @intCast(dx)) * scale;
                const base_py = y + @as(i32, @intCast(dy)) * scale;
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
                        const px = base_px + sx;
                        const py = base_py + sy;
                        if (px >= 0 and px < w_i32 and py >= 0 and py < h_i32) {
                            fb.putPixel32(@intCast(px), @intCast(py), color);
                        }
                    }
                }
            }
        }
    }
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

pub fn present() void {
    if (!use_framebuffer) return;
    // 仅 Aero：整帧 flip，减轻指针移动时 flipDirty 多矩形顺序拷贝的块状撕裂。其它主题保持 flipDirty，避免改变既有启动/帧耗。
    if (dwm_initialized and dwm_config.vsync_compositor) {
        fb.flip();
    } else {
        fb.flipDirty();
    }
    if (dwm_comp.isInitialized()) {
        dwm_comp.notifyFramePresented();
    }
    desktop_ctx.present_count += 1;
    desktop_ctx.frame_count += 1;
}

pub fn presentFull() void {
    if (!use_framebuffer) return;
    fb.flip();
    desktop_ctx.present_count += 1;
    desktop_ctx.frame_count += 1;
}

pub fn setCursorPosition(x: i32, y: i32) void {
    desktop_ctx.cursor_x = x;
    desktop_ctx.cursor_y = y;
}

// ── Public Accessors for Renderer Modules ──

pub const DragState = struct {
    explorer_active: bool,
    taskmgr_active: bool,
    explorer_prev: ShellRect,
    taskmgr_prev: ShellRect,
};

pub fn getDragState() DragState {
    return .{
        .explorer_active = drag_active,
        .taskmgr_active = taskmgr_drag_active,
        .explorer_prev = explorer_drag_prev_rect,
        .taskmgr_prev = taskmgr_drag_prev_rect,
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

/// Aero：在首次 `present()` 之前跳过盒式模糊，首屏尽快可见（ideas/Win7B.md 合成节拍）。
fn syncAeroGlassFastPath() void {
    const during_drag = drag_active or taskmgr_drag_active;
    dwm_mod.setSkipGlassBoxBlur(desktop_ctx.present_count == 0 or during_drag);
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
