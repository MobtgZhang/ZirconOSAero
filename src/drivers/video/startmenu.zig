//! Windows 7 Aero 开始菜单（NT 6.1）

const std = @import("std");
const fb = @import("framebuffer.zig");
const icons = @import("icons.zig");
const klog = @import("../../rtl/klog.zig");
const dwm = @import("dwm.zig");

fn drawMenuIcon(id: icons.IconId, x: i32, y: i32, scale: u32) void {
    icons.drawThemedIcon(id, x, y, scale, .aero);
}

fn rgb(r: u32, g: u32, b: u32) u32 {
    return b | (g << 8) | (r << 16);
}

pub const MenuStyle = enum(u8) {
    aero = 0,
};

pub const MenuItem = struct {
    label: []const u8,
    icon_id: ?icons.IconId = null,
    separator_after: bool = false,
    bold: bool = false,
};

const aero7_left = [_]MenuItem{
    .{ .label = "Internet Explorer", .icon_id = .browser, .bold = true },
    .{ .label = "Windows Media Player", .icon_id = .documents, .separator_after = true },
    .{ .label = "Terminal", .icon_id = .computer },
    .{ .label = "Notepad", .icon_id = .documents },
    .{ .label = "Calculator", .icon_id = .computer },
    .{ .label = "Paint", .icon_id = .documents },
};
const aero7_right = [_]MenuItem{
    .{ .label = "Documents", .icon_id = .documents, .bold = true },
    .{ .label = "Pictures", .icon_id = .documents, .bold = true },
    .{ .label = "Music", .icon_id = .documents, .bold = true },
    .{ .label = "Games", .icon_id = .computer, .separator_after = true },
    .{ .label = "Computer", .icon_id = .computer, .bold = true },
    .{ .label = "Network", .icon_id = .network },
    .{ .label = "Control Panel", .icon_id = .computer },
    .{ .label = "Devices and Printers", .icon_id = .computer },
    .{ .label = "Help and Support", .icon_id = .documents, .separator_after = true },
    .{ .label = "Run...", .icon_id = .computer },
};

const AERO7_HEADER_H: i32 = 52;
const AERO7_LEFT_W: i32 = 200;
const AERO7_ROW_H: i32 = 24;
const AERO7_SEARCH_H: i32 = 46;
const AERO7_FOOTER_H: i32 = 44;
const AERO7_RAIL_W: i32 = 52;
const AERO7_IDX_ALL: i32 = 48;

pub const MenuAction = enum {
    none,
    shutdown,
    restart,
    standby,
    logoff,
};

var menu_visible: bool = false;
var hover_index: i32 = -1;

pub fn isVisible() bool {
    return menu_visible;
}

pub fn show(_: MenuStyle) void {
    menu_visible = true;
    hover_index = -1;
}

pub fn hide() void {
    menu_visible = false;
    hover_index = -1;
}

pub fn toggle(_: MenuStyle) void {
    if (menu_visible) hide() else show(.aero);
}

pub fn setHoverIndex(idx: i32) void {
    hover_index = idx;
}

fn aeroRect(scr_h: i32) MenuRect {
    const h: i32 = AERO7_HEADER_H + 310 + AERO7_SEARCH_H + AERO7_FOOTER_H + AERO7_RAIL_W + 12;
    const w: i32 = 428;
    return .{ .x = 0, .y = scr_h - 40 - h, .w = w, .h = h };
}

pub fn getMenuRect(scr_w: i32, scr_h: i32) MenuRect {
    _ = scr_w;
    return aeroRect(scr_h);
}

pub const MenuRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: MenuRect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }
};

pub fn updatePointerHover(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    if (!menu_visible) return false;
    const prev = hover_index;
    hover_index = aero7HoverIndex(px, py, scr_w, scr_h);
    return prev != hover_index;
}

