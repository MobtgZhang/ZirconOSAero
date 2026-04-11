// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/applet_base.zig
// Purpose: Base class framework for all Control Panel applets
//
// This is an independent clean-room implementation.

const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and px < r.x + r.width and py >= r.y and py < r.y + r.height;
    }
};

pub const AppletId = enum(u16) {
    appearance = 0,
    display = 1,
    sounds = 2,
    mouse = 3,
    keyboard = 4,
    region = 5,
    date_time = 6,
    user_accounts = 7,
    firewall = 8,
    programs = 9,
    default_programs = 10,
    network_center = 11,
    device_manager = 12,
    power_options = 13,
    system = 14,
};

pub const CaptionButtonType = enum { none, minimize, maximize, close };

pub const ControlPanelApplet = struct {
    id: AppletId,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    modified: bool,

    pub fn create(id: AppletId, x_pos: i32, y_pos: i32, w: i32, h: i32) ControlPanelApplet {
        return .{
            .id = id,
            .x = x_pos,
            .y = y_pos,
            .width = w,
            .height = h,
            .visible = true,
            .caption_hover = .none,
            .modified = false,
        };
    }

    pub fn onMouseMove(_: *ControlPanelApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn onMouseDown(_: *ControlPanelApplet, px: i32, py: i32, btn: u8) void {
        _ = px;
        _ = py;
        _ = btn;
    }

    pub fn onMouseUp(_: *ControlPanelApplet, px: i32, py: i32, btn: u8) void {
        _ = px;
        _ = py;
        _ = btn;
    }

    pub fn onResize(applet: *ControlPanelApplet, new_w: i32, new_h: i32) void {
        applet.width = new_w;
        applet.height = new_h;
    }

    pub fn onClose(_: *ControlPanelApplet) void {}

    pub fn renderCaptionBar(applet: *const ControlPanelApplet, title: []const u8) void {
        const wx = applet.x;
        const wy = applet.y;
        const ww = applet.width;
        const ch: i32 = 32;

        fb.drawGradientH(wx, wy, ww, ch, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, title, rgb(0xFF, 0xFF, 0xFF));

        const btn_h: i32 = 20;
        const btn_y = wy + @divTrunc(ch - btn_h, 2);
        const close_x = wx + ww - 48;

        if (applet.caption_hover == .close) {
            fb.fillRect(close_x, btn_y, 48, btn_h, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, btn_y + 4, "X", rgb(0xFF, 0xFF, 0xFF));
    }

    pub fn getClientRect(applet: *const ControlPanelApplet) Rect {
        return .{
            .x = applet.x,
            .y = applet.y + 32,
            .width = applet.width,
            .height = applet.height - 32,
        };
    }

    pub fn drawButton(x: i32, y: i32, w: i32, h: i32, label: []const u8, hovered: bool) void {
        const bg = if (hovered) rgb(0xE8, 0xEC, 0xF4) else rgb(0xF0, 0xF4, 0xF8);
        fb.fillRect(x, y, w, h, bg);
        fb.draw3DRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        const text_x = x + @divTrunc(w, 2) - @as(i32, @intCast(label.len)) * 4;
        const text_y = y + @divTrunc(h, 2) - 7;
        fb.drawTextTransparent(text_x, text_y, label, rgb(0x20, 0x20, 0x28));
    }

    pub fn drawLabel(x: i32, y: i32, text: []const u8, color: u32) void {
        fb.drawTextTransparent(x, y, text, color);
    }

    pub fn drawGroupBox(x: i32, y: i32, w: i32, h: i32, title: []const u8) void {
        fb.draw3DRect(x, y, w, h, rgb(0xC0, 0xC8, 0xD8), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(x + 8, y, @as(i32, @intCast(title.len)) * 7 + 4, 14);
        fb.drawTextTransparent(x + 10, y + 2, title, rgb(0x20, 0x40, 0x80));
    }

    pub fn drawSlider(x: i32, y: i32, w: i32, value: i32, min_val: i32, max_val: i32) void {
        fb.fillRect(x, y, w, 8, rgb(0xC0, 0xC8, 0xD0));
        const ratio = @as(f32, @floatFromInt(value - min_val)) / @as(f32, @floatFromInt(max_val - min_val));
        const thumb_x = x + @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(w - 8))));
        fb.fillRect(thumb_x, y - 4, 8, 16, rgb(0xD0, 0xD8, 0xE0));
        fb.draw3DRect(thumb_x, y - 4, 8, 16, rgb(0xFF, 0xFF, 0xFF), rgb(0x90, 0x98, 0xA8));
    }

    pub fn drawCheckbox(x: i32, y: i32, label: []const u8, checked: bool) void {
        fb.fillRect(x, y + 2, 14, 14, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x, y + 2, 14, 14, rgb(0x80, 0x80, 0x88), rgb(0xFF, 0xFF, 0xFF));
        if (checked) {
            fb.drawTextTransparent(x + 2, y, "X", rgb(0x10, 0x40, 0x10));
        }
        fb.drawTextTransparent(x + 20, y + 2, label, rgb(0x20, 0x20, 0x28));
    }

    pub fn drawRadioButton(x: i32, y: i32, label: []const u8, selected: bool) void {
        fb.fillEllipse(x, y + 1, 14, 14, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x88));
        if (selected) {
            fb.fillEllipse(x + 3, y + 4, 8, 8, rgb(0x20, 0x60, 0xC0));
        }
        fb.drawTextTransparent(x + 20, y + 2, label, rgb(0x20, 0x20, 0x28));
    }

    pub fn drawListItem(x: i32, y: i32, w: i32, label: []const u8, selected: bool, icon: ?u16) void {
        const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else rgb(0xFF, 0xFF, 0xFF);
        fb.fillRect(x, y, w, 28, bg);
        if (icon) |_| {
            fb.fillRect(x + 4, y + 4, 20, 20, rgb(0xE8, 0xEC, 0xF0));
        }
        fb.drawTextTransparent(x + 30, y + 7, label, if (selected) rgb(0x10, 0x30, 0x70) else rgb(0x10, 0x10, 0x18));
    }

    pub fn drawProgressBar(x: i32, y: i32, w: i32, h: i32, value: i32, max_val: i32) void {
        fb.draw3DRect(x, y, w, h, rgb(0xA0, 0xA8, 0xB8), rgb(0xFF, 0xFF, 0xFF));
        const ratio = @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(max_val));
        const fill_w = @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(w - 4))));
        if (fill_w > 0) {
            fb.fillRect(x + 2, y + 2, fill_w, h - 4, rgb(0x38, 0x78, 0x38));
            fb.drawGradientH(x + 2, y + 2, fill_w, 3, rgb(0x90, 0xE0, 0x90), rgb(0x38, 0x78, 0x38));
        }
    }
};
