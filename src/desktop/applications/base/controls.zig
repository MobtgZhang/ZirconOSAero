// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/base/controls.zig
// Purpose: Win7 Aero style UI controls library
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

const Point = struct { x: i32, y: i32 };
const Rect = struct {
    x: i32, y: i32, width: i32, height: i32,
    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and px < r.x + r.width and py >= r.y and py < r.y + r.height;
    }
};

pub const ControlState = enum { normal, hover, pressed, disabled, focused };
pub const MouseButton = enum { left, right, middle };

pub const Control = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    enabled: bool,
    state: ControlState,
    tooltip: []const u8 = &[_]u8{},

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) Control {
        return .{
            .x = x_pos, .y = y_pos,
            .width = w, .height = h,
            .visible = true, .enabled = true,
            .state = .normal,
        };
    }

    pub fn hitTest(c: *const Control, px: i32, py: i32) bool {
        const r = Rect{ .x = c.x, .y = c.y, .width = c.width, .height = c.height };
        return c.visible and c.enabled and r.contains(px, py);
    }

    pub fn setState(c: *Control, s: ControlState) void { c.state = s; }

    pub fn getClientRect(c: *const Control) Rect {
        return .{ .x = c.x, .y = c.y, .width = c.width, .height = c.height };
    }
};

pub const Button = struct {
    control: Control,
    text: []const u8,
    icon: ?u16,
    default: bool,
    cancel: bool,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32, btn_text: []const u8) Button {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .text = btn_text,
            .icon = null,
            .default = false,
            .cancel = false,
        };
    }

    pub fn render(b: *Button, _: *const theme_mod.ThemeColors) void {
        if (!b.control.visible) return;
        const x = b.control.x;
        const y = b.control.y;
        const w = b.control.width;
        const h = b.control.height;

        const is_pressed = b.control.state == .pressed;
        const is_hover = b.control.state == .hover;
        const is_disabled = !b.control.enabled;

        const offset_x: i32 = if (is_pressed) 1 else 0;
        const offset_y: i32 = if (is_pressed) 1 else 0;

        if (b.control.state == .normal or is_hover or is_pressed) {
            if (is_pressed) {
                fb.fillRect(x + offset_x, y + offset_y, w, h, rgb(0xD0, 0xD0, 0xD8));
                fb.draw3DRect(x + offset_x, y + offset_y, w, h, rgb(0x60, 0x60, 0x68), rgb(0xF8, 0xF8, 0xFF));
            } else if (is_hover) {
                fb.fillRect(x + offset_x, y + offset_y, w, h, rgb(0xE8, 0xEC, 0xF4));
                fb.draw3DRect(x + offset_x, y + offset_y, w, h, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            } else {
                fb.fillRect(x + offset_x, y + offset_y, w, h, rgb(0xE4, 0xE8, 0xF0));
                fb.draw3DRect(x + offset_x, y + offset_y, w, h, rgb(0xFF, 0xFF, 0xFF), rgb(0x88, 0x88, 0x90));
            }
        } else {
            fb.fillRect(x, y, w, h, rgb(0xEC, 0xEC, 0xEC));
            fb.draw3DRect(x, y, w, h, rgb(0xF4, 0xF4, 0xF4), rgb(0xC0, 0xC0, 0xC0));
        }

        const text_color = if (is_disabled) rgb(0xA0, 0xA0, 0xA0) else rgb(0x20, 0x20, 0x28);
        const text_x = x + offset_x + @divTrunc(w, 2) - @divTrunc(@as(i32, @intCast(b.text.len * 7)), 2);
        const text_y = y + offset_y + @divTrunc(h - 14, 2);
        fb.drawTextTransparent(text_x, text_y, b.text, text_color);
    }
};

pub const TextField = struct {
    control: Control,
    text: []u8,
    max_length: usize,
    cursor_pos: usize,
    text_offset: i32,
    password_mode: bool,
    placeholder: []const u8,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) TextField {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .text = &[_]u8{},
            .max_length = 256,
            .cursor_pos = 0,
            .text_offset = 4,
            .password_mode = false,
            .placeholder = "",
        };
    }

    pub fn setText(tf: *TextField, new_text: []const u8) void {
        const len = @min(new_text.len, tf.max_length);
        @memcpy(tf.text[0..len], new_text[0..len]);
        tf.text.len = len;
        tf.cursor_pos = len;
    }

    pub fn render(tf: *TextField, _: *const theme_mod.ThemeColors) void {
        if (!tf.control.visible) return;
        const x = tf.control.x;
        const y = tf.control.y;
        const w = tf.control.width;
        const h = tf.control.height;
        const is_disabled = !tf.control.enabled;
        const is_focused = tf.control.state == .focused;

        if (is_focused) {
            fb.draw3DRect(x, y, w, h, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
            fb.fillRect(x + 1, y + 1, w - 2, h - 2, rgb(0xFF, 0xFF, 0xFF));
        } else {
            fb.draw3DRect(x, y, w, h, rgb(0x90, 0x98, 0xA8), rgb(0xFF, 0xFF, 0xFF));
            fb.fillRect(x + 1, y + 1, w - 2, h - 2, rgb(0xFF, 0xFF, 0xFF));
        }

        const display_text = if (tf.password_mode) std.mem.span(&tf.text) else std.mem.span(&tf.text);
        const text_color = if (is_disabled) rgb(0xA0, 0xA0, 0xA0) else rgb(0x10, 0x10, 0x18);
        const text_x = x + tf.text_offset;
        const text_y = y + @divTrunc(h - 14, 2);

        if (tf.text.len == 0 and tf.placeholder.len > 0) {
            fb.drawTextTransparent(text_x, text_y, tf.placeholder, rgb(0xA0, 0xA0, 0xA0));
        } else {
            fb.drawTextTransparent(text_x, text_y, display_text, text_color);
        }

        if (is_focused and tf.cursor_pos <= tf.text.len) {
            const cursor_x = x + tf.text_offset + @as(i32, @intCast(tf.cursor_pos)) * 8;
            fb.drawVLine(cursor_x, text_y, 14, rgb(0x00, 0x00, 0x00));
        }
    }
};

