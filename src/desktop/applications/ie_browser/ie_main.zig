// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/ie_browser/ie_main.zig
// Purpose: Internet Explorer 9 style browser main implementation
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const icons_mod = @import("../../kernel/icons/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");
const ie_strings = @import("ie_strings.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const IETab = struct {
    id: u32,
    title: [64]u8,
    title_len: usize,
    url: [2048]u8,
    url_len: usize,
    favicon: ?u16,
    is_loading: bool,
    can_go_back: bool,
    can_go_forward: bool,
    progress: i32,
    is_home: bool,
};

pub const IETabBar = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    tabs: [20]IETab,
    tab_count: usize,
    active_tab: i32,
    scroll_offset: i32,
    hover_tab: i32,

    pub fn create(x_pos: i32, y_pos: i32, w: i32) IETabBar {
        return .{
            .x = x_pos, .y = y_pos, .width = w, .height = 28,
            .tabs = undefined,
            .tab_count = 0,
            .active_tab = 0,
            .scroll_offset = 0,
            .hover_tab = -1,
        };
    }

    pub fn addTab(tb: *IETabBar, title: []const u8, url: []const u8) void {
        if (tb.tab_count >= tb.tabs.len) return;

        var tab = &tb.tabs[tb.tab_count];
        tab.id = @intCast(tb.tab_count);
        tab.title_len = @min(title.len, tab.title.len - 1);
        @memcpy(&tab.title, title[0..tab.title_len]);
        tab.title[tab.title_len] = 0;
        tab.url_len = @min(url.len, tab.url.len - 1);
        @memcpy(&tab.url, url[0..tab.url_len]);
        tab.url[tab.url_len] = 0;
        tab.favicon = null;
        tab.is_loading = false;
        tab.can_go_back = false;
        tab.can_go_forward = false;
        tab.progress = 0;
        tab.is_home = false;
        tb.tab_count += 1;
        tb.active_tab = @intCast(tb.tab_count - 1);
    }

    pub fn closeTab(tb: *IETabBar, index: usize) bool {
        if (index >= tb.tab_count or tb.tab_count <= 1) return false;
        var i: usize = index;
        while (i < tb.tabs.len - 1) : (i += 1) {
            tb.tabs[i] = tb.tabs[i + 1];
        }
        tb.tab_count -= 1;
        if (@as(usize, @intCast(tb.active_tab)) >= tb.tab_count) {
            tb.active_tab = @intCast(if (tb.tab_count > 0) tb.tab_count - 1 else 0);
        }
        return true;
    }

    pub fn render(tb: *IETabBar, t: *const theme_mod.ThemeColors) void {
        if (!tb.renderTabBarBackground(t)) return;
        tb.renderTabs(t);
        tb.renderNewTabButton(t);
    }

    fn renderTabBarBackground(tb: *IETabBar, t: *const theme_mod.ThemeColors) bool {
        _ = t;
        fb.fillRect(tb.x, tb.y, tb.width, tb.height, rgb(0xE8, 0xEC, 0xF0));
        fb.drawHLine(tb.x, tb.y + tb.height - 1, tb.width, rgb(0xC0, 0xC8, 0xD8));
        return true;
    }

    fn renderTabs(tb: *IETabBar, t: *const theme_mod.ThemeColors) void {
        _ = t;
        var tab_x = tb.x + 2;
        for (tb.tabs[0..tb.tab_count], 0..) |*tab, idx| {
            const is_active = @as(i32, @intCast(idx)) == tb.active_tab;
            const tab_width: i32 = @as(i32, @intCast(tab.title_len)) * 7 + 40;
            const tab_rect_x = tab_x - tb.scroll_offset;

            if (tab_rect_x < tb.x + tb.width and tab_rect_x + tab_width > tb.x) {
                if (is_active) {
                    fb.fillRect(tab_rect_x, tb.y + 2, tab_width, tb.height - 2, rgb(0xF8, 0xF8, 0xFC));
                    fb.drawHLine(tab_rect_x, tb.y + tb.height - 1, tab_width, rgb(0xF8, 0xF8, 0xFC));
                    fb.drawHLine(tab_rect_x, tb.y, tab_width, rgb(0xE8, 0xEC, 0xF0));
                    fb.drawVLine(tab_rect_x, tb.y, tb.height, rgb(0xC0, 0xC8, 0xD8));
                } else {
                    fb.fillRect(tab_rect_x, tb.y + 4, tab_width, tb.height - 5, rgb(0xD8, 0xDC, 0xE4));
                }

                if (tab.is_loading) {
                    const prog_w = @as(i32, @intCast(@as(f32, @floatFromInt(tab_width - 8)) * @as(f32, @floatFromInt(tab.progress)) / 100.0));
                    fb.fillRect(tab_rect_x + 4, tb.y + 2, prog_w, 2, rgb(0x5C, 0x9E, 0xD6));
                }

                fb.drawTextTransparent(tab_rect_x + 8, tb.y + 6, tab.title[0..tab.title_len], if (is_active) rgb(0x10, 0x10, 0x20) else rgb(0x40, 0x40, 0x50));
                fb.drawTextTransparent(tab_rect_x + tab_width - 18, tb.y + 7, "x", if (@as(isize, @intCast(idx)) == tb.hover_tab) rgb(0x80, 0x80, 0x88) else rgb(0x60, 0x60, 0x68));
            }
            tab_x += tab_width + 2;
        }
    }

    fn renderNewTabButton(tb: *IETabBar, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const btn_x = tb.x + tb.width - 26;
        fb.fillRect(btn_x, tb.y + 4, 20, 20, rgb(0xD8, 0xDC, 0xE4));
        fb.drawTextTransparent(btn_x + 5, tb.y + 6, "+", rgb(0x40, 0x40, 0x50));
    }
};