fn aero7HoverIndex(px: i32, py: i32, scr_w: i32, scr_h: i32) i32 {
    _ = scr_w;
    const r = aeroRect(scr_h);
    if (!r.contains(px, py)) return -1;

    const inner_x = r.x + 4;
    const inner_y = r.y + 4;
    const inner_w = r.w - 8;
    const inner_h = r.h - 8;
    const rail = AERO7_RAIL_W;
    const main_x = inner_x + rail;
    const main_w = inner_w - rail;

    const content_y = inner_y + AERO7_HEADER_H + 2;
    const mid_h = inner_h - AERO7_HEADER_H - AERO7_SEARCH_H - AERO7_FOOTER_H - 6;
    const search_y = inner_y + inner_h - AERO7_SEARCH_H - AERO7_FOOTER_H;
    const foot_y = inner_y + inner_h - AERO7_FOOTER_H;
    const split_x = main_x + AERO7_LEFT_W;
    const all_prog_y = content_y + mid_h - AERO7_ROW_H - 6;

    if (py >= foot_y and py < inner_y + inner_h) {
        if (py >= foot_y + 6 and py < foot_y + 34) {
            const sd_x = main_x + main_w - 116;
            if (px >= main_x + 8 and px < main_x + 90) return 200;
            if (px >= main_x + 92 and px < main_x + 152) return 202;
            if (px >= main_x + 156 and px < sd_x - 8) return 203;
            if (px >= sd_x and px < main_x + main_w - 8) return 201;
        }
        return -1;
    }
    if (py >= search_y) return -1;

    if (py >= all_prog_y and py < all_prog_y + AERO7_ROW_H and px >= main_x + 8 and px < split_x)
        return AERO7_IDX_ALL;

    if (px >= main_x + 8 and px < split_x and py >= content_y + 6 and py < all_prog_y) {
        const row = @divTrunc(py - (content_y + 6), AERO7_ROW_H);
        if (row >= 0 and row < aero7_left.len) return row;
    }

    if (px >= split_x + 6 and px < main_x + main_w - 8 and py >= content_y + 6 and py < search_y - 4) {
        var iy: i32 = content_y + 6;
        var ridx: i32 = 100;
        for (aero7_right) |item| {
            if (py >= iy and py < iy + AERO7_ROW_H) return ridx;
            iy += AERO7_ROW_H;
            if (item.separator_after) iy += 4;
            ridx += 1;
        }
    }
    return -1;
}

fn handleAero7MenuClick(px: i32, py: i32, scr_w: i32, scr_h: i32) MenuAction {
    const h = aero7HoverIndex(px, py, scr_w, scr_h);
    if (h == 201) return .shutdown;
    if (h == 203) return .restart;
    if (h == 202) return .standby;
    if (h == 200) return .logoff;
    if (h >= 0 and h < aero7_left.len) {
        klog.info("Start menu (Aero): %s", .{aero7_left[@intCast(h)].label});
        return .none;
    }
    if (h == AERO7_IDX_ALL) {
        klog.info("Start menu (Aero): All Programs", .{});
        return .none;
    }
    if (h >= 100) {
        const idx: usize = @intCast(h - 100);
        if (idx < aero7_right.len) {
            klog.info("Start menu (Aero): %s", .{aero7_right[idx].label});
        }
    }
    return .none;
}

pub fn handleMenuClick(px: i32, py: i32, scr_w: i32, scr_h: i32) MenuAction {
    if (!menu_visible) return .none;
    const r = getMenuRect(scr_w, scr_h);
    if (!r.contains(px, py)) return .none;
    return handleAero7MenuClick(px, py, scr_w, scr_h);
}