pub const ListViewItem = struct {
    text: []const u8,
    icon: ?u16,
    sub_items: [][]const u8,
    selected: bool,
    expanded: bool,
    data: usize,
};

pub const ListViewColumn = struct {
    text: []const u8,
    width: i32,
    align_right: bool,
};

pub const ListViewViewMode = enum { large_icon, small_icon, list, details };

pub const ListView = struct {
    control: Control,
    columns: []ListViewColumn,
    items: []ListViewItem,
    view_mode: ListViewViewMode,
    item_width: i32,
    item_height: i32,
    item_spacing: i32,
    scroll_y: i32,
    hover_index: isize,
    selected_index: isize,
    column_count: usize,
    show_header: bool,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) ListView {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .columns = &[_]ListViewColumn{},
            .items = &[_]ListViewItem{},
            .view_mode = .large_icon,
            .item_width = 80,
            .item_height = 80,
            .item_spacing = 8,
            .scroll_y = 0,
            .hover_index = -1,
            .selected_index = -1,
            .column_count = 0,
            .show_header = true,
        };
    }

    pub fn render(lv: *ListView, _: *const theme_mod.ThemeColors) void {
        if (!lv.control.visible) return;
        const x = lv.control.x;
        const y = lv.control.y;
        const w = lv.control.width;
        const h = lv.control.height;

        fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x, y, w, h, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF0));

        if (lv.view_mode == .details and lv.show_header) {
            var col_x: i32 = x + 2;
            const _col_y: i32 = y + 2;
            for (lv.columns) |col| {
                fb.fillRect(col_x, _col_y, col.width, 18, rgb(0xE8, 0xEC, 0xF0));
                fb.drawTextTransparent(col_x + 4, _col_y + 3, col.text, rgb(0x20, 0x20, 0x30));
                col_x += col.width + 1;
            }
            fb.drawHLine(x + 2, _col_y + 20, w - 4, rgb(0xC0, 0xC8, 0xD0));
        }

        const content_y = if (lv.view_mode == .details and lv.show_header) y + 22 else y + 2;
        var item_y = content_y - lv.scroll_y;
        var item_x = x + 4;
        const max_x = x + w - lv.item_width - 4;

        for (lv.items, 0..) |*item, idx| {
            const is_selected = idx == lv.selected_index;
            const is_hover = idx == lv.hover_index;

            if (item_y + lv.item_height >= y and item_y <= y + h) {
                if (is_selected) {
                    fb.fillRect(item_x - 2, item_y - 2, lv.item_width + 4, lv.item_height + 4, rgb(0xC8, 0xDC, 0xF0));
                } else if (is_hover) {
                    fb.fillRect(item_x - 2, item_y - 2, lv.item_width + 4, lv.item_height + 4, rgb(0xE8, 0xF0, 0xF8));
                }

                const text_y = item_y + lv.item_height - 18;
                const text_w = @min(@as(i32, @intCast(item.text.len)) * 7, lv.item_width - 4);
                fb.drawTextTransparentClipped(item_x + @divTrunc(lv.item_width - text_w, 2), text_y, item_x + lv.item_width, item.text, rgb(0x10, 0x10, 0x20));
            }

            if (lv.view_mode == .list) {
                item_y += lv.item_height + 2;
            } else {
                item_x += lv.item_width + lv.item_spacing;
                if (item_x > max_x) {
                    item_x = x + 4;
                    item_y += lv.item_height + lv.item_spacing;
                }
            }
        }
    }
};

pub const ScrollBarOrientation = enum { horizontal, vertical };

pub const ScrollBar = struct {
    control: Control,
    orientation: ScrollBarOrientation,
    value: i32,
    min_value: i32,
    max_value: i32,
    page_size: i32,
    thumb_pos: i32,
    thumb_size: i32,
    hover_part: ScrollBarPart,
    arrow_btn_height: i32,

    const ScrollBarPart = enum { none, arrow1, thumb, arrow2, track1, track2 };

    pub fn create(x_pos: i32, y_pos: i32, length: i32, is_vertical: bool) ScrollBar {
        const size = if (is_vertical) 16 else 16;
        return .{
            .control = Control.create(x_pos, y_pos, if (is_vertical) size else length, if (is_vertical) length else size),
            .orientation = if (is_vertical) .vertical else .horizontal,
            .value = 0,
            .min_value = 0,
            .max_value = 100,
            .page_size = 10,
            .thumb_pos = 0,
            .thumb_size = 20,
            .hover_part = .none,
            .arrow_btn_height = 16,
        };
    }

    pub fn setRange(sb: *ScrollBar, min: i32, max: i32) void {
        sb.min_value = min;
        sb.max_value = max;
    }

    pub fn setPageSize(sb: *ScrollBar, page: i32) void {
        sb.page_size = page;
    }

    pub fn render(sb: *ScrollBar, _: *const theme_mod.ThemeColors) void {
        if (!sb.control.visible) return;
        const x = sb.control.x;
        const y = sb.control.y;
        const w = sb.control.width;
        const h = sb.control.height;

        fb.fillRect(x, y, w, h, rgb(0xF0, 0xF0, 0xF0));
        fb.draw3DRect(x, y, w, h, rgb(0xC0, 0xC0, 0xC0), rgb(0xFF, 0xFF, 0xFF));

        const track_start = if (sb.orientation == .vertical) y + sb.arrow_btn_height else x + sb.arrow_btn_height;
        const track_len = if (sb.orientation == .vertical) h - 2 * sb.arrow_btn_height else w - 2 * sb.arrow_btn_height;

        const range = sb.max_value - sb.min_value;
        const thumb_ratio = if (range > 0) @as(f32, @floatFromInt(sb.value - sb.min_value)) / @as(f32, @floatFromInt(range)) else 0.0;
        const thumb_range = @as(i32, @intFromFloat(@as(f32, @floatFromInt(track_len)) * (1.0 - @as(f32, @floatFromInt(sb.page_size)) / @as(f32, @floatFromInt(range + sb.page_size)))));
        const thumb_offset = if (thumb_range > 0) @as(i32, @intFromFloat(thumb_ratio * @as(f32, @floatFromInt(thumb_range)))) else 0;

        if (sb.orientation == .vertical) {
            const thumb_y = track_start + thumb_offset;
            fb.fillRect(x + 2, thumb_y, w - 4, sb.thumb_size, rgb(0xC8, 0xD0, 0xD8));
            fb.draw3DRect(x + 2, thumb_y, w - 4, sb.thumb_size, rgb(0xFF, 0xFF, 0xFF), rgb(0x90, 0x98, 0xA8));
        } else {
            const thumb_x = track_start + thumb_offset;
            fb.fillRect(thumb_x, y + 2, sb.thumb_size, h - 4, rgb(0xC8, 0xD0, 0xD8));
            fb.draw3DRect(thumb_x, y + 2, sb.thumb_size, h - 4, rgb(0xFF, 0xFF, 0xFF), rgb(0x90, 0x98, 0xA8));
        }
    }
};