pub const IEAddressBar = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    url: [2048]u8,
    url_len: usize,
    is_editing: bool,
    show_dropdown: bool,
    dropdown_items: [20][]const u8,
    dropdown_count: usize,
    secure_icon: bool,
    protocol_https: bool,

    pub fn create(x_pos: i32, y_pos: i32, w: i32) IEAddressBar {
        return .{
            .x = x_pos, .y = y_pos, .width = w, .height = 24,
            .url = undefined,
            .url_len = 0,
            .is_editing = false,
            .show_dropdown = false,
            .dropdown_items = undefined,
            .dropdown_count = 0,
            .secure_icon = false,
            .protocol_https = false,
        };
    }

    pub fn setUrl(ab: *IEAddressBar, url_text: []const u8) void {
        ab.url_len = @min(url_text.len, ab.url.len - 1);
        @memcpy(&ab.url, url_text[0..ab.url_len]);
        ab.url[ab.url_len] = 0;
        ab.secure_icon = std.mem.startsWith(u8, url_text, "https://");
        ab.protocol_https = ab.secure_icon;
    }

    pub fn addDropdownItem(ab: *IEAddressBar, item: []const u8) void {
        if (ab.dropdown_count < ab.dropdown_items.len) {
            ab.dropdown_items[ab.dropdown_count] = item;
            ab.dropdown_count += 1;
        }
    }

    pub fn render(ab: *IEAddressBar, t: *const theme_mod.ThemeColors) void {
        _ = t;
        fb.fillRect(ab.x, ab.y, ab.width, ab.height, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(ab.x, ab.y, ab.width, ab.height, rgb(0x90, 0x98, 0xA8), rgb(0xFF, 0xFF, 0xFF));

        const text_x = ab.x + 4;
        const text_y = ab.y + @divTrunc(ab.height - 14, 2);

        if (ab.secure_icon) {
            fb.drawTextTransparent(text_x, text_y, "[S]", rgb(0x20, 0x80, 0x20));
            fb.drawTextTransparent(text_x + 24, text_y, ab.url[0..ab.url_len], rgb(0x10, 0x10, 0x18));
        } else {
            fb.drawTextTransparent(text_x, text_y, ab.url[0..ab.url_len], rgb(0x10, 0x10, 0x18));
        }

        const go_btn_x = ab.x + ab.width - 24;
        fb.fillRect(go_btn_x, ab.y + 2, 22, ab.height - 4, rgb(0xE4, 0xE8, 0xF0));
        fb.draw3DRect(go_btn_x, ab.y + 2, 22, ab.height - 4, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(go_btn_x + 5, text_y, "Go", rgb(0x20, 0x20, 0x28));

        if (ab.is_editing) {
            fb.drawRect(ab.x + 1, ab.y + 1, ab.width - 2, ab.height - 2, rgb(0x5C, 0x9E, 0xD6));
        }
    }
};

pub const IEToolbar = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    back_enabled: bool,
    forward_enabled: bool,
    refresh_enabled: bool,
    stop_enabled: bool,
    stop_mode: bool,

    pub fn create(x_pos: i32, y_pos: i32, w: i32) IEToolbar {
        return .{
            .x = x_pos, .y = y_pos, .width = w, .height = 32,
            .back_enabled = false,
            .forward_enabled = false,
            .refresh_enabled = true,
            .stop_enabled = false,
            .stop_mode = false,
        };
    }

    pub fn render(tb: *IEToolbar, t: *const theme_mod.ThemeColors) void {
        fb.fillRect(tb.x, tb.y, tb.width, tb.height, rgb(0xF0, 0xF4, 0xF8));
        fb.drawHLine(tb.x, tb.y + tb.height - 1, tb.width, rgb(0xC0, 0xC8, 0xD8));

        const btn_x = tb.x + 8;
        tb.renderToolbarButton(btn_x, "←", tb.back_enabled, t);
        tb.renderToolbarButton(btn_x + 28, "→", tb.forward_enabled, t);
        tb.renderToolbarButton(btn_x + 56, if (tb.stop_mode) "■" else "↻", tb.refresh_enabled, t);
        tb.renderToolbarButton(btn_x + 84, "★", true, t);
        tb.renderToolbarButton(btn_x + 112, "⚙", true, t);
        tb.renderToolbarButton(btn_x + 140, "?", true, t);
    }

    fn renderToolbarButton(tb: *IEToolbar, bx: i32, enabled: bool, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const btn_w: i32 = 24;
        const btn_h: i32 = 24;
        const btn_y = tb.y + @divTrunc(tb.height - btn_h, 2);

        if (enabled) {
            fb.fillRect(bx, btn_y, btn_w, btn_h, rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(bx, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        } else {
            fb.fillRect(bx, btn_y, btn_w, btn_h, rgb(0xF8, 0xF8, 0xFC));
        }
    }
};

pub const IEFavoritesBar = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    items: []IEFavItem,
    visible: bool,

    pub const IEFavItem = struct {
        name: []const u8,
        url: []const u8,
    };

    pub fn create(x_pos: i32, y_pos: i32, w: i32) IEFavoritesBar {
        return .{
            .x = x_pos, .y = y_pos, .width = w, .height = 24,
            .items = &[_]IEFavItem{},
            .visible = true,
        };
    }

    pub fn render(fb_bar: *IEFavoritesBar, t: *const theme_mod.ThemeColors) void {
        _ = t;
        if (!fb_bar.visible) return;
        fb.fillRect(fb_bar.x, fb_bar.y, fb_bar.width, fb_bar.height, rgb(0xE8, 0xEC, 0xF0));
        fb.drawHLine(fb_bar.x, fb_bar.y + fb_bar.height - 1, fb_bar.width, rgb(0xC0, 0xC8, 0xD8));

        var item_x = fb_bar.x + 8;
        for (fb_bar.items) |*item| {
            const item_w: i32 = @as(i32, @intCast(item.name.len)) * 7 + 12;
            if (item_x + item_w < fb_bar.x + fb_bar.width - 24) {
                fb.drawTextTransparent(item_x, fb_bar.y + 5, item.name, rgb(0x20, 0x40, 0x80));
            }
            item_x += item_w + 8;
        }

        fb.drawTextTransparent(fb_bar.x + fb_bar.width - 20, fb_bar.y + 5, "★", rgb(0x40, 0x40, 0x50));
    }
};

pub const IEStatusBar = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    message: []const u8,
    progress: i32,
    show_progress: bool,
    zoom_level: i32,

    pub fn create(x_pos: i32, y_pos: i32, w: i32) IEStatusBar {
        return .{
            .x = x_pos, .y = y_pos, .width = w, .height = 22,
            .message = "Done",
            .progress = 100,
            .show_progress = false,
            .zoom_level = 100,
        };
    }

    pub fn render(sb: *IEStatusBar, t: *const theme_mod.ThemeColors) void {
        _ = t;
        fb.fillRect(sb.x, sb.y, sb.width, sb.height, rgb(0xE8, 0xEC, 0xF0));
        fb.drawHLine(sb.x, sb.y, sb.width, rgb(0xFF, 0xFF, 0xFF));
        fb.drawHLine(sb.x, sb.y + sb.height - 1, sb.width, rgb(0xC0, 0xC8, 0xD8));

        fb.drawTextTransparent(sb.x + 8, sb.y + 5, sb.message, rgb(0x30, 0x30, 0x40));

        if (sb.show_progress) {
            const bar_x = sb.x + 80;
            const bar_w = 200;
            const bar_h = 12;
            const bar_y = sb.y + @divTrunc(sb.height - bar_h, 2);

            fb.fillRect(bar_x, bar_y, bar_w, bar_h, rgb(0xD8, 0xDC, 0xE4));
            fb.draw3DRect(bar_x, bar_y, bar_w, bar_h, rgb(0xA0, 0xA8, 0xB8), rgb(0xFF, 0xFF, 0xFF));

            const fill_w = @as(i32, @intCast(@as(f32, @floatFromInt(bar_w - 4)) * @as(f32, @floatFromInt(sb.progress)) / 100.0));
            if (fill_w > 0) {
                fb.fillRect(bar_x + 2, bar_y + 2, fill_w, bar_h - 4, rgb(0x38, 0x78, 0x38));
            }
        }

        var zoom_buf: [16]u8 = undefined;
        const zoom_text = std.fmt.bufPrint(&zoom_buf, "{d}%", .{sb.zoom_level}) catch "100%";
        const zoom_x = sb.x + sb.width - 60;
        fb.drawTextTransparent(zoom_x, sb.y + 5, zoom_text, rgb(0x30, 0x30, 0x40));
    }
};

