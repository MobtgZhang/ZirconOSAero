// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/cp_main.zig
// Purpose: Control Panel main window
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const icons_mod = @import("../../kernel/icons/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");
const cp_strings = @import("cp_strings.zig");
const cp_applets = @import("cp_applets.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const ControlPanelView = enum {
    category,
    classic,
};

pub const CPCategory = struct {
    id: u32,
    name: []const u8,
    description: []const u8,
    icon_id: icons_mod.IconId,
    applets: []const cp_applets.CPAppletId,
};

pub const CPAppletItem = struct {
    id: cp_applets.CPAppletId,
    name: []const u8,
    description: []const u8,
    icon_id: icons_mod.IconId,
    category_id: u32,
};

pub const ControlPanel = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    title: []const u8,
    visible: bool,
    focused: bool,
    view_mode: ControlPanelView,
    search_text: []u8,
    search_focused: bool,
    selected_category: i32,
    selected_applet: i32,
    hover_category: i32,
    hover_applet: i32,
    caption_hover: CaptionButtonType,
    show_nav_pane: bool,
    nav_width: i32,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) ControlPanel {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = w,
            .height = h,
            .title = cp_strings.cpString("window_title"),
            .visible = true,
            .focused = false,
            .view_mode = .category,
            .search_text = &[_]u8{},
            .search_focused = false,
            .selected_category = -1,
            .selected_applet = -1,
            .hover_category = -1,
            .hover_applet = -1,
            .caption_hover = .none,
            .show_nav_pane = true,
            .nav_width = 200,
        };
    }

    pub fn setViewMode(cp: *ControlPanel, mode: ControlPanelView) void {
        cp.view_mode = mode;
    }

    pub fn search(cp: *ControlPanel, query: []const u8) void {
        const len = @min(query.len, cp.search_text.len);
        @memcpy(cp.search_text[0..len], query[0..len]);
        cp.search_text.len = len;
    }

    pub fn selectApplet(cp: *ControlPanel, applet_id: cp_applets.CPAppletId) void {
        _ = applet_id;
        cp.selected_applet = 0;
    }

    pub fn render(cp: *ControlPanel, t: *const theme_mod.ThemeColors) void {
        if (!cp.visible) return;
        cp.renderWindowFrame(t);
        cp.renderClientArea(t);
    }

    fn renderWindowFrame(cp: *ControlPanel, t: *const theme_mod.ThemeColors) void {
        const wx = cp.x;
        const wy = cp.y;
        const ww = cp.width;
        const wh = cp.height;
        const ch: i32 = 32;

        if (dwm_mod.isInitialized() and dwm_mod.getConfig().shadow_enabled) {
            fb.fillRect(wx + 4, wy + 4, ww, wh, rgb(0x28, 0x28, 0x30));
        }

        fb.fillRect(wx, wy + ch, ww, wh - ch, t.window_bg);

        if (dwm_mod.isGlassEnabled()) {
            const active_color = if (cp.focused) t.titlebar_active_left else t.titlebar_inactive_left;
            dwm_mod.renderGlassEffect(wx, wy, ww, ch, active_color, .caption);
        } else {
            const left_color = if (cp.focused) t.titlebar_active_left else t.titlebar_inactive_left;
            const right_color = if (cp.focused) t.titlebar_active_right else t.titlebar_inactive_right;
            fb.drawGradientH(wx, wy, ww, ch, left_color, right_color);
        }

        cp.renderCaptionButtons(t);

        const text_x = wx + 8;
        const text_y = wy + @divTrunc(ch - 14, 2);
        const text_color = if (cp.focused) t.titlebar_text else t.titlebar_inactive_text;
        fb.drawTextTransparent(text_x, text_y, cp.title, text_color);

        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    fn renderCaptionButtons(cp: *ControlPanel, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = cp.x;
        const wy = cp.y;
        const ww = cp.width;
        const ch: i32 = 32;

        const vpad: i32 = 2;
        const btn_h = @max(18, ch - 2 * vpad);
        const btn_y = wy + @divTrunc(ch - btn_h, 2);
        const btn_w: i32 = 40;
        const btn_w_close: i32 = 48;
        const close_x = wx + ww - btn_w_close;
        const max_x = close_x - btn_w;
        const min_x = max_x - btn_w;

        fb.drawVLine(min_x - 1, wy + 1, ch - 2, rgb(0xB8, 0xD0, 0xE8));
        fb.drawVLine(max_x, wy + 1, ch - 2, rgb(0x3A, 0x5A, 0x78));
        fb.drawVLine(close_x, wy + 1, ch - 2, rgb(0x3A, 0x5A, 0x78));

        if (cp.caption_hover == .minimize) {
            fb.blendTintRect(min_x, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
        }
        if (cp.caption_hover == .maximize) {
            fb.blendTintRect(max_x, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
        }
        if (cp.caption_hover == .close) {
            fb.fillRect(close_x, btn_y, btn_w_close, btn_h, rgb(0xE8, 0x11, 0x23));
        }

        fb.fillRect(min_x + 14, btn_y + btn_h - 4, 12, 2, rgb(0xE8, 0xF2, 0xFA));
        fb.drawRect(min_x + 12, btn_y + 4, 16, 12, rgb(0xE8, 0xF2, 0xFA));
        fb.drawHLine(min_x + 12, btn_y + 5, 16, rgb(0xE8, 0xF2, 0xFA));

        const cx: i32 = close_x + @divTrunc(btn_w_close, 2);
        const cy: i32 = btn_y + @divTrunc(btn_h, 2);
        const arm: i32 = 4;
        var d: i32 = -arm;
        while (d <= arm) : (d += 1) {
            fb.putPixel32(@intCast(cx + d), @intCast(cy + d), if (cp.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
            fb.putPixel32(@intCast(cx + d), @intCast(cy - d), if (cp.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
        }
    }

    fn renderClientArea(cp: *ControlPanel, t: *const theme_mod.ThemeColors) void {
        cp.renderToolbar(t);

        if (cp.show_nav_pane and cp.view_mode == .category) {
            cp.renderNavigationPane(t);
        }

        if (cp.view_mode == .category) {
            cp.renderCategoryView(t);
        } else {
            cp.renderClassicView(t);
        }
    }

    fn renderToolbar(cp: *ControlPanel, _: *const theme_mod.ThemeColors) void {
        const tx = cp.x + 4;
        const ty = cp.y + 36;
        const tw = cp.width - 8;
        const th: i32 = 32;

        fb.fillRect(tx, ty, tw, th, rgb(0xF0, 0xF4, 0xF8));
        fb.drawHLine(tx, ty + th - 1, tw, rgb(0xC0, 0xC8, 0xD8));

        const btn_w: i32 = 100;
        const category_btn_x = tx + 8;
        const classic_btn_x = tx + 8 + btn_w + 8;

        if (cp.view_mode == .category) {
            fb.fillRect(category_btn_x, ty + 4, btn_w, 24, rgb(0xD8, 0xE0, 0xEC));
            fb.draw3DRect(category_btn_x, ty + 4, btn_w, 24, rgb(0x80, 0x88, 0x98), rgb(0xFF, 0xFF, 0xFF));
        }
        fb.drawTextTransparent(category_btn_x + 8, ty + 10, cp_strings.cpString("category_view"), if (cp.view_mode == .category) rgb(0x10, 0x40, 0x90) else rgb(0x30, 0x30, 0x40));

        if (cp.view_mode == .classic) {
            fb.fillRect(classic_btn_x, ty + 4, btn_w, 24, rgb(0xD8, 0xE0, 0xEC));
            fb.draw3DRect(classic_btn_x, ty + 4, btn_w, 24, rgb(0x80, 0x88, 0x98), rgb(0xFF, 0xFF, 0xFF));
        }
        fb.drawTextTransparent(classic_btn_x + 8, ty + 10, cp_strings.cpString("classic_view"), if (cp.view_mode == .classic) rgb(0x10, 0x40, 0x90) else rgb(0x30, 0x30, 0x40));
    }

    fn renderNavigationPane(cp: *ControlPanel, _: *const theme_mod.ThemeColors) void {
        const nx = cp.x + 4;
        const ny = cp.y + 72;
        const nw = cp.nav_width;
        const nh = cp.height - 76;

        fb.fillRect(nx, ny, nw, nh, rgb(0xF0, 0xF4, 0xF8));
        fb.drawHLine(nx, ny + nh - 1, nw, rgb(0xC0, 0xC8, 0xD8));

        const categories = cp_strings.getCategories();
        var cat_y = ny + 8;
        for (categories, 0..) |cat, idx| {
            const is_hover = @as(i32, @intCast(idx)) == cp.hover_category;
            const is_selected = @as(i32, @intCast(idx)) == cp.selected_category;

            if (is_hover) {
                fb.fillRect(nx + 4, cat_y, nw - 8, 28, rgb(0xD8, 0xE4, 0xF0));
            }
            if (is_selected) {
                fb.fillRect(nx + 2, cat_y, 4, 28, rgb(0x10, 0x40, 0x90));
            }

            fb.drawTextTransparent(nx + 12, cat_y + 7, cat, if (is_selected) rgb(0x10, 0x40, 0x90) else rgb(0x20, 0x20, 0x30));
            cat_y += 32;
        }
    }

    fn renderCategoryView(cp: *ControlPanel, _: *const theme_mod.ThemeColors) void {
        const cx = cp.x + cp.nav_width + 8;
        const cy = cp.y + 72;
        const cw = cp.width - cp.nav_width - 16;
        const ch = cp.height - 76;

        fb.fillRect(cx, cy, cw, ch, rgb(0xF8, 0xFC, 0xFF));

        const title_y = cy + 8;
        fb.drawTextTransparent(cx + 8, title_y, cp_strings.cpString("system_and_security"), rgb(0x20, 0x20, 0x30));

        const items_y = cy + 36;
        const item_w: i32 = 160;
        const item_h: i32 = 80;
        const spacing: i32 = 12;

        var item_x = cx + 8;
        var item_y = items_y;

        const items = cp_applets.getSystemApplets();
        for (items, 0..) |item, idx| {
            const is_hover = @as(i32, @intCast(idx)) == cp.hover_applet;
            const is_selected = @as(i32, @intCast(idx)) == cp.selected_applet;

            if (item_x + item_w > cx + cw - 8) {
                item_x = cx + 8;
                item_y += item_h + spacing;
            }

            if (is_hover) {
                fb.fillRect(item_x - 2, item_y - 2, item_w + 4, item_h + 4, rgb(0xE0, 0xE8, 0xF0));
            }
            if (is_selected) {
                fb.fillRect(item_x - 2, item_y - 2, item_w + 4, item_h + 4, rgb(0xC0, 0xD8, 0xF0));
            }

            fb.fillRect(item_x, item_y, item_w, item_h, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(item_x, item_y, item_w, item_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF0));

            const icon_x = item_x + @divTrunc(item_w - 48, 2);
            fb.fillRect(icon_x, item_y + 8, 48, 32, rgb(0xE8, 0xEC, 0xF4));
            fb.drawTextTransparent(icon_x + 12, item_y + 16, "Icon", rgb(0x60, 0x60, 0x70));

            fb.drawTextTransparentClipped(item_x + 4, item_y + 46, item_x + item_w - 4, item.name, rgb(0x10, 0x20, 0x40));

            item_x += item_w + spacing;
        }
    }

    fn renderClassicView(cp: *ControlPanel, _: *const theme_mod.ThemeColors) void {
        const cx = cp.x + 8;
        const cy = cp.y + 72;
        const cw = cp.width - 16;
        const ch = cp.height - 76;

        fb.fillRect(cx, cy, cw, ch, rgb(0xF8, 0xFC, 0xFF));

        const item_w: i32 = 80;
        const item_h: i32 = 80;
        const spacing: i32 = 16;

        var item_x = cx + 8;
        var item_y = cy + 8;

        const applets = cp_applets.getAllApplets();
        for (applets, 0..) |applet, idx| {
            if (item_x + item_w > cx + cw - 8) {
                item_x = cx + 8;
                item_y += item_h + spacing;
            }

            const is_hover = @as(i32, @intCast(idx)) == cp.hover_applet;

            if (is_hover) {
                fb.fillRect(item_x - 2, item_y - 2, item_w + 4, item_h + 4, rgb(0xE0, 0xE8, 0xF0));
            }

            fb.fillRect(item_x, item_y, item_w, item_h, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(item_x, item_y, item_w, item_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF0));

            const icon_x = item_x + @divTrunc(item_w - 32, 2);
            fb.fillRect(icon_x, item_y + 8, 32, 32, rgb(0xE8, 0xEC, 0xF4));

            fb.drawTextTransparentClipped(item_x + 2, item_y + 46, item_x + item_w - 2, applet.name, rgb(0x10, 0x20, 0x40));

            item_x += item_w + spacing;
        }
    }
};