pub const ProgressBar = struct {
    control: Control,
    value: i32,
    min_value: i32,
    max_value: i32,
    show_text: bool,
    smooth: bool,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) ProgressBar {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .value = 0,
            .min_value = 0,
            .max_value = 100,
            .show_text = true,
            .smooth = true,
        };
    }

    pub fn setValue(pb: *ProgressBar, v: i32) void {
        pb.value = @max(pb.min_value, @min(pb.max_value, v));
    }

    pub fn render(pb: *ProgressBar, _: *const theme_mod.ThemeColors) void {
        if (!pb.control.visible) return;
        const x = pb.control.x;
        const y = pb.control.y;
        const w = pb.control.width;
        const h = pb.control.height;

        fb.draw3DRect(x, y, w, h, rgb(0xA0, 0xA8, 0xB8), rgb(0xFF, 0xFF, 0xFF));

        const ratio = @as(f32, @floatFromInt(pb.value - pb.min_value)) / @as(f32, @floatFromInt(pb.max_value - pb.min_value));
        const fill_w = @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(w - 4))));
        if (fill_w > 0) {
            fb.fillRect(x + 2, y + 2, fill_w, h - 4, rgb(0x38, 0x78, 0x38));
            fb.drawGradientH(x + 2, y + 2, fill_w, 3, rgb(0x90, 0xE0, 0x90), rgb(0x38, 0x78, 0x38));
        }

        if (pb.show_text) {
            var buf: [16]u8 = undefined;
            const txt = std.fmt.bufPrint(&buf, "{d}%", .{pb.value}) catch "%";
            const text_x = x + @divTrunc(w, 2) - @divTrunc(@as(i32, @intCast(txt.len * 6)), 2);
            const text_y = y + @divTrunc(h - 12, 2);
            fb.drawTextTransparent(text_x, text_y, txt, rgb(0xFF, 0xFF, 0xFF));
        }
    }
};

pub const TabControlTab = struct {
    text: []const u8,
    icon: ?u16,
    selected: bool,
};

pub const TabControl = struct {
    control: Control,
    tabs: []TabControlTab,
    active_index: i32,
    tab_height: i32,
    content_rect: Rect,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) TabControl {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .tabs = &[_]TabControlTab{},
            .active_index = 0,
            .tab_height = 24,
            .content_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };
    }

    pub fn render(tc: *TabControl, _: *const theme_mod.ThemeColors) void {
        if (!tc.control.visible) return;
        const x = tc.control.x;
        const y = tc.control.y;
        const w = tc.control.width;
        const h = tc.control.height;

        fb.fillRect(x, y, w, h, rgb(0xF8, 0xF8, 0xFC));
        fb.draw3DRect(x, y, w, h, rgb(0xA0, 0xA8, 0xB8), rgb(0xFF, 0xFF, 0xFF));

        var tab_x = x + 4;
        for (tc.tabs, 0..) |*tab, idx| {
            const is_selected = @as(i32, @intCast(idx)) == tc.active_index;
            const tab_w: i32 = @as(i32, @intCast(tab.text.len)) * 7 + 16;

            if (is_selected) {
                fb.fillRect(tab_x, y + 2, tab_w, tc.tab_height, rgb(0xF8, 0xF8, 0xFC));
                fb.drawHLine(tab_x, y + tc.tab_height + 2, tab_w, rgb(0xF8, 0xF8, 0xFC));
            } else {
                fb.fillRect(tab_x, y + 6, tab_w, tc.tab_height - 4, rgb(0xE0, 0xE4, 0xEC));
                fb.drawTextTransparent(tab_x + 8, y + 8, tab.text, rgb(0x30, 0x30, 0x40));
            }

            if (is_selected) {
                fb.drawTextTransparent(tab_x + 8, y + 6, tab.text, rgb(0x10, 0x10, 0x20));
            }
            tab_x += tab_w + 4;
        }

        fb.drawHLine(x + 2, y + tc.tab_height + 4, w - 4, rgb(0xC0, 0xC8, 0xD8));

        tc.content_rect = .{
            .x = x + 4,
            .y = y + tc.tab_height + 6,
            .width = w - 8,
            .height = h - tc.tab_height - 10,
        };
    }
};

pub const CheckBox = struct {
    control: Control,
    text: []const u8,
    checked: bool,
    tristate: bool,
    third_state: bool,

    pub fn create(x_pos: i32, y_pos: i32, checkbox_text: []const u8) CheckBox {
        return .{
            .control = Control.create(x_pos, y_pos, @as(i32, @intCast(checkbox_text.len)) * 7 + 20, 18),
            .text = checkbox_text,
            .checked = false,
            .tristate = false,
            .third_state = false,
        };
    }

    pub fn render(cb: *CheckBox, _: *const theme_mod.ThemeColors) void {
        if (!cb.control.visible) return;
        const x = cb.control.x;
        const y = cb.control.y;

        fb.fillRect(x, y + 2, 14, 14, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x, y + 2, 14, 14, rgb(0x80, 0x80, 0x88), rgb(0xFF, 0xFF, 0xFF));

        if (cb.checked) {
            fb.drawTextTransparent(x + 2, y, "✓", rgb(0x10, 0x40, 0x10));
        } else if (cb.tristate and cb.third_state) {
            fb.fillRect(x + 3, y + 5, 8, 2, rgb(0x60, 0x60, 0x60));
        }

        fb.drawTextTransparent(x + 18, y + 2, cb.text, rgb(0x20, 0x20, 0x28));
    }
};