pub const IEBrowser = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    title: []const u8,
    visible: bool,
    focused: bool,
    is_loading: bool,
    load_progress: i32,

    tab_bar: IETabBar,
    toolbar: IEToolbar,
    address_bar: IEAddressBar,
    favorites_bar: IEFavoritesBar,
    status_bar: IEStatusBar,

    caption_hover: CaptionButtonType,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) IEBrowser {
        return .{
            .x = x_pos, .y = y_pos, .width = w, .height = h,
            .title = ie_strings.ieString("window_title"),
            .visible = true,
            .focused = false,
            .is_loading = false,
            .load_progress = 100,

            .tab_bar = IETabBar.create(x_pos, y_pos + 32, w),
            .toolbar = IEToolbar.create(x_pos, y_pos + 60, w),
            .address_bar = IEAddressBar.create(x_pos + 80, y_pos + 95, w - 160),
            .favorites_bar = IEFavoritesBar.create(x_pos, y_pos + 122, w),
            .status_bar = IEStatusBar.create(x_pos, y_pos + h - 22, w),
            .caption_hover = .none,
        };
    }

    pub fn navigateTo(ie: *IEBrowser, url: []const u8) void {
        ie.is_loading = true;
        ie.load_progress = 0;
        ie.address_bar.setUrl(&ie.address_bar, url);
        ie.status_bar.message = ie_strings.ieString("loading");
        ie.status_bar.show_progress = true;
    }

    pub fn setLoadProgress(ie: *IEBrowser, progress: i32) void {
        ie.load_progress = progress;
        ie.status_bar.progress = progress;
        if (progress >= 100) {
            ie.is_loading = false;
            ie.status_bar.show_progress = false;
            ie.status_bar.message = ie_strings.ieString("done");
            ie.toolbar.stop_mode = false;
        }
    }

    pub fn stop(ie: *IEBrowser) void {
        ie.is_loading = false;
        ie.status_bar.show_progress = false;
        ie.status_bar.message = "Stopped";
        ie.toolbar.stop_mode = false;
    }

    pub fn render(ie: *IEBrowser, t: *const theme_mod.ThemeColors) void {
        if (!ie.visible) return;
        ie.renderWindowFrame(t);
        ie.renderClientArea(t);
    }

    fn renderWindowFrame(ie: *IEBrowser, t: *const theme_mod.ThemeColors) void {
        const wx = ie.x;
        const wy = ie.y;
        const ww = ie.width;
        const wh = ie.height;
        const ch: i32 = 32;

        if (dwm_mod.isInitialized() and dwm_mod.getConfig().shadow_enabled) {
            fb.fillRect(wx + 4, wy + 4, ww, wh, rgb(0x28, 0x28, 0x30));
        }

        fb.fillRect(wx, wy + ch, ww, wh - ch, t.window_bg);

        if (dwm_mod.isGlassEnabled()) {
            const active_color = if (ie.focused) t.titlebar_active_left else t.titlebar_inactive_left;
            dwm_mod.renderGlassEffect(wx, wy, ww, ch, active_color, .caption);
        } else {
            const left_color = if (ie.focused) t.titlebar_active_left else t.titlebar_inactive_left;
            const right_color = if (ie.focused) t.titlebar_active_right else t.titlebar_inactive_right;
            fb.drawGradientH(wx, wy, ww, ch, left_color, right_color);
        }

        ie.renderCaptionButtons(t);

        const text_x = wx + 8;
        const text_y = wy + @divTrunc(ch - 14, 2);
        const text_color = if (ie.focused) t.titlebar_text else t.titlebar_inactive_text;
        fb.drawTextTransparent(text_x, text_y, ie.title, text_color);

        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    fn renderCaptionButtons(ie: *IEBrowser, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = ie.x;
        const wy = ie.y;
        const ww = ie.width;
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

        if (ie.caption_hover == .minimize) {
            fb.blendTintRect(min_x, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
        }
        if (ie.caption_hover == .maximize) {
            fb.blendTintRect(max_x, btn_y, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), 22, 120);
        }
        if (ie.caption_hover == .close) {
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
            fb.putPixel32(@intCast(cx + d), @intCast(cy + d), if (ie.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
            fb.putPixel32(@intCast(cx + d), @intCast(cy - d), if (ie.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
        }
    }

    fn renderClientArea(ie: *IEBrowser, t: *const theme_mod.ThemeColors) void {
        ie.tab_bar.render(&ie.tab_bar, t);
        ie.toolbar.render(&ie.toolbar, t);
        ie.address_bar.render(&ie.address_bar, t);
        ie.favorites_bar.render(&ie.favorites_bar, t);

        const content_x = ie.x + 4;
        const content_y = ie.y + 150;
        const content_w = ie.width - 8;
        const content_h = ie.height - 176;
        fb.fillRect(content_x, content_y, content_w, content_h, rgb(0xFF, 0xFF, 0xFF));

        const url_text = ie.address_bar.url[0..ie.address_bar.url_len];
        if (url_text.len > 0) {
            fb.drawTextTransparent(content_x + 20, content_y + 40, url_text, rgb(0x40, 0x40, 0x50));
        } else {
            const placeholder = ie_strings.ieString("address_placeholder");
            fb.drawTextTransparent(content_x + 20, content_y + 40, placeholder, rgb(0xA0, 0xA0, 0xA0));
        }

        ie.status_bar.render(&ie.status_bar, t);
    }
};
