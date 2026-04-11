// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/base/window_framework.zig
// Purpose: Unified window framework for Win7-style applications
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const icons_mod = @import("../../kernel/icons/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");
const klog = @import("../../../rtl/klog.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Size = struct {
    width: i32,
    height: i32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and px < r.x + r.width and py >= r.y and py < r.y + r.height;
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.x + b.width and a.x + a.width > b.x and a.y < b.y + b.height and a.y + a.height > b.y;
    }

    pub fn unionRects(a: Rect, b: Rect) Rect {
        const x1 = @min(a.x, b.x);
        const y1 = @min(a.y, b.y);
        const x2 = @max(a.x + a.width, b.x + b.width);
        const y2 = @max(a.y + a.height, b.y + b.height);
        return .{ .x = x1, .y = y1, .width = x2 - x1, .height = y2 - y1 };
    }
};

pub const WindowStyle = enum {
    aero_glass,
    aero_basic,
    classic,
};

pub const CaptionButton = enum {
    none,
    minimize,
    maximize,
    close,
};

pub const AppEvent = union(enum) {
    paint: Rect,
    mouse_move: Point,
    mouse_down: Point,
    mouse_up: Point,
    key_down: u8,
    resize: Size,
    focus: void,
    blur: void,
    close: void,
};

pub const AppId = enum(u16) {
    _,
};

pub const AppWindow = struct {
    id: AppId,
    title: []const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    min_width: i32,
    min_height: i32,
    style: WindowStyle,
    visible: bool,
    focused: bool,
    resizable: bool,
    maximizable: bool,
    minimizable: bool,
    caption_height: i32,
    border_width: i32,
    caption_hover: CaptionButton,
    is_dragging: bool,
    is_resizing: bool,
    resize_edge: ResizeEdge,
    drag_offset_x: i32,
    drag_offset_y: i32,
    client_dirty: bool,
    title_changed: bool,

    const DEFAULT_WIDTH: i32 = 640;
    const DEFAULT_HEIGHT: i32 = 480;
    const DEFAULT_CAPTION_H: i32 = 32;
    const DEFAULT_BORDER: i32 = 1;

    pub fn create(title: []const u8) AppWindow {
        return .{
            .id = ._,
            .title = title,
            .x = 100,
            .y = 100,
            .width = DEFAULT_WIDTH,
            .height = DEFAULT_HEIGHT,
            .min_width = 200,
            .min_height = 150,
            .style = .aero_glass,
            .visible = true,
            .focused = false,
            .resizable = true,
            .maximizable = true,
            .minimizable = true,
            .caption_height = DEFAULT_CAPTION_H,
            .border_width = DEFAULT_BORDER,
            .caption_hover = .none,
            .is_dragging = false,
            .is_resizing = false,
            .resize_edge = .none,
            .drag_offset_x = 0,
            .drag_offset_y = 0,
            .client_dirty = true,
            .title_changed = false,
        };
    }

    pub fn setPosition(w: *AppWindow, new_x: i32, new_y: i32) void {
        w.x = new_x;
        w.y = new_y;
        w.client_dirty = true;
    }

    pub fn setSize(w: *AppWindow, new_width: i32, new_height: i32) void {
        w.width = @max(w.min_width, new_width);
        w.height = @max(w.min_height, new_height);
        w.client_dirty = true;
    }

    pub fn getClientRect(w: *const AppWindow) Rect {
        return .{
            .x = w.x + w.border_width,
            .y = w.y + w.caption_height + w.border_width,
            .width = w.width - 2 * w.border_width,
            .height = w.height - w.caption_height - 2 * w.border_width,
        };
    }

    pub fn getCaptionRect(w: *const AppWindow) Rect {
        return .{
            .x = w.x,
            .y = w.y,
            .width = w.width,
            .height = w.caption_height,
        };
    }

    pub fn hitTestCaption(w: *const AppWindow, px: i32, py: i32) CaptionButton {
        const cap = w.getCaptionRect();
        if (!cap.contains(px, py)) return .none;
        const btn_layout = captionButtonLayout(w.x, w.y, w.width, w.caption_height);
        if (px >= btn_layout.close_x) return .close;
        if (px >= btn_layout.max_x) return .maximize;
        if (px >= btn_layout.min_x) return .minimize;
        return .none;
    }

    pub fn updateCaptionHover(w: *AppWindow, px: i32, py: i32) void {
        w.caption_hover = w.hitTestCaption(px, py);
    }

    pub fn startDrag(w: *AppWindow, px: i32, py: i32) void {
        w.is_dragging = true;
        w.drag_offset_x = px - w.x;
        w.drag_offset_y = py - w.y;
    }

    pub fn updateDrag(w: *AppWindow, px: i32, py: i32, screen_width: i32, screen_height: i32, taskbar_height: i32) void {
        if (!w.is_dragging) return;
        const new_x = @max(0, @min(px - w.drag_offset_x, screen_width - w.width));
        const new_y = @max(0, @min(py - w.drag_offset_y, screen_height - taskbar_height - w.height));
        if (new_x != w.x or new_y != w.y) {
            w.x = new_x;
            w.y = new_y;
            w.client_dirty = true;
        }
    }

    pub fn endDrag(w: *AppWindow) void {
        w.is_dragging = false;
    }

    pub fn markDirty(w: *AppWindow) void {
        w.client_dirty = true;
    }

    pub fn clearDirty(w: *AppWindow) void {
        w.client_dirty = false;
    }

    pub fn isDirty(w: *const AppWindow) bool {
        return w.client_dirty;
    }
};