pub const RadioButton = struct {
    control: Control,
    text: []const u8,
    selected: bool,
    group_id: u32,

    pub fn create(x_pos: i32, y_pos: i32, radio_text: []const u8, group: u32) RadioButton {
        return .{
            .control = Control.create(x_pos, y_pos, @as(i32, @intCast(radio_text.len)) * 7 + 20, 18),
            .text = radio_text,
            .selected = false,
            .group_id = group,
        };
    }

    pub fn render(rb: *RadioButton, _: *const theme_mod.ThemeColors) void {
        if (!rb.control.visible) return;
        const x = rb.control.x;
        const y = rb.control.y;

        fb.fillRect(x + 1, y + 3, 12, 12, rgb(0xFF, 0xFF, 0xFF));
        fb.drawEllipse(x, y + 2, 14, 14, rgb(0x80, 0x80, 0x88), rgb(0xFF, 0xFF, 0xFF));

        if (rb.selected) {
            fb.fillEllipse(x + 3, y + 5, 8, 8, rgb(0x20, 0x60, 0xC0));
        }

        fb.drawTextTransparent(x + 18, y + 2, rb.text, rgb(0x20, 0x20, 0x28));
    }
};

pub const GroupBox = struct {
    control: Control,
    text: []const u8,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32, group_text: []const u8) GroupBox {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .text = group_text,
        };
    }

    pub fn render(gb: *GroupBox, _: *const theme_mod.ThemeColors) void {
        if (!gb.control.visible) return;
        const x = gb.control.x;
        const y = gb.control.y;
        const w = gb.control.width;
        const h = gb.control.height;

        fb.draw3DRect(x, y + 8, w, h - 8, rgb(0xC0, 0xC8, 0xD8), rgb(0xFF, 0xFF, 0xFF));

        fb.fillRect(x + 8, y + 2, @as(i32, @intCast(gb.text.len)) * 7 + 4, 12);
        fb.drawTextTransparent(x + 10, y + 4, gb.text, rgb(0x20, 0x40, 0x80));
    }
};

pub const ComboBoxItem = struct {
    text: []const u8,
    data: usize,
};

pub const ComboBox = struct {
    control: Control,
    items: []ComboBoxItem,
    selected_index: i32,
    dropdown_open: bool,
    dropdown_height: i32,
    max_visible_items: i32,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) ComboBox {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .items = &[_]ComboBoxItem{},
            .selected_index = -1,
            .dropdown_open = false,
            .dropdown_height = 120,
            .max_visible_items = 6,
        };
    }

    pub fn render(cb: *ComboBox, _: *const theme_mod.ThemeColors) void {
        if (!cb.control.visible) return;
        const x = cb.control.x;
        const y = cb.control.y;
        const w = cb.control.width;
        const h = cb.control.height;

        fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x, y, w, h, rgb(0x90, 0x98, 0xA8), rgb(0xFF, 0xFF, 0xFF));

        const arrow_x = x + w - 18;
        fb.fillRect(arrow_x, y + 2, 16, h - 4, rgb(0xE0, 0xE4, 0xEC));
        fb.drawTextTransparent(arrow_x + 4, y + @divTrunc(h - 12, 2), "▼", rgb(0x40, 0x40, 0x50));

        if (cb.selected_index >= 0 and cb.selected_index < cb.items.len) {
            const sel_text = cb.items[@intCast(cb.selected_index)].text;
            fb.drawTextTransparent(x + 4, y + @divTrunc(h - 12, 2), sel_text, rgb(0x10, 0x10, 0x18));
        }

        if (cb.dropdown_open) {
            const drop_h = @min(cb.dropdown_height, @as(i32, @intCast(cb.items.len)) * 20 + 4);
            fb.fillRect(x, y + h, w, drop_h, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(x, y + h, w, drop_h, rgb(0x80, 0x88, 0x98), rgb(0xFF, 0xFF, 0xFF));

            var item_y = y + h + 2;
            const max_items: i32 = @intCast(@min(cb.items.len, @as(usize, @intCast(cb.max_visible_items))));
            for (0..@as(usize, @intCast(max_items))) |i| {
                const is_sel = @as(i32, @intCast(i)) == cb.selected_index;
                if (is_sel) {
                    fb.fillRect(x + 2, item_y, w - 4, 18, rgb(0xC8, 0xD8, 0xF0));
                }
                fb.drawTextTransparent(x + 4, item_y + 3, cb.items[i].text, rgb(0x10, 0x10, 0x18));
                item_y += 20;
            }
        }
    }
};

pub const Slider = struct {
    control: Control,
    value: f32,
    min_value: f32,
    max_value: f32,
    orientation: ScrollBarOrientation,
    thumb_width: i32,
    thumb_height: i32,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) Slider {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .value = 50.0,
            .min_value = 0.0,
            .max_value = 100.0,
            .orientation = .horizontal,
            .thumb_width = 10,
            .thumb_height = 20,
        };
    }

    pub fn render(s: *Slider, _: *const theme_mod.ThemeColors) void {
        if (!s.control.visible) return;
        const x = s.control.x;
        const y = s.control.y;
        const w = s.control.width;
        const h = s.control.height;

        fb.fillRect(x, y, w, h, rgb(0xF0, 0xF0, 0xF0));

        const track_y = y + @divTrunc(h, 2) - 2;
        const track_h: i32 = 4;
        fb.fillRect(x, track_y, w, track_h, rgb(0xC0, 0xC8, 0xD0));

        const range = s.max_value - s.min_value;
        const ratio = if (range != 0) (s.value - s.min_value) / range else 0.0;
        const thumb_x = x + @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(w - s.thumb_width))));

        fb.fillRect(thumb_x, track_y - 8, s.thumb_width, track_h + 16, rgb(0xD0, 0xD8, 0xE0));
        fb.draw3DRect(thumb_x, track_y - 8, s.thumb_width, track_h + 16, rgb(0xFF, 0xFF, 0xFF), rgb(0x90, 0x98, 0xA8));
    }
};