pub fn render(scr_w: i32, scr_h: i32) void {
    if (!menu_visible or !fb.isInitialized()) return;
    _ = scr_w;
    const r = aeroRect(scr_h);
    const text_dark = rgb(0x18, 0x1C, 0x22);
    const text_dim = rgb(0x50, 0x58, 0x62);
    const text_white = rgb(0xFF, 0xFF, 0xFF);
    const sep = rgb(0xB8, 0xC4, 0xD4);
    const rail_bg = rgb(0x10, 0x1C, 0x30);

    fb.blendTintRect(r.x + 5, r.y + 5, r.w, r.h, rgb(0x00, 0x00, 0x00), 35, 255);
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(r.x + 2, r.y + 2, r.w - 4, r.h - 4, rgb(0x28, 0x40, 0x60), .panel);
    } else {
        fb.fillRoundedRect(r.x + 2, r.y + 2, r.w - 4, r.h - 4, 6, rgb(0xE8, 0xEE, 0xF6));
        fb.blendTintRect(r.x + 2, r.y + 2, r.w - 4, r.h - 4, rgb(0x88, 0xA8, 0xC8), 22, 200);
    }
    fb.draw3DRect(r.x, r.y, r.w, r.h, rgb(0xF5, 0xFA, 0xFF), rgb(0x40, 0x58, 0x70));
    fb.draw3DRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2, rgb(0xC8, 0xD8, 0xE8), rgb(0x30, 0x40, 0x55));

    const inner_x = r.x + 4;
    const inner_y = r.y + 4;
    const inner_w = r.w - 8;
    const inner_h = r.h - 8;
    const rail = AERO7_RAIL_W;
    const main_x = inner_x + rail;
    const main_w = inner_w - rail;

    fb.fillRect(inner_x, inner_y, rail, inner_h, rail_bg);
    fb.drawGradientV(inner_x, inner_y, rail, @divTrunc(inner_h, 2), rgb(0x18, 0x28, 0x40), rail_bg);
    fb.drawVLine(main_x - 1, inner_y, inner_h, rgb(0x30, 0x44, 0x5C));
    const orb_y = inner_y + inner_h - rail - 6;
    fb.fillRoundedRect(inner_x + 8, orb_y, 36, 36, 18, rgb(0x28, 0x48, 0x78));
    fb.drawGradientV(inner_x + 9, orb_y + 1, 34, 17, rgb(0x50, 0x78, 0xA8), rgb(0x28, 0x48, 0x78));
    fb.drawTextTransparentUi(inner_x + 18, orb_y + 11, "Z", rgb(0xE8, 0xF0, 0xFF));

    const hdr_h = AERO7_HEADER_H;
    fb.drawGradientH(main_x, inner_y, main_w, hdr_h, rgb(0x68, 0x78, 0x88), rgb(0x90, 0xA0, 0xB0));
    fb.blendTintRect(main_x, inner_y, main_w, hdr_h, rgb(0xE8, 0xF0, 0xF8), 45, 220);
    fb.addSpecularBand(main_x, inner_y, main_w, @divTrunc(hdr_h, 3), 22);
    fb.drawHLine(main_x + 2, inner_y + 2, main_w - 4, rgb(0xF8, 0xFC, 0xFF));

    fb.fillRoundedRect(main_x + 8, inner_y + 8, 40, 40, 5, rgb(0xA8, 0xB8, 0xC8));
    fb.blendTintRect(main_x + 8, inner_y + 8, 40, 40, rgb(0xFF, 0xFF, 0xFF), 35, 255);
    fb.drawRect(main_x + 8, inner_y + 8, 40, 40, rgb(0xD8, 0xE4, 0xF0));
    drawMenuIcon(.computer, main_x + 12, inner_y + 12, 2);
    fb.drawTextTransparentUi(main_x + 54, inner_y + 12, "ZirconOS User", text_white);
    fb.drawTextTransparentUi(main_x + 54, inner_y + 30, "Windows 7 · Aero Glass", rgb(0xE8, 0xF0, 0xF8));

    const content_y = inner_y + hdr_h + 2;
    const mid_h = inner_h - AERO7_HEADER_H - AERO7_SEARCH_H - AERO7_FOOTER_H - 6;
    const search_y = inner_y + inner_h - AERO7_SEARCH_H - AERO7_FOOTER_H;
    const foot_y = inner_y + inner_h - AERO7_FOOTER_H;
    const split_x = main_x + AERO7_LEFT_W;
    const all_prog_y = content_y + mid_h - AERO7_ROW_H - 6;

    fb.fillRect(main_x, content_y, AERO7_LEFT_W, mid_h, rgb(0xFA, 0xFC, 0xFE));
    fb.blendTintRect(main_x, content_y, AERO7_LEFT_W, mid_h, rgb(0xF0, 0xF6, 0xFC), 30, 255);
    fb.fillRect(split_x, content_y, main_w - AERO7_LEFT_W, mid_h, rgb(0xE4, 0xEC, 0xF4));
    fb.blendTintRect(split_x, content_y, main_w - AERO7_LEFT_W, mid_h, rgb(0xC8, 0xD8, 0xE8), 18, 200);
    fb.drawVLine(split_x, content_y, mid_h, sep);

    var iy: i32 = content_y + 6;
    for (aero7_left, 0..) |item, li| {
        if (iy + AERO7_ROW_H > all_prog_y - 2) break;
        const row_r = hover_index == @as(i32, @intCast(li));
        if (row_r) {
            fb.blendTintRect(main_x + 6, iy - 1, AERO7_LEFT_W - 12, AERO7_ROW_H, rgb(0x70, 0x98, 0xC8), 55, 255);
            if (item.icon_id) |iid| {
                drawMenuIcon(iid, main_x + 10, iy + 3, 1);
            }
            fb.drawTextTransparentUi(main_x + 36, iy + 5, item.label, text_white);
        } else {
            if (item.icon_id) |iid| {
                drawMenuIcon(iid, main_x + 10, iy + 3, 1);
            }
            const tc = if (item.bold) text_dark else text_dim;
            fb.drawTextTransparentUi(main_x + 36, iy + 5, item.label, tc);
        }
        iy += AERO7_ROW_H;
        if (item.separator_after) {
            fb.drawHLine(main_x + 8, iy, AERO7_LEFT_W - 14, sep);
            iy += 4;
        }
    }

    fb.drawHLine(main_x + 8, all_prog_y - 2, AERO7_LEFT_W - 14, sep);
    const ap_hov = hover_index == AERO7_IDX_ALL;
    if (ap_hov) {
        fb.blendTintRect(main_x + 6, all_prog_y - 1, AERO7_LEFT_W - 12, AERO7_ROW_H, rgb(0x70, 0x98, 0xC8), 50, 255);
        fb.drawTextTransparentUi(main_x + 36, all_prog_y + 5, "All Programs", text_white);
        fb.drawTextTransparentUi(main_x + AERO7_LEFT_W - 22, all_prog_y + 5, ">", rgb(0xE8, 0xF4, 0xFF));
    } else {
        fb.drawTextTransparentUi(main_x + 36, all_prog_y + 5, "All Programs", rgb(0x20, 0x50, 0x88));
        fb.drawTextTransparentUi(main_x + AERO7_LEFT_W - 22, all_prog_y + 5, ">", text_dim);
    }

    iy = content_y + 6;
    var ridx: i32 = 100;
    for (aero7_right) |item| {
        if (iy + AERO7_ROW_H > search_y - 6) break;
        const row_r = hover_index == ridx;
        if (row_r) {
            fb.blendTintRect(split_x + 4, iy - 1, main_w - AERO7_LEFT_W - 12, AERO7_ROW_H, rgb(0x70, 0x98, 0xC8), 50, 255);
            if (item.icon_id) |iid| {
                drawMenuIcon(iid, split_x + 8, iy + 3, 1);
            }
            fb.drawTextTransparentUi(split_x + 34, iy + 5, item.label, text_white);
        } else {
            if (item.icon_id) |iid| {
                drawMenuIcon(iid, split_x + 8, iy + 3, 1);
            }
            const tc = if (item.bold) rgb(0x10, 0x38, 0x68) else text_dim;
            fb.drawTextTransparentUi(split_x + 34, iy + 5, item.label, tc);
        }
        iy += AERO7_ROW_H;
        if (item.separator_after) {
            fb.drawHLine(split_x + 6, iy, main_w - AERO7_LEFT_W - 14, sep);
            iy += 4;
        }
        ridx += 1;
    }

    fb.fillRect(main_x, search_y, main_w, AERO7_SEARCH_H, rgb(0xDC, 0xE4, 0xEE));
    fb.blendTintRect(main_x, search_y, main_w, AERO7_SEARCH_H, rgb(0xF8, 0xFC, 0xFF), 25, 255);
    fb.drawHLine(main_x, search_y, main_w, sep);
    fb.drawRect(main_x + 8, search_y + 9, main_w - 16, 26, rgb(0x98, 0xA8, 0xB8));
    fb.fillRect(main_x + 9, search_y + 10, main_w - 18, 24, rgb(0xFF, 0xFF, 0xFF));
    fb.drawTextTransparentUi(main_x + 16, search_y + 15, "Search programs and files", rgb(0x98, 0xA0, 0xA8));

    fb.fillRect(main_x, foot_y, main_w, AERO7_FOOTER_H, rgb(0xD0, 0xDC, 0xE8));
    fb.blendTintRect(main_x, foot_y, main_w, AERO7_FOOTER_H, rgb(0xF0, 0xF6, 0xFC), 20, 255);
    fb.drawHLine(main_x, foot_y, main_w, sep);

    const log_h = hover_index == 200;
    fb.drawTextTransparentUi(main_x + 10, foot_y + 14, "Log off", if (log_h) rgb(0x30, 0x60, 0x98) else text_dim);

    const sleep_h = hover_index == 202;
    fb.drawTextTransparentUi(main_x + 92, foot_y + 14, "Sleep", if (sleep_h) rgb(0x30, 0x60, 0x98) else text_dim);

    const rst_h = hover_index == 203;
    fb.drawTextTransparentUi(main_x + 156, foot_y + 14, "Restart", if (rst_h) rgb(0x30, 0x60, 0x98) else text_dim);

    const sd_x = main_x + main_w - 116;
    const sd_hov = hover_index == 201;
    fb.fillRoundedRect(sd_x, foot_y + 8, 106, 28, 4, if (sd_hov) rgb(0xD8, 0x50, 0x40) else rgb(0xB8, 0x48, 0x38));
    fb.blendTintRect(sd_x, foot_y + 8, 106, 28, rgb(0xFF, 0xC8, 0xB8), if (sd_hov) 35 else 18, 255);
    fb.drawTextTransparentUi(sd_x + 10, foot_y + 14, "Shut down", text_white);
    fb.drawTextTransparentUi(sd_x + 90, foot_y + 14, ">", rgb(0xFF, 0xE8, 0xE0));
}