const ResizeEdge = enum {
    none,
    left,
    right,
    top,
    bottom,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

fn captionButtonLayout(win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32) struct {
    min_x: i32,
    max_x: i32,
    close_x: i32,
    btn_w: i32,
    btn_w_close: i32,
    btn_y: i32,
    btn_h: i32,
} {
    const vpad: i32 = 2;
    const btn_h = @max(18, titlebar_h - 2 * vpad);
    const btn_y = win_y + @divTrunc(titlebar_h - btn_h, 2);
    const btn_w: i32 = if (titlebar_h >= 28) 40 else @max(34, titlebar_h + 2);
    const btn_w_close: i32 = btn_w + 8;
    const close_x = win_x + win_w - btn_w_close;
    const max_x = close_x - btn_w;
    const min_x = max_x - btn_w;
    return .{
        .min_x = min_x,
        .max_x = max_x,
        .close_x = close_x,
        .btn_w = btn_w,
        .btn_w_close = btn_w_close,
        .btn_y = btn_y,
        .btn_h = btn_h,
    };
}

pub fn drawCaptionButtons(win_x: i32, win_y: i32, win_w: i32, titlebar_h: i32, hover: CaptionButton, t: *const theme_mod.ThemeColors) void {
    _ = t;
    if (titlebar_h < 8 or win_w < 96) return;
    const L = captionButtonLayout(win_x, win_y, win_w, titlebar_h);
    const div_dark = rgb(0x3A, 0x5A, 0x78);
    const div_light = rgb(0xB8, 0xD0, 0xE8);
    const glyph_idle = rgb(0xE8, 0xF2, 0xFA);
    const glyph_on_red = rgb(0xFF, 0xFF, 0xFF);

    fb.drawVLine(L.min_x - 1, win_y + 1, titlebar_h - 2, div_light);
    fb.drawVLine(L.max_x, win_y + 1, titlebar_h - 2, div_dark);
    fb.drawVLine(L.close_x, win_y + 1, titlebar_h - 2, div_dark);

    if (hover == .minimize) {
        fb.blendTintRect(L.min_x, L.btn_y, L.btn_w, L.btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
    }
    if (hover == .maximize) {
        fb.blendTintRect(L.max_x, L.btn_y, L.btn_w, L.btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
    }
    if (hover == .close) {
        fb.fillRect(L.close_x, L.btn_y, L.btn_w_close, L.btn_h, rgb(0xE8, 0x11, 0x23));
    }

    drawMinGlyph(L.min_x, L.btn_y, L.btn_w, L.btn_h, glyph_idle);
    drawMaxGlyph(L.max_x, L.btn_y, L.btn_w, L.btn_h, glyph_idle);
    drawCloseGlyph(L.close_x, L.btn_y, L.btn_w_close, L.btn_h, if (hover == .close) glyph_on_red else glyph_idle);
}

fn drawMinGlyph(bx: i32, by: i32, bw: i32, bh: i32, fg: u32) void {
    if (bw < 8 or bh < 8) return;
    const bar_w = @max(6, @min(bw - 4, 12));
    const sx = bx + @divTrunc(bw - bar_w, 2);
    const sy = by + bh - @divTrunc(bh, 3);
    fb.fillRect(sx, sy, bar_w, 2, fg);
}

fn drawMaxGlyph(bx: i32, by: i32, bw: i32, bh: i32, fg: u32) void {
    if (bw < 10 or bh < 10) return;
    const m = @max(5, @min(8, @divTrunc(@min(bw, bh), 5)));
    _ = m;
    const sz = @max(7, @min(bw, bh) - 2 * 5);
    const ox = bx + @divTrunc(bw - sz, 2);
    const oy = by + @divTrunc(bh - sz, 2);
    fb.drawRect(ox, oy, sz, sz, fg);
    fb.drawHLine(ox, oy + 1, sz, fg);
}

fn drawCloseGlyph(bx: i32, by: i32, bw: i32, bh: i32, fg: u32) void {
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

pub fn renderWindowFrame(w: *const AppWindow, t: *const theme_mod.ThemeColors) void {
    const wx = w.x;
    const wy = w.y;
    const ww = w.width;
    const wh = w.height;
    const ch = w.caption_height;

    if (dwm_mod.isInitialized() and dwm_mod.getConfig().shadow_enabled) {
        fb.fillRect(wx + 4, wy + 4, ww, wh, rgb(0x28, 0x28, 0x30));
    }

    const client_y = wy + ch;
    const client_h = wh - ch;
    fb.fillRect(wx, client_y, ww, client_h, t.window_bg);

    if (w.style == .aero_glass or w.style == .aero_basic) {
        if (dwm_mod.isGlassEnabled()) {
            const active_color = if (w.focused) t.titlebar_active_left else t.titlebar_inactive_left;
            dwm_mod.renderGlassEffect(wx, wy, ww, ch, active_color, .caption);
        } else {
            const left_color = if (w.focused) t.titlebar_active_left else t.titlebar_inactive_left;
            const right_color = if (w.focused) t.titlebar_active_right else t.titlebar_inactive_right;
            fb.drawGradientH(wx, wy, ww, ch, left_color, right_color);
        }
    } else {
        fb.fillRect(wx, wy, ww, ch, rgb(0xCC, 0xCC, 0xCC));
    }

    drawCaptionButtons(wx, wy, ww, ch, w.caption_hover, t);

    const text_x = wx + 8;
    const text_y = wy + @divTrunc(ch - 14, 2);
    const text_color = if (w.focused) t.titlebar_text else t.titlebar_inactive_text;
    fb.drawTextTransparent(text_x, text_y, w.title, text_color);

    fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
}

pub fn renderWindowFrameLight(w: *const AppWindow, t: *const theme_mod.ThemeColors) void {
    const wx = w.x;
    const wy = w.y;
    const ww = w.width;
    const wh = w.height;
    const ch = w.caption_height;

    fb.fillRect(wx + 3, wy + 3, ww, wh, rgb(0x30, 0x30, 0x30));
    fb.fillRect(wx, wy + ch, ww, wh - ch, t.window_bg);

    if (dwm_mod.isGlassEnabled()) {
        const active_color = if (w.focused) t.titlebar_active_left else t.titlebar_inactive_left;
        dwm_mod.renderGlassTintOnly(wx, wy, ww, ch, active_color, .caption);
    } else {
        fb.drawGradientH(wx, wy, ww, ch, t.titlebar_active_left, t.titlebar_active_right);
    }

    drawCaptionButtons(wx, wy, ww, ch, w.caption_hover, t);

    const text_x = wx + 8;
    const text_y = wy + @divTrunc(ch - 14, 2);
    fb.drawTextTransparent(text_x, text_y, w.title, t.titlebar_text);
}