pub const Splitter = struct {
    control: Control,
    orientation: ScrollBarOrientation,
    min_size: i32,
    split_pos: i32,
    dragging: bool,

    pub fn create(x_pos: i32, y_pos: i32, length: i32, is_vertical: bool) Splitter {
        return .{
            .control = Control.create(x_pos, y_pos, if (is_vertical) 4 else length, if (is_vertical) length else 4),
            .orientation = if (is_vertical) .vertical else .horizontal,
            .min_size = 50,
            .split_pos = 0,
            .dragging = false,
        };
    }

    pub fn render(s: *Splitter, _: *const theme_mod.ThemeColors) void {
        if (!s.control.visible) return;
        const x = s.control.x;
        const y = s.control.y;
        const w = s.control.width;
        const h = s.control.height;

        if (s.dragging) {
            fb.fillRect(x, y, w, h, rgb(0x5C, 0x9E, 0xD6));
        } else {
            fb.fillRect(x, y, w, h, rgb(0xD8, 0xDC, 0xE4));
            fb.draw3DRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        }
    }
};

pub const MenuBarItem = struct {
    text: []const u8,
    submenu: ?[]MenuItem,
    shortcut: ?[]const u8,
};

pub const MenuItem = struct {
    text: []const u8,
    enabled: bool,
    separator: bool,
    checked: bool,
    submenu: ?[]MenuItem,
    shortcut: ?[]const u8,
    id: u32,
};

pub const MenuBar = struct {
    control: Control,
    items: []MenuBarItem,
    active_index: i32,
    dropdown_open: bool,

    pub fn create(x_pos: i32, y_pos: i32, w: i32) MenuBar {
        return .{
            .control = Control.create(x_pos, y_pos, w, 22),
            .items = &[_]MenuBarItem{},
            .active_index = -1,
            .dropdown_open = false,
        };
    }

    pub fn render(mb: *MenuBar, _: *const theme_mod.ThemeColors) void {
        if (!mb.control.visible) return;
        const x = mb.control.x;
        const y = mb.control.y;
        const w = mb.control.width;
        const h = mb.control.height;

        fb.fillRect(x, y, w, h, rgb(0xF0, 0xF4, 0xF8));
        fb.drawHLine(x, y + h - 1, w, rgb(0xC0, 0xC8, 0xD8));

        var item_x = x + 4;
        for (mb.items, 0..) |*item, idx| {
            const is_active = @as(i32, @intCast(idx)) == mb.active_index;
            const item_w: i32 = @as(i32, @intCast(item.text.len)) * 7 + 12;

            if (is_active) {
                fb.fillRect(item_x - 2, y + 1, item_w + 4, h - 2, rgb(0xE8, 0xF0, 0xF8));
                fb.drawHLine(item_x - 2, y + 1, item_w + 4, rgb(0xFF, 0xFF, 0xFF));
            }

            fb.drawTextTransparent(item_x, y + 5, item.text, rgb(0x20, 0x20, 0x30));
            item_x += item_w + 8;
        }
    }
};

pub const StatusBarPanel = struct {
    text: []const u8,
    width: i32,
    resizable: bool,
};

pub const StatusBar = struct {
    control: Control,
    panels: []StatusBarPanel,

    pub fn create(x_pos: i32, y_pos: i32, w: i32) StatusBar {
        return .{
            .control = Control.create(x_pos, y_pos, w, 22),
            .panels = &[_]StatusBarPanel{},
        };
    }

    pub fn render(sb: *StatusBar, _: *const theme_mod.ThemeColors) void {
        if (!sb.control.visible) return;
        const x = sb.control.x;
        const y = sb.control.y;
        const w = sb.control.width;
        const h = sb.control.height;

        fb.fillRect(x, y, w, h, rgb(0xE8, 0xEC, 0xF0));
        fb.drawHLine(x, y, w, rgb(0xFF, 0xFF, 0xFF));
        fb.drawHLine(x, y + h - 1, w, rgb(0xC0, 0xC8, 0xD8));

        var panel_x = x + 2;
        for (sb.panels) |*panel| {
            if (panel_x + panel.width > x + w) break;
            fb.drawVLine(panel_x + panel.width, y, h, rgb(0xC0, 0xC8, 0xD8));
            fb.drawTextTransparent(panel_x + 4, y + 5, panel.text, rgb(0x30, 0x30, 0x40));
            panel_x += panel.width + 2;
        }
    }
};

pub const ToolbarButton = struct {
    icon: ?u16,
    text: []const u8,
    tooltip: []const u8,
    enabled: bool,
    checked: bool,
    separator: bool,
    id: u32,
};

pub const Toolbar = struct {
    control: Control,
    buttons: []ToolbarButton,
    button_size: i32,
    icon_size: i32,
    show_text: bool,
    flat_style: bool,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32) Toolbar {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .buttons = &[_]ToolbarButton{},
            .button_size = 24,
            .icon_size = 16,
            .show_text = false,
            .flat_style = true,
        };
    }

    pub fn render(tb: *Toolbar, _: *const theme_mod.ThemeColors) void {
        if (!tb.control.visible) return;
        const x = tb.control.x;
        const y = tb.control.y;
        const w = tb.control.width;
        const h = tb.control.height;

        fb.fillRect(x, y, w, h, rgb(0xF0, 0xF4, 0xF8));
        fb.drawHLine(x, y + h - 1, w, rgb(0xC0, 0xC8, 0xD8));

        var btn_x = x + 4;
        for (tb.buttons) |*btn| {
            if (btn.separator) {
                fb.drawVLine(btn_x, y + 4, h - 8, rgb(0xC0, 0xC8, 0xD0));
                btn_x += 6;
                continue;
            }

            const btn_w = if (tb.show_text and btn.text.len > 0) @as(i32, @intCast(btn.text.len)) * 7 + 20 else tb.button_size;
            const btn_h = tb.button_size;

            if (!tb.flat_style) {
                if (btn.checked) {
                    fb.fillRect(btn_x, y + @divTrunc(h - btn_h, 2), btn_w, btn_h, rgb(0xD8, 0xE0, 0xE8));
                    fb.draw3DRect(btn_x, y + @divTrunc(h - btn_h, 2), btn_w, btn_h, rgb(0x80, 0x88, 0x98), rgb(0xFF, 0xFF, 0xFF));
                } else if (btn.enabled) {
                    fb.fillRect(btn_x, y + @divTrunc(h - btn_h, 2), btn_w, btn_h, rgb(0xF0, 0xF4, 0xF8));
                }
            }
            btn_x += btn_w + 4;
        }
    }
};

