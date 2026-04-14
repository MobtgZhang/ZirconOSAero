// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/color_management.zig
// Purpose: Color Management - ICC profile configuration applet
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");
const applet_base = @import("applet_base.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const ColorProfile = struct {
    name: [64]u8,
    name_len: usize,
    profile_type: ProfileType,
    is_default: bool,
};

pub const ProfileType = enum {
    display,
    printer,
    import,
};

pub const ColorManagementState = struct {
    current_profile: [64]u8 = undefined,
    current_profile_len: usize = 0,
    profiles: [16]ColorProfile = undefined,
    profile_count: usize = 0,
    device_associations: [4]DeviceAssoc = undefined,
    device_count: usize = 0,
};

pub const DeviceAssoc = struct {
    device_name: [32]u8,
    device_name_len: usize,
    profile_name: [64]u8,
    profile_name_len: usize,
};

var color_state: ColorManagementState = .{ .current_profile_len = 0, .profile_count = 0, .device_count = 0 };
var hover_add_profile: bool = false;
var hover_remove_profile: bool = false;
var hover_set_default: bool = false;
var selected_profile_index: i32 = -1;

pub fn getState() *ColorManagementState {
    return &color_state;
}

pub fn createWindow(x_pos: i32, y_pos: i32) applet_base.ControlPanelApplet {
    const applet = applet_base.ControlPanelApplet.create(.color_management, x_pos, y_pos, 540, 420);

    // Initialize default profiles
    if (color_state.profile_count == 0) {
        // Default display profile
        const srgb = "sRGB Color Space Profile";
        @memcpy(color_state.profiles[0].name[0..srgb.len], srgb);
        color_state.profiles[0].name_len = srgb.len;
        color_state.profiles[0].profile_type = .display;
        color_state.profiles[0].is_default = true;
        color_state.profile_count = 1;

        const adobe = "Adobe RGB (1998) Color Space";
        @memcpy(color_state.profiles[1].name[0..adobe.len], adobe);
        color_state.profiles[1].name_len = adobe.len;
        color_state.profiles[1].profile_type = .display;
        color_state.profiles[1].is_default = false;
        color_state.profile_count = 2;

        // Set current profile
        @memcpy(color_state.current_profile[0..srgb.len], srgb);
        color_state.current_profile_len = srgb.len;
    }

    return applet;
}

