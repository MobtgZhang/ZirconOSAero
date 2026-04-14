// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/indexing_options.zig
// Purpose: Indexing Options - Windows Search configuration applet
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");
const applet_base = @import("applet_base.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const IndexingState = struct {
    index_enabled: bool = true,
    indexed_locations: [8][128]u8 = undefined,
    indexed_count: usize = 0,
    file_types: [32]FileTypeEntry = undefined,
    file_type_count: usize = 0,
};

pub const FileTypeEntry = struct {
    extension: [8]u8,
    extension_len: usize,
    indexed: bool,
    summarized: bool,
};

var index_state: IndexingState = .{ .indexed_count = 0, .file_type_count = 0 };
var hover_include: bool = false;
var hover_exclude: bool = false;
var hover_modify: bool = false;
var show_location_dialog: bool = false;
var show_type_dialog: bool = false;

pub fn getState() *IndexingState {
    return &index_state;
}

pub fn createWindow(x_pos: i32, y_pos: i32) applet_base.ControlPanelApplet {
    const applet = applet_base.ControlPanelApplet.create(.indexing_options, x_pos, y_pos, 540, 460);

    // Initialize default indexed locations
    if (index_state.indexed_count == 0) {
        const loc1 = "C:\\Users";
        @memcpy(index_state.indexed_locations[0][0..loc1.len], loc1);
        index_state.indexed_locations[0][loc1.len] = 0;
        index_state.indexed_count = 1;
    }

    // Initialize default file types
    if (index_state.file_type_count == 0) {
        const types = [_][]const u8{ ".txt", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pdf", ".zip", ".rar" };
        for (types, 0..) |ext, i| {
            @memcpy(index_state.file_types[i].extension[0..ext.len], ext);
            index_state.file_types[i].extension_len = ext.len;
            index_state.file_types[i].indexed = true;
            index_state.file_types[i].summarized = false;
            index_state.file_type_count = i + 1;
        }
    }

    return applet;
}

pub fn render(idx: *const applet_base.ControlPanelApplet) void {
    idx.renderCaptionBar("Indexing Options");

    const cx = idx.x + 8;
    const cy = idx.y + 40;
    const cw = idx.width - 16;
    const ch = idx.height - 48;

    // Background
    fb.fillRect(cx, cy, cw, ch, rgb(0xF0, 0xF4, 0xF8));

    if (show_location_dialog) {
        renderLocationDialog(cx, cy, cw, ch);
        return;
    }

    if (show_type_dialog) {
        renderTypeDialog(cx, cy, cw, ch);
        return;
    }

    // Title
    fb.drawTextTransparent(cx + 10, cy + 10, "Windows Search Indexing", rgb(0x18, 0x18, 0x20));

    // Index status
    const status_y = cy + 40;
    const status_h: i32 = 70;
    fb.fillRect(cx + 10, status_y, cw - 20, status_h, rgb(0xF8, 0xFC, 0xF0));
    fb.draw3DRect(cx + 10, status_y, cw - 20, status_h, rgb(0xC0, 0xD0, 0xB0), rgb(0xFF, 0xFF, 0xFF));

    if (index_state.index_enabled) {
        fb.fillEllipse(cx + 40, status_y + 35, 12, 12, rgb(0x00, 0xA0, 0x00));
        fb.drawTextTransparent(cx + 60, status_y + 25, "Indexing is enabled", rgb(0x00, 0x60, 0x00));

        var buf: [64]u8 = undefined;
        const count = std.fmt.bufPrint(&buf, "{d} items indexed", .{index_state.indexed_count * 100}) catch "items indexed";
        fb.drawTextTransparent(cx + 60, status_y + 45, count, rgb(0x50, 0x60, 0x50));
    } else {
        fb.fillEllipse(cx + 40, status_y + 35, 12, 12, rgb(0xC0, 0x40, 0x40));
        fb.drawTextTransparent(cx + 60, status_y + 25, "Indexing is disabled", rgb(0x80, 0x00, 0x00));
        fb.drawTextTransparent(cx + 60, status_y + 45, "Search results may be incomplete", rgb(0x60, 0x40, 0x40));
    }

    // Modify button
    const mod_btn_x = cx + cw - 110;
    const mod_btn_y = status_y + 20;
    const mod_btn_w: i32 = 90;
    const mod_btn_h: i32 = 28;
    const mod_btn_bg = if (hover_modify) rgb(0x60, 0x90, 0xC0) else rgb(0x40, 0x70, 0xA0);
    fb.fillRect(mod_btn_x, mod_btn_y, mod_btn_w, mod_btn_h, mod_btn_bg);
    fb.draw3DRect(mod_btn_x, mod_btn_y, mod_btn_w, mod_btn_h, rgb(0x30, 0x60, 0x90), rgb(0x80, 0xB0, 0xE0));
    fb.drawTextTransparent(mod_btn_x + 25, mod_btn_y + 7, "Modify", rgb(0xFF, 0xFF, 0xFF));

    // Indexed locations section
    const loc_y = status_y + status_h + 15;
    fb.drawTextTransparent(cx + 10, loc_y, "Indexed Locations:", rgb(0x20, 0x40, 0x80));

    const loc_list_y = loc_y + 25;
    const loc_list_h: i32 = 120;
    fb.fillRect(cx + 10, loc_list_y, cw - 20, loc_list_h, rgb(0xFF, 0xFF, 0xFF));
    fb.draw3DRect(cx + 10, loc_list_y, cw - 20, loc_list_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

    // Draw indexed locations
    var iy: i32 = loc_list_y + 8;
    for (0..index_state.indexed_count) |i| {
        const loc = index_state.indexed_locations[i];
        var len: usize = 0;
        while (len < loc.len and loc[len] != 0) : (len += 1) {}

        fb.drawTextTransparent(cx + 20, iy, "[+] ", rgb(0x00, 0x80, 0x00));
        fb.drawTextTransparent(cx + 45, iy, loc[0..len], rgb(0x18, 0x18, 0x20));
        iy += 18;

        if (iy > loc_list_y + loc_list_h - 20) break;
    }

    // Include/Exclude buttons
    const inc_btn_y = loc_list_y + loc_list_h + 10;
    const inc_btn_w: i32 = 140;
    const inc_btn_h: i32 = 28;

    fb.fillRect(cx + 10, inc_btn_y, inc_btn_w, inc_btn_h, if (hover_include) rgb(0x60, 0x90, 0xC0) else rgb(0x40, 0x70, 0xA0));
    fb.draw3DRect(cx + 10, inc_btn_y, inc_btn_w, inc_btn_h, rgb(0x30, 0x60, 0x90), rgb(0x80, 0xB0, 0xE0));
    fb.drawTextTransparent(cx + 35, inc_btn_y + 7, "Include a location", rgb(0xFF, 0xFF, 0xFF));

    fb.fillRect(cx + 160, inc_btn_y, inc_btn_w, inc_btn_h, if (hover_exclude) rgb(0xC0, 0x60, 0x60) else rgb(0xA0, 0x40, 0x40));
    fb.draw3DRect(cx + 160, inc_btn_y, inc_btn_w, inc_btn_h, rgb(0x80, 0x30, 0x30), rgb(0xE0, 0x80, 0x80));
    fb.drawTextTransparent(cx + 180, inc_btn_y + 7, "Exclude a location", rgb(0xFF, 0xFF, 0xFF));

    // File Types section
    const types_y = inc_btn_y + inc_btn_h + 15;
    fb.drawTextTransparent(cx + 10, types_y, "File Types to Index:", rgb(0x20, 0x40, 0x80));

    const types_list_y = types_y + 25;
    const types_list_h: i32 = 80;
    fb.fillRect(cx + 10, types_list_y, cw - 20, types_list_h, rgb(0xFF, 0xFF, 0xFF));
    fb.draw3DRect(cx + 10, types_list_y, cw - 20, types_list_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

    fb.drawTextTransparent(cx + 20, types_list_y + 8, "Currently indexing file types: ", rgb(0x50, 0x50, 0x60));
    var types_buf: [256]u8 = undefined;
    var types_len: usize = 0;
    for (0..@min(index_state.file_type_count, 10)) |i| {
        const ext = index_state.file_types[i].extension[0..index_state.file_type_count];
        if (types_len + ext.len + 2 < types_buf.len) {
            if (types_len > 0) {
                types_buf[types_len] = ',';
                types_len += 1;
            }
            @memcpy(types_buf[types_len..][0..ext.len], ext);
            types_len += ext.len;
        }
    }
    fb.drawTextTransparent(cx + 20, types_list_y + 28, types_buf[0..types_len], rgb(0x30, 0x30, 0x40));

    if (index_state.file_type_count > 10) {
        var more_buf: [32]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "and {d} more...", .{index_state.file_type_count - 10}) catch "";
        fb.drawTextTransparent(cx + 20, types_list_y + 48, more, rgb(0x60, 0x60, 0x70));
    }
}

fn renderLocationDialog(cx: i32, cy: i32, cw: i32, ch: i32) void {
    fb.drawTextTransparent(cx + 10, cy + 10, "Select locations to index:", rgb(0x20, 0x40, 0x80));

    // Drive selection
    const drive_y = cy + 45;
    const drive_h: i32 = 200;
    fb.fillRect(cx + 10, drive_y, cw - 20, drive_h, rgb(0xFF, 0xFF, 0xFF));
    fb.draw3DRect(cx + 10, drive_y, cw - 20, drive_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

    // Drive checkboxes
    const drives = [_]struct { letter: u8, label: []const u8 }{
        .{ .letter = 'C', .label = "Local Disk (C:)" },
        .{ .letter = 'D', .label = "Local Disk (D:)" },
        .{ .letter = 'E', .label = "Removable (E:)" },
    };

    var dy: i32 = drive_y + 15;
    for (drives) |drive| {
        const is_indexed = isLocationIndexed(drive.letter);

        // Checkbox
        const cb_bg = if (is_indexed) rgb(0x00, 0x80, 0x00) else rgb(0xFF, 0xFF, 0xFF);
        fb.fillRect(cx + 20, dy, 14, 14, cb_bg);
        fb.drawRect(cx + 20, dy, 14, 14, rgb(0x80, 0x80, 0x80));

        if (is_indexed) {
            fb.drawTextTransparent(cx + 23, dy + 2, "X", rgb(0xFF, 0xFF, 0xFF));
        }

        fb.drawTextTransparent(cx + 45, dy + 1, drive.label, rgb(0x18, 0x18, 0x20));

        dy += 28;
    }

    // Buttons
    const btn_y = cy + ch - 45;
    const btn_w: i32 = 80;
    const btn_h: i32 = 28;

    fb.fillRect(cx + cw - btn_w - 10, btn_y, btn_w, btn_h, rgb(0x40, 0x70, 0xA0));
    fb.draw3DRect(cx + cw - btn_w - 10, btn_y, btn_w, btn_h, rgb(0x30, 0x50, 0x80), rgb(0x60, 0x90, 0xC0));
    fb.drawTextTransparent(cx + cw - btn_w + 20, btn_y + 7, "OK", rgb(0xFF, 0xFF, 0xFF));

    fb.fillRect(cx + cw - 2 * btn_w - 20, btn_y, btn_w, btn_h, rgb(0xE0, 0xE0, 0xE0));
    fb.draw3DRect(cx + cw - 2 * btn_w - 20, btn_y, btn_w, btn_h, rgb(0xB0, 0xB0, 0xB0), rgb(0xFF, 0xFF, 0xFF));
    fb.drawTextTransparent(cx + cw - 2 * btn_w - 5, btn_y + 7, "Cancel", rgb(0x40, 0x40, 0x50));
}

fn renderTypeDialog(cx: i32, cy: i32, cw: i32, ch: i32) void {
    fb.drawTextTransparent(cx + 10, cy + 10, "Select file types to index:", rgb(0x20, 0x40, 0x80));
    fb.drawTextTransparent(cx + 10, cy + 30, "Search behaviors:", rgb(0x50, 0x50, 0x60));

    // Behavior options
    const beh_y = cy + 55;
    fb.fillRect(cx + 10, beh_y, cw - 20, 35, rgb(0xF8, 0xFC, 0xF8));
    fb.draw3DRect(cx + 10, beh_y, cw - 20, 35, rgb(0xC0, 0xD0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
    fb.drawTextTransparent(cx + 20, beh_y + 10, "Index Properties and File Contents (slow)", rgb(0x18, 0x18, 0x20));

    fb.fillRect(cx + 10, beh_y + 45, cw - 20, 35, rgb(0xFF, 0xFF, 0xFF));
    fb.draw3DRect(cx + 10, beh_y + 45, cw - 20, 35, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
    fb.drawTextTransparent(cx + 20, beh_y + 55, "Index Properties Only (fast)", rgb(0x18, 0x18, 0x20));

    // File types list
    const list_y = beh_y + 100;
    const list_h: i32 = 180;
    fb.fillRect(cx + 10, list_y, cw - 20, list_h, rgb(0xFF, 0xFF, 0xFF));
    fb.draw3DRect(cx + 10, list_y, cw - 20, list_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

    var ly: i32 = list_y + 10;
    for (0..@min(index_state.file_type_count, 8)) |i| {
        const ext = index_state.file_types[i].extension[0..index_state.file_types[i].extension_len];

        // Checkbox
        const cb_bg = if (index_state.file_types[i].indexed) rgb(0x00, 0x80, 0x00) else rgb(0xFF, 0xFF, 0xFF);
        fb.fillRect(cx + 20, ly, 14, 14, cb_bg);
        fb.drawRect(cx + 20, ly, 14, 14, rgb(0x80, 0x80, 0x80));

        if (index_state.file_types[i].indexed) {
            fb.drawTextTransparent(cx + 23, ly + 2, "X", rgb(0xFF, 0xFF, 0xFF));
        }

        fb.drawTextTransparent(cx + 45, ly + 1, ext, rgb(0x18, 0x18, 0x20));
        ly += 20;
    }

    // Buttons
    const btn_y = cy + ch - 45;
    const btn_w: i32 = 80;
    const btn_h: i32 = 28;

    fb.fillRect(cx + cw - btn_w - 10, btn_y, btn_w, btn_h, rgb(0x40, 0x70, 0xA0));
    fb.draw3DRect(cx + cw - btn_w - 10, btn_y, btn_w, btn_h, rgb(0x30, 0x50, 0x80), rgb(0x60, 0x90, 0xC0));
    fb.drawTextTransparent(cx + cw - btn_w + 20, btn_y + 7, "OK", rgb(0xFF, 0xFF, 0xFF));

    fb.fillRect(cx + cw - 2 * btn_w - 20, btn_y, btn_w, btn_h, rgb(0xE0, 0xE0, 0xE0));
    fb.draw3DRect(cx + cw - 2 * btn_w - 20, btn_y, btn_w, btn_h, rgb(0xB0, 0xB0, 0xB0), rgb(0xFF, 0xFF, 0xFF));
    fb.drawTextTransparent(cx + cw - 2 * btn_w - 5, btn_y + 7, "Cancel", rgb(0x40, 0x40, 0x50));
}

fn isLocationIndexed(letter: u8) bool {
    for (0..index_state.indexed_count) |i| {
        const loc = index_state.indexed_locations[i];
        if (loc[0] == letter and loc[1] == ':') {
            return true;
        }
    }
    return false;
}

pub fn handleClick(idx: *const applet_base.ControlPanelApplet, px: i32, py: i32) void {
    const cx = idx.x + 8;
    const cy = idx.y + 40;
    const cw = idx.width - 16;
    const ch = idx.height - 48;

    if (show_location_dialog) {
        const btn_y = cy + ch - 45;
        const btn_w: i32 = 80;

        // OK button
        if (px >= cx + cw - btn_w - 10 and px < cx + cw - 10 and
            py >= btn_y and py < btn_y + 28)
        {
            show_location_dialog = false;
            return;
        }

        // Cancel button
        if (px >= cx + cw - 2 * btn_w - 20 and px < cx + cw - btn_w - 20 and
            py >= btn_y and py < btn_y + 28)
        {
            show_location_dialog = false;
            return;
        }
        return;
    }

    if (show_type_dialog) {
        const btn_y = cy + ch - 45;
        const btn_w: i32 = 80;

        // OK button
        if (px >= cx + cw - btn_w - 10 and px < cx + cw - 10 and
            py >= btn_y and py < btn_y + 28)
        {
            show_type_dialog = false;
            return;
        }

        // Cancel button
        if (px >= cx + cw - 2 * btn_w - 20 and px < cx + cw - btn_w - 20 and
            py >= btn_y and py < btn_y + 28)
        {
            show_type_dialog = false;
            return;
        }
        return;
    }

    // Modify button
    const mod_btn_x = cx + cw - 110;
    const mod_btn_y = cy + 60;
    if (px >= mod_btn_x and px < mod_btn_x + 90 and py >= mod_btn_y and py < mod_btn_y + 28) {
        show_location_dialog = true;
        return;
    }

    // Include location button
    const inc_btn_y = cy + 195;
    if (px >= cx + 10 and px < cx + 150 and py >= inc_btn_y and py < inc_btn_y + 28) {
        show_location_dialog = true;
        return;
    }

    // Exclude location button
    if (px >= cx + 160 and px < cx + 300 and py >= inc_btn_y and py < inc_btn_y + 28) {
        show_location_dialog = true;
        return;
    }
}

pub fn handleMouseMove(idx: *const applet_base.ControlPanelApplet, px: i32, py: i32) void {
    if (show_location_dialog or show_type_dialog) {
        hover_include = false;
        hover_exclude = false;
        hover_modify = false;
        return;
    }

    const cx = idx.x + 8;
    const cw = idx.width - 16;

    hover_modify = (px >= cx + cw - 110 and px < cx + cw - 20 and py >= idx.y + 60 and py < idx.y + 88);

    const inc_btn_y = idx.y + 195;
    hover_include = (px >= cx + 10 and px < cx + 150 and py >= inc_btn_y and py < inc_btn_y + 28);
    hover_exclude = (px >= cx + 160 and px < cx + 300 and py >= inc_btn_y and py < inc_btn_y + 28);
}