// ============================================================================
// TextArea - Multi-line Text Editor Control
// ============================================================================
pub const TextArea = struct {
    control: Control,
    text: []u8,
    buffer_capacity: usize,
    cursor_x: usize,
    cursor_y: usize,
    scroll_x: i32,
    scroll_y: i32,
    line_count: usize,
    max_lines: usize,
    char_width: i32,
    line_height: i32,
    read_only: bool,
    word_wrap: bool,
    show_line_numbers: bool,
    max_buffer_size: usize,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32, capacity: usize) TextArea {
        const max_lines_val = @as(usize, @intCast(@divTrunc(h, 16)));
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .text = &[_]u8{},
            .buffer_capacity = capacity,
            .cursor_x = 0,
            .cursor_y = 0,
            .scroll_x = 0,
            .scroll_y = 0,
            .line_count = 1,
            .max_lines = max_lines_val,
            .char_width = 8,
            .line_height = 16,
            .read_only = false,
            .word_wrap = true,
            .show_line_numbers = false,
            .max_buffer_size = capacity,
        };
    }

    pub fn createWithBuffer(x_pos: i32, y_pos: i32, w: i32, h: i32, buffer: []u8) TextArea {
        const max_lines_val = @as(usize, @intCast(@divTrunc(h, 16)));
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .text = buffer[0..0],
            .buffer_capacity = buffer.len,
            .cursor_x = 0,
            .cursor_y = 0,
            .scroll_x = 0,
            .scroll_y = 0,
            .line_count = 1,
            .max_lines = max_lines_val,
            .char_width = 8,
            .line_height = 16,
            .read_only = false,
            .word_wrap = true,
            .show_line_numbers = false,
            .max_buffer_size = buffer.len,
        };
    }

    pub fn setText(ta: *TextArea, new_text: []const u8) void {
        if (ta.read_only) return;
        const len = @min(new_text.len, ta.max_buffer_size);
        if (len > 0 and ta.text.len < ta.buffer_capacity) {
            const copy_len = @min(len, ta.buffer_capacity - ta.text.len);
            @memcpy(ta.text[ta.text.len..][0..copy_len], new_text[0..copy_len]);
            ta.text.len += copy_len;
        } else if (len > 0) {
            @memcpy(ta.text[0..len], new_text[0..len]);
            ta.text.len = len;
        } else {
            ta.text.len = 0;
        }
        ta.updateLineCount();
        ta.cursor_x = 0;
        ta.cursor_y = 0;
    }

    pub fn appendText(ta: *TextArea, extra_text: []const u8) void {
        if (ta.read_only) return;
        const remaining = ta.buffer_capacity - ta.text.len;
        const len = @min(extra_text.len, remaining);
        if (len > 0) {
            @memcpy(ta.text[ta.text.len..][0..len], extra_text[0..len]);
            ta.text.len += len;
            ta.updateLineCount();
        }
    }

    pub fn clearText(ta: *TextArea) void {
        if (ta.read_only) return;
        ta.text.len = 0;
        ta.cursor_x = 0;
        ta.cursor_y = 0;
        ta.scroll_x = 0;
        ta.scroll_y = 0;
        ta.line_count = 1;
    }

    pub fn getText(ta: *const TextArea) []const u8 {
        return ta.text[0..ta.text.len];
    }

    pub fn insertChar(ta: *TextArea, ch: u8) void {
        if (ta.read_only) return;
        if (ta.text.len >= ta.buffer_capacity) return;

        // Find insertion position
        const byte_offset = ta.getByteOffset();
        if (byte_offset < ta.text.len) {
            @memmove(ta.text[byte_offset + 1 ..][0..(ta.text.len - byte_offset)], ta.text[byte_offset..][0..(ta.text.len - byte_offset)]);
        }
        ta.text[byte_offset] = ch;
        ta.text.len += 1;
        ta.cursor_x += 1;
        ta.updateLineCount();
    }

    pub fn deleteChar(ta: *TextArea) void {
        if (ta.read_only) return;
        const byte_offset = ta.getByteOffset();
        if (byte_offset >= ta.text.len) return;

        @memmove(ta.text[byte_offset..][0..(ta.text.len - byte_offset - 1)], ta.text[byte_offset + 1 ..][0..(ta.text.len - byte_offset - 1)]);
        ta.text.len -= 1;
        if (ta.cursor_x > 0) ta.cursor_x -= 1;
        ta.updateLineCount();
    }

    pub fn backspace(ta: *TextArea) void {
        if (ta.cursor_x == 0 and ta.cursor_y == 0) return;
        if (ta.cursor_x > 0) {
            ta.cursor_x -= 1;
            ta.deleteChar();
        }
    }

    pub fn moveCursor(ta: *TextArea, new_x: usize, new_y: usize) void {
        ta.cursor_x = new_x;
        ta.cursor_y = @min(new_y, ta.line_count -| 1);
    }

    pub fn scrollBy(ta: *TextArea, _: i32, delta_y: i32) void {
        ta.scroll_x = @max(0, ta.scroll_x);
        ta.scroll_y = @max(0, ta.scroll_y +| @as(i32, @intCast(ta.line_count)) -| ta.max_lines);
        _ = delta_y;
    }

    fn getByteOffset(ta: *const TextArea) usize {
        var offset: usize = 0;
        var line: usize = 0;
        while (line < ta.cursor_y and offset < ta.text.len) : (line += 1) {
            while (offset < ta.text.len and ta.text[offset] != '\n') {
                offset += 1;
            }
            if (offset < ta.text.len and ta.text[offset] == '\n') {
                offset += 1;
            }
        }
        offset += ta.cursor_x;
        return @min(offset, ta.text.len);
    }

    fn getLineOffset(ta: *const TextArea, line: usize) usize {
        var offset: usize = 0;
        var current_line: usize = 0;
        while (current_line < line and offset < ta.text.len) : (current_line += 1) {
            while (offset < ta.text.len and ta.text[offset] != '\n') {
                offset += 1;
            }
            if (offset < ta.text.len and ta.text[offset] == '\n') {
                offset += 1;
            }
        }
        return offset;
    }

    fn updateLineCount(ta: *TextArea) void {
        ta.line_count = 1;
        for (ta.text[0..ta.text.len]) |ch| {
            if (ch == '\n') ta.line_count += 1;
        }
    }

    fn getLineLength(ta: *const TextArea, line: usize) usize {
        const start = ta.getLineOffset(line);
        var end = start;
        while (end < ta.text.len and ta.text[end] != '\n') {
            end += 1;
        }
        return end - start;
    }

    pub fn render(ta: *TextArea, _: *const theme_mod.ThemeColors) void {
        if (!ta.control.visible) return;
        const x = ta.control.x;
        const y = ta.control.y;
        const w = ta.control.width;
        const h = ta.control.height;

        // Background
        fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));

        // Border
        const border_color = if (ta.control.state == .focused) rgb(0x5C, 0x9E, 0xD6) else rgb(0x90, 0x98, 0xA8);
        fb.draw3DRect(x, y, w, h, border_color, rgb(0xFF, 0xFF, 0xFF));

        // Line numbers gutter
        if (ta.show_line_numbers) {
            const gutter_w: i32 = @as(i32, @intCast(@as(usize, @intCast(ta.line_count.toString().len)) * 8 + 8));
            fb.fillRect(x + 1, y + 1, gutter_w, h - 2, rgb(0xF0, 0xF0, 0xF0));
            fb.drawVLine(x + gutter_w, y, h, rgb(0xC0, 0xC8, 0xD0));

            const vis_start = @as(usize, @intCast(@max(0, ta.scroll_y)));
            const vis_end = @min(ta.line_count, vis_start + ta.max_lines);

            var line_num = vis_start;
            var text_y = y + 4 - @as(i32, @intCast(ta.scroll_y)) * ta.line_height;
            while (line_num < vis_end) : (line_num += 1) {
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num + 1}) catch "";
                fb.drawTextTransparent(x + 4, text_y, num_str, rgb(0x80, 0x80, 0x90));
                text_y += ta.line_height;
            }
        }

        // Text content
        const text_area_x = if (ta.show_line_numbers) x + @as(i32, @intCast(@as(usize, @intCast(ta.line_count.toString().len)) * 8 + 8)) + 2 else x + 4;
        const text_area_y = y + 4 - @as(i32, @intCast(ta.scroll_y)) * ta.line_height;

        const vis_start = @as(usize, @intCast(@max(0, ta.scroll_y)));
        const vis_end = @min(ta.line_count, vis_start + ta.max_lines);

        var line_num = vis_start;
        var text_y = text_area_y;
        while (line_num < vis_end) : (line_num += 1) {
            const line_start = ta.getLineOffset(line_num);
            const line_len = ta.getLineLength(line_num);
            if (line_len > 0 and line_start < ta.text.len) {
                const display_len = @min(line_len, @as(usize, @intCast(@divTrunc(w - (text_area_x - x), ta.char_width))));
                if (display_len > 0) {
                    fb.drawTextTransparentClipped (text_area_x, text_y, text_area_x + w, ta.text[line_start..][0..display_len], rgb(0x10, 0x10, 0x18));
                }
            }
            text_y += ta.line_height;
        }

        // Cursor
        if (ta.control.state == .focused) {
            const cursor_screen_x = text_area_x + @as(i32, @intCast(ta.cursor_x)) * ta.char_width - @as(i32, @intCast(ta.scroll_x)) * ta.char_width;
            const cursor_screen_y = text_area_y + @as(i32, @intCast(ta.cursor_y)) * ta.line_height;
            fb.drawVLine(cursor_screen_x, cursor_screen_y, ta.line_height, rgb(0x00, 0x00, 0x00));
        }

        // Scroll indicators
        if (@as(i32, @intCast(ta.line_count)) > ta.max_lines) {
            const scrollbar_x = x + w - 12;
            fb.fillRect(scrollbar_x, y + 2, 10, h - 4, rgb(0xE8, 0xEC, 0xF0));
            fb.draw3DRect(scrollbar_x, y + 2, 10, h - 4, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

            const thumb_h = @as(i32, @intCast(@divTrunc(h, @as(i32, @intCast(ta.line_count)))));
            const thumb_y = y + 2 + @as(i32, @intCast(@divTrunc(@as(i32, @intCast(ta.scroll_y)) * h, @as(i32, @intCast(ta.line_count)))));
            fb.fillRect(scrollbar_x + 1, thumb_y, 8, @max(20, thumb_h), rgb(0xC8, 0xD0, 0xD8));
        }
    }
};