pub fn render(cm: *const applet_base.ControlPanelApplet) void {
    cm.renderCaptionBar("Color Management");

    const cx = cm.x + 8;
    const cy = cm.y + 40;
    const cw = cm.width - 16;
    const ch = cm.height - 48;

    // Background
    fb.fillRect(cx, cy, cw, ch, rgb(0xF0, 0xF4, 0xF8));

    // Device selection section
    const dev_y = cy + 10;
    fb.drawTextTransparent(cx + 10, dev_y, "Device:", rgb(0x20, 0x40, 0x80));

    const dev_drop_y = dev_y + 22;
    fb.fillRect(cx + 10, dev_drop_y, cw - 20, 35, rgb(0xFF, 0xFF, 0xFF));
    fb.draw3DRect(cx + 10, dev_drop_y, cw - 20, 35, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

    // Device selector (dropdown)
    fb.drawTextTransparent(cx + 15, dev_drop_y + 10, "ColorLCD", rgb(0x18, 0x18, 0x20));
    fb.drawTextTransparent(cx + cw - 60, dev_drop_y + 10, "▼", rgb(0x50, 0x50, 0x60));

    // Current profile section
    const profile_y = dev_drop_y + 50;
    fb.drawTextTransparent(cx + 10, profile_y, "Color Profiles:", rgb(0x20, 0x40, 0x80));

    const profile_list_y = profile_y + 25;
    const profile_list_h: i32 = 150;
    fb.fillRect(cx + 10, profile_list_y, cw - 20, profile_list_h, rgb(0xFF, 0xFF, 0xFF));
    fb.draw3DRect(cx + 10, profile_list_y, cw - 20, profile_list_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

    // Profile list
    var py: i32 = profile_list_y + 8;
    for (0..color_state.profile_count) |i| {
        const prof = color_state.profiles[i];
        const is_selected = @as(i32, @intCast(i)) == selected_profile_index;

        // Selection background
        if (is_selected) {
            fb.fillRect(cx + 12, py - 2, cw - 24, 20, rgb(0xD0, 0xE0, 0xF0));
        }

        // Default indicator
        if (prof.is_default) {
            fb.drawTextTransparent(cx + 18, py, "*", rgb(0xC0, 0x00, 0x00));
        }

        // Profile name
        fb.drawTextTransparent(cx + 30, py, prof.name[0..prof.name_len], if (is_selected) rgb(0x00, 0x30, 0x80) else rgb(0x18, 0x18, 0x20));

        // Profile type indicator
        const type_str: []const u8 = switch (prof.profile_type) {
            .display => "[Display]",
            .printer => "[Printer]",
            .import => "[Imported]",
        };
        fb.drawTextTransparent(cx + cw - 100, py, type_str, rgb(0x80, 0x80, 0x80));

        py += 22;

        if (py > profile_list_y + profile_list_h - 25) break;
    }

    // Profile buttons
    const btn_y = profile_list_y + profile_list_h + 10;
    const btn_w: i32 = 110;
    const btn_h: i32 = 28;

    fb.fillRect(cx + 10, btn_y, btn_w, btn_h, if (hover_add_profile) rgb(0x60, 0x90, 0xC0) else rgb(0x40, 0x70, 0xA0));
    fb.draw3DRect(cx + 10, btn_y, btn_w, btn_h, rgb(0x30, 0x60, 0x90), rgb(0x80, 0xB0, 0xE0));
    fb.drawTextTransparent(cx + 30, btn_y + 7, "Add...", rgb(0xFF, 0xFF, 0xFF));

    fb.fillRect(cx + 130, btn_y, btn_w, btn_h, if (hover_remove_profile) rgb(0xC0, 0x60, 0x60) else rgb(0xA0, 0x40, 0x40));
    fb.draw3DRect(cx + 130, btn_y, btn_w, btn_h, rgb(0x80, 0x30, 0x30), rgb(0xE0, 0x80, 0x80));
    fb.drawTextTransparent(cx + 145, btn_y + 7, "Remove", rgb(0xFF, 0xFF, 0xFF));

    fb.fillRect(cx + 250, btn_y, btn_w, btn_h, if (hover_set_default) rgb(0x60, 0x90, 0xC0) else rgb(0x40, 0x70, 0xA0));
    fb.draw3DRect(cx + 250, btn_y, btn_w, btn_h, rgb(0x30, 0x60, 0x90), rgb(0x80, 0xB0, 0xE0));
    fb.drawTextTransparent(cx + 265, btn_y + 7, "Set as Default", rgb(0xFF, 0xFF, 0xFF));

    // Advanced section
    const adv_y = btn_y + 45;
    fb.drawTextTransparent(cx + 10, adv_y, "Advanced Settings:", rgb(0x20, 0x40, 0x80));

    const adv_box_y = adv_y + 25;
    fb.fillRect(cx + 10, adv_box_y, cw - 20, 60, rgb(0xF8, 0xFA, 0xFC));
    fb.draw3DRect(cx + 10, adv_box_y, cw - 20, 60, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

    fb.drawTextTransparent(cx + 20, adv_box_y + 8, "Use Windows display calibration", rgb(0x50, 0x50, 0x60));
    fb.drawTextTransparent(cx + 20, adv_box_y + 28, "(Recommended for most users)", rgb(0x80, 0x80, 0x80));

    // Info text
    const info_y = adv_box_y + 75;
    fb.fillRect(cx + 10, info_y, cw - 20, 45, rgb(0xF0, 0xF8, 0xFF));
    fb.draw3DRect(cx + 10, info_y, cw - 20, 45, rgb(0xA0, 0xC0, 0xE0), rgb(0xFF, 0xFF, 0xFF));
    fb.drawTextTransparent(cx + 20, info_y + 10, "Note: This is a simplified color management interface.", rgb(0x40, 0x60, 0x80));
    fb.drawTextTransparent(cx + 20, info_y + 26, "Full ICC profile management requires additional system support.", rgb(0x40, 0x60, 0x80));
}

pub fn handleClick(cm: *const applet_base.ControlPanelApplet, px: i32, py: i32) void {
    const cx = cm.x + 8;
    const cw = cm.width - 16;

    // Device dropdown
    const dev_drop_y = cm.y + 72;
    if (px >= cx + 10 and px < cx + cw - 10 and
        py >= dev_drop_y and py < dev_drop_y + 35)
    {
        // Would show device selection dialog
        return;
    }

    // Profile list area
    const profile_list_y = cm.y + 120;
    const profile_list_h: i32 = 150;

    if (py >= profile_list_y and py < profile_list_y + profile_list_h) {
        // Calculate clicked profile index
        const item_index = @divTrunc(py - profile_list_y - 6, 22);
        if (item_index >= 0 and @as(usize, @intCast(item_index)) < color_state.profile_count) {
            selected_profile_index = item_index;
        }
        return;
    }

    // Button area
    const btn_y = profile_list_y + profile_list_h + 10;
    const btn_w: i32 = 110;
    const btn_h: i32 = 28;

    // Add button
    if (px >= cx + 10 and px < cx + 10 + btn_w and
        py >= btn_y and py < btn_y + btn_h)
    {
        // Would show add profile dialog
        return;
    }

    // Remove button
    if (px >= cx + 130 and px < cx + 130 + btn_w and
        py >= btn_y and py < btn_y + btn_h)
    {
        if (selected_profile_index >= 0) {
            const idx = @as(usize, @intCast(selected_profile_index));
            if (idx < color_state.profile_count) {
                // Shift remaining profiles down
                var i = idx;
                while (i < color_state.profile_count - 1) : (i += 1) {
                    color_state.profiles[i] = color_state.profiles[i + 1];
                }
                color_state.profile_count -= 1;
                selected_profile_index = -1;
            }
        }
        return;
    }

    // Set as Default button
    if (px >= cx + 250 and px < cx + 250 + btn_w and
        py >= btn_y and py < btn_y + btn_h)
    {
        if (selected_profile_index >= 0) {
            const idx = @as(usize, @intCast(selected_profile_index));
            if (idx < color_state.profile_count) {
                // Clear all defaults
                for (0..color_state.profile_count) |i| {
                    color_state.profiles[i].is_default = false;
                }
                // Set selected as default
                color_state.profiles[idx].is_default = true;
            }
        }
        return;
    }
}

pub fn handleMouseMove(cm: *const applet_base.ControlPanelApplet, px: i32, py: i32) void {
    const profile_list_y = cm.y + 120;
    const profile_list_h: i32 = 150;
    const btn_y = profile_list_y + profile_list_h + 10;

    hover_add_profile = (px >= cm.x + 18 and px < cm.x + 128 and
        py >= btn_y and py < btn_y + 28);

    hover_remove_profile = (px >= cm.x + 138 and px < cm.x + 248 and
        py >= btn_y and py < btn_y + 28);

    hover_set_default = (px >= cm.x + 258 and px < cm.x + 368 and
        py >= btn_y and py < btn_y + 28);
}