// ============================================================================
// TreeView - Tree Structure Navigation Control
// ============================================================================
pub const TreeNode = struct {
    text: []const u8,
    icon: ?u16,
    expanded: bool,
    selected: bool,
    depth: u32,
    children: []TreeNode,
    child_count: usize,
    data: usize,
    user_data: usize,
};

pub const TreeView = struct {
    control: Control,
    root: TreeNode,
    visible_nodes: []TreeNode,
    node_count: usize,
    selected_node: ?*TreeNode,
    hover_node: ?*TreeNode,
    scroll_y: i32,
    item_height: i32,
    indent_width: i32,
    expand_collapse_area: i32,
    max_nodes: usize,
    show_icons: bool,
    show_lines: bool,
    show_root: bool,
    root_expanded: bool,

    pub fn create(x_pos: i32, y_pos: i32, w: i32, h: i32, max_nodes_val: usize) TreeView {
        return .{
            .control = Control.create(x_pos, y_pos, w, h),
            .root = TreeNode{
                .text = "Root",
                .icon = null,
                .expanded = true,
                .selected = false,
                .depth = 0,
                .children = &[_]TreeNode{},
                .child_count = 0,
                .data = 0,
                .user_data = 0,
            },
            .visible_nodes = &[_]TreeNode{},
            .node_count = 0,
            .selected_node = null,
            .hover_node = null,
            .scroll_y = 0,
            .item_height = 20,
            .indent_width = 20,
            .expand_collapse_area = 16,
            .max_nodes = max_nodes_val,
            .show_icons = true,
            .show_lines = true,
            .show_root = false,
            .root_expanded = true,
        };
    }

    pub fn addNode(tv: *TreeView, parent: ?*TreeNode, text: []const u8, icon: ?u16, user_data: usize) *TreeNode {
        if (tv.node_count >= tv.max_nodes) return null;
        _ = parent;
        // Simplified: add to root for now
        _ = text;
        _ = icon;
        _ = user_data;
        return null;
    }

    pub fn expand(tv: *TreeView, node: *TreeNode) void {
        node.expanded = true;
        tv.rebuildVisibleList();
    }

    pub fn collapse(tv: *TreeView, node: *TreeNode) void {
        node.expanded = false;
        tv.rebuildVisibleList();
    }

    pub fn toggle(tv: *TreeView, node: *TreeNode) void {
        if (node.expanded) {
            tv.collapse(node);
        } else {
            tv.expand(node);
        }
    }

    pub fn select(tv: *TreeView, node: *TreeNode) void {
        if (tv.selected_node) |prev| {
            prev.selected = false;
        }
        node.selected = true;
        tv.selected_node = node;
    }

    pub fn getSelected(tv: *const TreeView) ?*const TreeNode {
        return tv.selected_node;
    }

    pub fn findByData(tv: *const TreeView, data: usize) ?*const TreeNode {
        return tv.findNodeRecursive(&tv.root, data);
    }

    fn findNodeRecursive(tv: *const TreeView, node: *const TreeNode, data: usize) ?*const TreeNode {
        if (node.user_data == data) return node;
        for (node.children[0..node.child_count]) |*child| {
            if (tv.findNodeRecursive(child, data)) |found| return found;
        }
        return null;
    }

    fn rebuildVisibleList(tv: *TreeView) void {
        tv.node_count = 0;
        if (!tv.show_root and !tv.root_expanded) return;
        if (!tv.show_root) {
            for (tv.root.children[0..tv.root.child_count]) |*child| {
                tv.collectVisibleNode(child);
            }
        }
    }

    fn collectVisibleNode(tv: *TreeView, node: *TreeNode) void {
        if (tv.node_count >= tv.max_nodes) return;
        tv.node_count += 1;
        if (node.expanded) {
            for (node.children[0..node.child_count]) |*child| {
                tv.collectVisibleNode(child);
            }
        }
    }

    pub fn getNodeAt(tv: *const TreeView, screen_x: i32, screen_y: i32) ?*TreeNode {
        const ctrl_rect = Rect{ .x = tv.control.x, .y = tv.control.y, .width = tv.control.width, .height = tv.control.height };
        if (!ctrl_rect.contains(screen_x, screen_y)) {
            return null;
        }
        const rel_y = screen_y - tv.control.y + tv.scroll_y;
        const node_index = @divTrunc(rel_y, tv.item_height);
        if (node_index < 0 or @as(usize, @intCast(node_index)) >= tv.node_count) return null;
        return null; // Would need visible_nodes array populated
    }

    pub fn render(tv: *TreeView, t: *const theme_mod.ThemeColors) void {
        if (!tv.control.visible) return;
        const x = tv.control.x;
        const y = tv.control.y;
        const w = tv.control.width;
        const h = tv.control.height;

        // Background
        fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x, y, w, h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        const content_x = x + 2;
        const content_y = y + 2 - tv.scroll_y;

        // Render root only if show_root
        if (tv.show_root) {
            tv.renderNode(&tv.root, content_x, content_y, t);
        } else {
            // Render root's children
            for (tv.root.children[0..tv.root.child_count]) |*child| {
                const node_y = content_y + @as(i32, @intCast(tv.node_count)) * tv.item_height;
                if (node_y >= y and node_y < y + h) {
                    tv.renderNode(child, content_x + tv.indent_width, node_y, t);
                }
                tv.node_count += 1;
            }
        }

        // Vertical scrollbar
        const total_height = @as(i32, @intCast(tv.node_count)) * tv.item_height;
        if (total_height > h) {
            const scrollbar_x = x + w - 14;
            fb.fillRect(scrollbar_x, y + 2, 12, h - 4, rgb(0xF0, 0xF0, 0xF0));
            fb.draw3DRect(scrollbar_x, y + 2, 12, h - 4, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

            const thumb_ratio = @as(f32, @floatFromInt(tv.scroll_y)) / @as(f32, @floatFromInt(total_height - h));
            const thumb_h = @max(20, @divTrunc(@as(i32, @intCast(h)) * h, total_height));
            const thumb_y = y + 2 + @as(i32, @intCast(@as(f32, @floatFromInt(thumb_ratio)) * @as(f32, @floatFromInt(h - thumb_h - 4))));
            fb.fillRect(scrollbar_x + 2, thumb_y, 8, thumb_h, rgb(0xC8, 0xD0, 0xD8));
        }
    }

    fn renderNode(tv: *TreeView, node: *TreeNode, node_x: i32, base_y: i32, _: *const theme_mod.ThemeColors) void {
        const y = tv.control.y;
        const h = tv.control.height;
        const node_y = base_y;

        if (node_y < y or node_y >= y + h) return;

        const is_selected = node.selected;
        const is_hover = tv.hover_node != null and tv.hover_node.? == node;

        if (is_selected) {
            fb.fillRect(tv.control.x + 1, node_y, tv.control.width - 2, tv.item_height, rgb(0xC8, 0xDC, 0xF0));
        } else if (is_hover) {
            fb.fillRect(tv.control.x + 1, node_y, tv.control.width - 2, tv.item_height, rgb(0xE8, 0xF0, 0xF8));
        }

        const text_x = node_x + (node.depth * tv.indent_width) + tv.expand_collapse_area + 4;
        fb.drawTextTransparent(text_x, node_y + 3, node.text, if (is_selected) rgb(0x10, 0x30, 0x70) else rgb(0x10, 0x10, 0x18));

        if (tv.show_lines and node.depth > 0) {
            const line_x = node_x + tv.expand_collapse_area - tv.expand_collapse_area + tv.indent_width / 2;
            fb.drawVLine(line_x, y, h, rgb(0xD0, 0xD8, 0xE0));
        }
    }
};
