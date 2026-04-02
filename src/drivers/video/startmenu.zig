// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/startmenu.zig
// Purpose: Windows 7-style Start Menu (two columns, search, power flyout, optional All Programs panel).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/ (shell UX / public API names only).

//! Windows 7 风格开始菜单（NT 6.1 Shell 布局）

const std = @import("std");
const fb = @import("framebuffer.zig");
const icons = @import("icons.zig");
const klog = @import("../../rtl/klog.zig");
const dwm = @import("dwm.zig");
const shell_strings = @import("shell_strings.zig");
const app_cfg = @import("../../config/config.zig");
const builtin_apps = @import("builtin_apps.zig");
const kernel32 = @import("../../libs/kernel32.zig");

fn drawMenuIcon(id: icons.IconId, x: i32, y: i32, scale: u32) void {
    icons.drawThemedIcon(id, x, y, scale, .aero);
}

fn rgb(r: u32, g: u32, b: u32) u32 {
    return b | (g << 8) | (r << 16);
}

fn clampMenuI32(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
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

/// 左列：前 `pinned_left_count` 项为固定区，其后为常用程序区（中间加分隔空隙）。
const pinned_left_count: usize = 2;

const aero7_left = [_]MenuItem{
    .{ .label = "Internet Explorer", .icon_id = .browser, .bold = true },
    .{ .label = "Zircon Media Player", .icon_id = .music, .separator_after = true },
    .{ .label = "Terminal", .icon_id = .terminal },
    .{ .label = "Notepad", .icon_id = .text_editor },
    .{ .label = "Calculator", .icon_id = .calculator },
    .{ .label = "Paint", .icon_id = .pictures },
};
/// Win7 右列：库 → 游戏 → 计算机/网络 → 控制面板与程序 → 帮助与运行。
const aero7_right = [_]MenuItem{
    .{ .label = "Documents", .icon_id = .documents, .bold = true },
    .{ .label = "Pictures", .icon_id = .pictures, .bold = true },
    .{ .label = "Music", .icon_id = .music, .bold = true },
    .{ .label = "Videos", .icon_id = .folder, .bold = true },
    .{ .label = "Downloads", .icon_id = .folder, .bold = true },
    .{ .label = "Games", .icon_id = .folder, .separator_after = true },
    .{ .label = "Computer", .icon_id = .computer, .bold = true },
    .{ .label = "Network", .icon_id = .network },
    .{ .label = "Control Panel", .icon_id = .control_panel },
    .{ .label = "Devices and Printers", .icon_id = .printer },
    .{ .label = "Default Programs", .icon_id = .settings },
    .{ .label = "Help and Support", .icon_id = .settings, .separator_after = true },
    .{ .label = "Run...", .icon_id = .terminal },
};

const AERO7_HEADER_H: i32 = 52;
const AERO7_LEFT_W: i32 = 200;
const AERO7_ROW_H: i32 = 24;
/// Win7：搜索与关机同一底栏高度（原 SEARCH+FOOTER 两行合并为一行）。
const AERO7_BOTTOM_BAND_H: i32 = @max(46, 44);
const AERO7_SEARCH_INNER_H: i32 = 26;
const AERO7_RAIL_W: i32 = 52;
/// 大屏下 Win7 风格主面板目标高度；实际 `aeroRect` 会按 `scr_h` 钳位，避免小屏下 `mid_h` 等链式下溢。
const AERO7_DESIRED_MENU_H: i32 = AERO7_HEADER_H + 310 + AERO7_BOTTOM_BAND_H + AERO7_RAIL_W + 12;
const AERO7_IDX_ALL: i32 = 48;

/// 底部：仅 Win7 式「关机」主按钮 + 右侧箭头（注销/睡眠/重启等均在飞出菜单内）。
const IDX_FOOT_SHUTDOWN_BTN: i32 = 201;
const IDX_FOOT_SHUTDOWN_CHEVRON: i32 = 204;

/// 电源弹出层（Switch user … Shut down）
const IDX_FLYOUT_BASE: i32 = 300;

/// 「所有程序」侧栏项（二级面板）
const IDX_ALLPROG_BASE: i32 = 400;
const ALL_PROG_COUNT: i32 = @intCast(builtin_apps.allProgramsCount());

pub const MenuAction = enum {
    none,
    shutdown,
    restart,
    standby,
    logoff,
    lock_workstation,
    hibernate,
    switch_user,
};

var menu_visible: bool = false;
var hover_index: i32 = -1;
/// `updatePointerHover` 检测到变化时的上一索引，供 `getHoverHighlightRepaintBounds` 与当前 `hover_index` 做行级脏区并集。
var hover_prev_for_partial_repaint: i32 = -1;
/// 搜索框输入（开始菜单打开时由主循环 `feedSearchFromKeyboard` 填充）。
var search_buf: [96]u8 = [_]u8{0} ** 96;
var search_len: usize = 0;
var power_flyout_open: bool = false;
var all_programs_open: bool = false;
/// 打开后已绘制的帧数；0 = 首帧走 tint-only 大面板，降低首屏延迟。
var menu_frames_since_open: u8 = 0;

pub fn isVisible() bool {
    return menu_visible;
}

pub fn show(_: MenuStyle) void {
    menu_visible = true;
    hover_index = -1;
    hover_prev_for_partial_repaint = -1;
    power_flyout_open = false;
    all_programs_open = false;
    menu_frames_since_open = 0;
    search_len = 0;
    search_hover_cached_bounds = null;
    search_hover_cache_tick = 0;
}

pub fn hide() void {
    menu_visible = false;
    hover_index = -1;
    hover_prev_for_partial_repaint = -1;
    power_flyout_open = false;
    all_programs_open = false;
    menu_frames_since_open = 0;
    search_len = 0;
    search_hover_cached_bounds = null;
    search_hover_cache_tick = 0;
}

/// 开始菜单可见时消费键盘字符；有缓冲变化返回 true。
fn asciiLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c - 'A' + 'a' else c;
}

/// 搜索非空时：ASCII 子串匹配（大小写不敏感）。空查询显示全部。
fn menuItemMatchesSearch(label: []const u8) bool {
    if (search_len == 0) return true;
    if (search_len > label.len) return false;
    const needle = search_buf[0..search_len];
    var i: usize = 0;
    while (i + needle.len <= label.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |nc, j| {
            if (asciiLower(nc) != asciiLower(label[i + j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

pub fn feedSearchFromKeyboard() bool {
    if (!menu_visible) return false;
    const arch = @import("../../arch.zig");
    var dirty = false;
    while (arch.readInputChar()) |c| {
        if (c == 0x08 or c == 127) {
            if (search_len > 0) {
                search_len -= 1;
                dirty = true;
            }
        } else if (c >= 32 and c < 127 and search_len + 1 < search_buf.len) {
            search_buf[search_len] = c;
            search_len += 1;
            dirty = true;
        }
    }
    return dirty;
}

pub fn toggle(_: MenuStyle) void {
    if (menu_visible) hide() else show(.aero);
}

pub fn setHoverIndex(idx: i32) void {
    hover_index = idx;
}

pub fn pointerHoverIndex() i32 {
    return hover_index;
}

fn aeroRect(scr_h: i32) MenuRect {
    const sh64 = @as(i64, scr_h);
    const max_h64 = @min(@as(i64, AERO7_DESIRED_MENU_H), @max(40, sh64 - 8));
    const h: i32 = @intCast(std.math.clamp(max_h64, 40, @as(i64, std.math.maxInt(i32))));
    const w: i32 = 428;
    const y64 = sh64 - 40 - @as(i64, h);
    const yy: i32 = @intCast(std.math.clamp(y64, std.math.minInt(i32), std.math.maxInt(i32)));
    return .{ .x = 0, .y = yy, .w = w, .h = h };
}

fn rectUnion(a: MenuRect, b: MenuRect) MenuRect {
    const ax2 = @as(i64, a.x) + @as(i64, a.w);
    const ay2 = @as(i64, a.y) + @as(i64, a.h);
    const bx2 = @as(i64, b.x) + @as(i64, b.w);
    const by2 = @as(i64, b.y) + @as(i64, b.h);
    const x0 = @min(@as(i64, a.x), @as(i64, b.x));
    const y0 = @min(@as(i64, a.y), @as(i64, b.y));
    const x1 = @max(ax2, bx2);
    const y1 = @max(ay2, by2);
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .w = @intCast(x1 - x0),
        .h = @intCast(y1 - y0),
    };
}

/// 与 `aeroRect` 一致的主面板（用于未展开时命中）。
pub fn getMenuRect(scr_w: i32, scr_h: i32) MenuRect {
    _ = scr_w;
    return aeroRect(scr_h);
}

fn menuCornerRadius() i32 {
    const r = app_cfg.getStartMenuCornerRadius();
    return @intCast(@max(4, @min(r, 24)));
}

fn allProgramsPanelRect(scr_w: i32, scr_h: i32) MenuRect {
    const r = aeroRect(scr_h);
    const L = innerLayout(scr_h);
    const panel_w: i32 = 196;
    const px0 = @as(i64, r.x) + @as(i64, r.w);
    var px = clampMenuI32(px0);
    const sw = @as(i64, scr_w);
    if (@as(i64, px) + @as(i64, panel_w) > sw - 2) {
        px = @max(2, clampMenuI32(sw - 2 - @as(i64, panel_w)));
    }
    const panel_h_i64 = @as(i64, L.bottom_y) + @as(i64, AERO7_BOTTOM_BAND_H) - @as(i64, L.content_y);
    const panel_h = @max(1, clampMenuI32(panel_h_i64));
    return .{ .x = px, .y = L.content_y, .w = panel_w, .h = panel_h };
}

/// 主菜单 + 电源飞出 +「所有程序」侧栏（点击区外关闭用）。
pub fn getInteractiveBounds(scr_w: i32, scr_h: i32) MenuRect {
    var u = aeroRect(scr_h);
    if (power_flyout_open) u = rectUnion(u, powerFlyoutRect(scr_w, scr_h));
    if (all_programs_open) u = rectUnion(u, allProgramsPanelRect(scr_w, scr_h));
    return u;
}

/// 局部重绘脏区（开始菜单悬停优化路径）。
pub fn getPaintBounds(scr_w: i32, scr_h: i32) MenuRect {
    return getInteractiveBounds(scr_w, scr_h);
}

/// 主面板内「列表项 / 底栏关机条 / 电源飞出 / 所有程序行」悬停高亮所需的**最小**轴对齐脏区（上一索引与当前索引对应行的并集）。
/// `hoverIndexRowBounds` 已按搜索过滤与侧栏几何计算；若两索引均无法解析则返回 `null`，调用方回退 `getPaintBounds`。
/// Ref: docs/cn/DesktopManagerSpec.md — 开始菜单局部重绘与 Shell 合成边界。
pub fn getHoverHighlightRepaintBounds(scr_w: i32, scr_h: i32) ?MenuRect {
    if (!menu_visible) return null;

    var u: ?MenuRect = null;
    if (hoverIndexRowBounds(scr_w, scr_h, hover_prev_for_partial_repaint)) |r| {
        u = r;
    }
    if (hoverIndexRowBounds(scr_w, scr_h, hover_index)) |r| {
        u = if (u) |uu| rectUnion(uu, r) else r;
    }
    if (search_len > 0) {
        const now = kernel32.GetTickCount();
        if (u) |fresh| {
            if (search_hover_cached_bounds) |cb| {
                if (now -% search_hover_cache_tick < search_hover_repaint_min_ms) {
                    return cb;
                }
            }
            search_hover_cached_bounds = fresh;
            search_hover_cache_tick = now;
        }
    } else {
        search_hover_cached_bounds = null;
    }
    return u;
}

fn hoverIndexRowBounds(scr_w: i32, scr_h: i32, idx: i32) ?MenuRect {
    if (idx < 0) return null;
    const L = innerLayout(scr_h);
    const main_x = L.main_x;
    const main_w = L.main_w;
    const content_y = L.content_y;
    const bottom_y = L.bottom_y;
    const split_x = L.split_x;
    const all_prog_y = L.all_prog_y;

    if (idx >= 0 and idx < aero7_left.len) {
        return hoverIndexRowBoundsLeft(scr_h, idx, content_y, all_prog_y, main_x, split_x);
    }
    if (idx >= 100 and idx < IDX_FLYOUT_BASE) {
        const ri = idx - 100;
        if (ri < 0 or ri >= aero7_right.len) return null;
        return hoverIndexRowBoundsRight(scr_h, @intCast(ri), content_y, bottom_y, split_x, main_x, main_w);
    }
    if (idx == AERO7_IDX_ALL) {
        return .{
            .x = main_x + 6,
            .y = all_prog_y - 1,
            .w = AERO7_LEFT_W - 12,
            .h = AERO7_ROW_H,
        };
    }
    if (idx == IDX_FOOT_SHUTDOWN_BTN or idx == IDX_FOOT_SHUTDOWN_CHEVRON) {
        const sd_x = main_x + main_w - 116;
        const sd_y = bottom_y + @divTrunc(AERO7_BOTTOM_BAND_H - 28, 2);
        return .{ .x = sd_x, .y = sd_y, .w = 106, .h = 28 };
    }
    if (idx >= IDX_FLYOUT_BASE + 1 and idx <= IDX_FLYOUT_BASE + 7) {
        const fr = powerFlyoutRect(scr_w, scr_h);
        const row = idx - (IDX_FLYOUT_BASE + 1);
        const row_h: i32 = 22;
        const iy = fr.y + 3 + row * row_h;
        return .{ .x = fr.x + 3, .y = iy - 1, .w = fr.w - 6, .h = row_h };
    }
    if (idx >= IDX_ALLPROG_BASE and idx < IDX_ALLPROG_BASE + ALL_PROG_COUNT) {
        const pr = allProgramsPanelRect(scr_w, scr_h);
        const row_i = idx - IDX_ALLPROG_BASE;
        const pad: i32 = 8;
        var iy: i32 = pr.y + pad;
        var i: i32 = 0;
        while (i < ALL_PROG_COUNT) : (i += 1) {
            if (!menuItemMatchesSearch(allProgEntryLabel(i))) continue;
            if (i == row_i) {
                return .{ .x = pr.x + 4, .y = iy - 1, .w = pr.w - 8, .h = AERO7_ROW_H };
            }
            iy += AERO7_ROW_H;
        }
        return null;
    }
    return null;
}

fn hoverIndexRowBoundsLeft(_: i32, li_target: i32, content_y: i32, all_prog_y: i32, main_x: i32, _: i32) ?MenuRect {
    var iy: i32 = content_y + 6;
    for (aero7_left, 0..) |item, li| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (iy + AERO7_ROW_H > all_prog_y - 2) break;
        if (@as(i32, @intCast(li)) == li_target) {
            return .{
                .x = main_x + 6,
                .y = iy - 1,
                .w = AERO7_LEFT_W - 12,
                .h = AERO7_ROW_H,
            };
        }
        iy += AERO7_ROW_H;
        if (search_len == 0 and item.separator_after) {
            iy += 4;
            if (li + 1 == pinned_left_count) iy += 5;
        }
    }
    return null;
}

fn hoverIndexRowBoundsRight(_: i32, ri: usize, content_y: i32, bottom_y: i32, split_x: i32, _: i32, main_w: i32) ?MenuRect {
    var iy: i32 = content_y + 6;
    for (aero7_right, 0..) |item, rj| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (iy + AERO7_ROW_H > bottom_y - 6) break;
        if (rj == ri) {
            return .{
                .x = split_x + 4,
                .y = iy - 1,
                .w = main_w - AERO7_LEFT_W - 12,
                .h = AERO7_ROW_H,
            };
        }
        iy += AERO7_ROW_H;
        if (search_len == 0 and item.separator_after) iy += 4;
    }
    return null;
}

pub const MenuRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: MenuRect, px: i32, py: i32) bool {
        const pxi = @as(i64, px);
        const pyi = @as(i64, py);
        const x0 = @as(i64, self.x);
        const y0 = @as(i64, self.y);
        const w0 = @as(i64, self.w);
        const h0 = @as(i64, self.h);
        return pxi >= x0 and pxi < x0 + w0 and pyi >= y0 and pyi < y0 + h0;
    }
};

/// 搜索过滤开启时合并 hover 重绘：两次 `getHoverHighlightRepaintBounds` 间隔不低于该毫秒数（`GetTickCount` 回绕安全用 `-%`）。
const search_hover_repaint_min_ms: u32 = 50;
var search_hover_cached_bounds: ?MenuRect = null;
var search_hover_cache_tick: u32 = 0;

fn innerLayout(scr_h: i32) struct {
    inner_x: i32,
    inner_y: i32,
    inner_w: i32,
    inner_h: i32,
    main_x: i32,
    main_w: i32,
    foot_y: i32,
    bottom_y: i32,
    content_y: i32,
    mid_h: i32,
    search_y: i32,
    split_x: i32,
    all_prog_y: i32,
} {
    const r = aeroRect(scr_h);
    const rx = @as(i64, r.x);
    const ry = @as(i64, r.y);
    const rw = @as(i64, r.w);
    const rh = @as(i64, r.h);
    const inner_x = clampMenuI32(rx + 4);
    const inner_y = clampMenuI32(ry + 4);
    const inner_w = @max(0, clampMenuI32(rw - 8));
    const inner_h = @max(0, clampMenuI32(rh - 8));
    const rail = @as(i64, AERO7_RAIL_W);
    const main_x = clampMenuI32(@as(i64, inner_x) + rail);
    const main_w = @max(0, clampMenuI32(@as(i64, inner_w) - rail));
    const content_y = clampMenuI32(@as(i64, inner_y) + @as(i64, AERO7_HEADER_H) + 2);
    const mid_raw = @as(i64, inner_h) - @as(i64, AERO7_HEADER_H) - @as(i64, AERO7_BOTTOM_BAND_H) - 6;
    const mid_h = @max(0, clampMenuI32(mid_raw));
    const bottom_y = clampMenuI32(@as(i64, inner_y) + @as(i64, inner_h) - @as(i64, AERO7_BOTTOM_BAND_H));
    const foot_y = bottom_y;
    const search_y = bottom_y;
    const split_x = clampMenuI32(@as(i64, main_x) + @as(i64, AERO7_LEFT_W));
    const all_prog_y = clampMenuI32(@as(i64, content_y) + @as(i64, mid_h) - @as(i64, AERO7_ROW_H) - 6);
    return .{
        .inner_x = inner_x,
        .inner_y = inner_y,
        .inner_w = inner_w,
        .inner_h = inner_h,
        .main_x = main_x,
        .main_w = main_w,
        .foot_y = foot_y,
        .bottom_y = bottom_y,
        .content_y = content_y,
        .mid_h = mid_h,
        .search_y = search_y,
        .split_x = split_x,
        .all_prog_y = all_prog_y,
    };
}

fn leftColumnHoverIndex(px: i32, py: i32, content_y: i32, all_prog_y: i32, main_x: i32, split_x: i32) i32 {
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    if (pxi < @as(i64, main_x) + 8 or pxi >= @as(i64, split_x) or
        pyi < @as(i64, content_y) + 6 or pyi >= @as(i64, all_prog_y)) return -1;
    var iy = @as(i64, content_y) + 6;
    const row = @as(i64, AERO7_ROW_H);
    for (aero7_left, 0..) |item, li| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (pyi >= iy and pyi < iy + row) return @intCast(li);
        iy += row;
        if (search_len == 0 and item.separator_after) {
            iy += 4;
            if (li + 1 == pinned_left_count) iy += 5;
        }
    }
    return -1;
}

fn rightColumnHoverIndex(px: i32, py: i32, content_y: i32, bottom_y: i32, split_x: i32, main_x: i32, main_w: i32) i32 {
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    if (pxi < @as(i64, split_x) + 6 or pxi >= @as(i64, main_x) + @as(i64, main_w) - 8 or
        pyi < @as(i64, content_y) + 6 or pyi >= @as(i64, bottom_y) - 4) return -1;
    var iy = @as(i64, content_y) + 6;
    const row = @as(i64, AERO7_ROW_H);
    for (aero7_right, 0..) |item, ri| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (pyi >= iy and pyi < iy + row) return 100 + @as(i32, @intCast(ri));
        iy += row;
        if (search_len == 0 and item.separator_after) iy += 4;
    }
    return -1;
}

fn allProgramsHoverIndex(px: i32, py: i32, scr_w: i32, scr_h: i32) i32 {
    if (!all_programs_open) return -1;
    const pr = allProgramsPanelRect(scr_w, scr_h);
    if (!pr.contains(px, py)) return -1;
    const pad: i32 = 8;
    var iy = pr.y + pad;
    var i: i32 = 0;
    while (i < ALL_PROG_COUNT) : (i += 1) {
        if (!menuItemMatchesSearch(allProgEntryLabel(i))) continue;
        if (py >= iy and py < iy + AERO7_ROW_H) return IDX_ALLPROG_BASE + i;
        iy += AERO7_ROW_H;
    }
    return -1;
}

fn powerFlyoutRect(scr_w: i32, scr_h: i32) MenuRect {
    const L = innerLayout(scr_h);
    const flyout_w: i32 = 176;
    const row_h: i32 = 22;
    const rows: i32 = 7;
    const flyout_h = 6 + rows * row_h;
    const sd_x = clampMenuI32(@as(i64, L.main_x) + @as(i64, L.main_w) - 116);
    var fx = clampMenuI32(@as(i64, sd_x) + 108);
    const sw = @as(i64, scr_w);
    if (@as(i64, fx) + @as(i64, flyout_w) > sw - 2) {
        fx = @max(2, clampMenuI32(sw - 2 - @as(i64, flyout_w)));
    }
    const r = aeroRect(scr_h);
    if (fx < r.x) fx = r.x;
    const fy = clampMenuI32(@as(i64, L.bottom_y) - @as(i64, flyout_h) + 2);
    return .{ .x = fx, .y = fy, .w = flyout_w, .h = flyout_h };
}

fn powerFlyoutHoverIndex(px: i32, py: i32, scr_w: i32, scr_h: i32) i32 {
    const fr = powerFlyoutRect(scr_w, scr_h);
    if (!fr.contains(px, py)) return -1;
    const row_h: i32 = 22;
    const body_y = @as(i64, fr.y) + 3;
    const row = @divTrunc(@as(i64, py) - body_y, row_h);
    if (row < 0 or row > 6) return -1;
    return IDX_FLYOUT_BASE + 1 + @as(i32, @intCast(row));
}

pub fn updatePointerHover(px: i32, py: i32, scr_w: i32, scr_h: i32) bool {
    if (!menu_visible) return false;
    const prev = hover_index;
    hover_index = aero7HoverIndex(px, py, scr_w, scr_h);
    if (prev != hover_index) {
        hover_prev_for_partial_repaint = prev;
    }
    return prev != hover_index;
}

fn aero7HoverIndex(px: i32, py: i32, scr_w: i32, scr_h: i32) i32 {
    const r = aeroRect(scr_h);
    const in_flyout = power_flyout_open and powerFlyoutRect(scr_w, scr_h).contains(px, py);
    const in_allprog = all_programs_open and allProgramsPanelRect(scr_w, scr_h).contains(px, py);
    if (!r.contains(px, py) and !in_flyout and !in_allprog) {
        return -1;
    }

    if (power_flyout_open) {
        const fh = powerFlyoutHoverIndex(px, py, scr_w, scr_h);
        if (fh >= 0) return fh;
    }

    if (all_programs_open) {
        const ap = allProgramsHoverIndex(px, py, scr_w, scr_h);
        if (ap >= 0) return ap;
    }

    const L = innerLayout(scr_h);
    const main_x = L.main_x;
    const main_w = L.main_w;
    const content_y = L.content_y;
    const bottom_y = L.bottom_y;
    const split_x = L.split_x;
    const all_prog_y = L.all_prog_y;
    const inner_y = L.inner_y;
    const inner_h = L.inner_h;

    const pyi = @as(i64, py);
    const pxi = @as(i64, px);
    if (pyi >= @as(i64, bottom_y) and pyi < @as(i64, inner_y) + @as(i64, inner_h)) {
        const sd_y = @as(i64, bottom_y) + @divTrunc(AERO7_BOTTOM_BAND_H - 28, 2);
        if (pyi >= sd_y and pyi < sd_y + 28) {
            const sd_x = @as(i64, main_x) + @as(i64, main_w) - 116;
            if (pxi >= sd_x and pxi < sd_x + 80) return IDX_FOOT_SHUTDOWN_BTN;
            if (pxi >= sd_x + 80 and pxi < sd_x + 106) return IDX_FOOT_SHUTDOWN_CHEVRON;
        }
        return -1;
    }

    if (pyi >= @as(i64, all_prog_y) and pyi < @as(i64, all_prog_y) + @as(i64, AERO7_ROW_H) and
        pxi >= @as(i64, main_x) + 8 and pxi < @as(i64, split_x))
        return AERO7_IDX_ALL;

    const lh = leftColumnHoverIndex(px, py, content_y, all_prog_y, main_x, split_x);
    if (lh >= 0) return lh;

    const rh = rightColumnHoverIndex(px, py, content_y, bottom_y, split_x, main_x, main_w);
    if (rh >= 0) return rh;

    return -1;
}

fn handlePowerFlyoutSelection(idx: i32) MenuAction {
    power_flyout_open = false;
    return switch (idx) {
        IDX_FLYOUT_BASE + 1 => {
            klog.info("startmenu: Switch user (stub)", .{});
            return .switch_user;
        },
        IDX_FLYOUT_BASE + 2 => .logoff,
        IDX_FLYOUT_BASE + 3 => .lock_workstation,
        IDX_FLYOUT_BASE + 4 => .restart,
        IDX_FLYOUT_BASE + 5 => .standby,
        IDX_FLYOUT_BASE + 6 => {
            klog.info("startmenu: Hibernate (stub)", .{});
            return .hibernate;
        },
        IDX_FLYOUT_BASE + 7 => .shutdown,
        else => .none,
    };
}

fn allProgEntryLabel(row: i32) []const u8 {
    if (row < 0 or row >= ALL_PROG_COUNT) return "";
    return builtin_apps.titleOf(builtin_apps.allProgramsId(@intCast(row)));
}

fn handleAero7MenuClick(px: i32, py: i32, scr_w: i32, scr_h: i32) MenuAction {
    const h = aero7HoverIndex(px, py, scr_w, scr_h);
    if (power_flyout_open and h >= IDX_FLYOUT_BASE + 1 and h <= IDX_FLYOUT_BASE + 7) {
        return handlePowerFlyoutSelection(h);
    }
    if (h == IDX_FOOT_SHUTDOWN_CHEVRON) {
        power_flyout_open = !power_flyout_open;
        if (power_flyout_open) all_programs_open = false;
        return .none;
    }
    if (h == IDX_FOOT_SHUTDOWN_BTN) return .shutdown;
    if (all_programs_open and h >= IDX_ALLPROG_BASE and h < IDX_ALLPROG_BASE + ALL_PROG_COUNT) {
        builtin_apps.launch(builtin_apps.allProgramsId(@intCast(h - IDX_ALLPROG_BASE)));
        return .none;
    }
    if (h >= 0 and h < aero7_left.len) {
        builtin_apps.launch(switch (@as(usize, @intCast(h))) {
            0 => .ie8,
            1 => .wmp,
            2 => .cmd_shell,
            3 => .notepad,
            4 => .calculator,
            5 => .paint,
            else => .generic_stub,
        });
        return .none;
    }
    if (h == AERO7_IDX_ALL) {
        all_programs_open = !all_programs_open;
        if (all_programs_open) power_flyout_open = false;
        return .none;
    }
    if (h >= 100 and h < IDX_FLYOUT_BASE) {
        const idx: usize = @intCast(h - 100);
        if (idx < aero7_right.len) {
            const app: builtin_apps.BuiltinAppId = switch (idx) {
                0 => .shell_documents,
                1 => .shell_pictures,
                2 => .shell_music,
                3 => .shell_videos,
                4 => .shell_downloads,
                5 => .games_folder,
                6 => .shell_computer,
                7 => .shell_network,
                8 => .control_panel,
                9 => .shell_devices_printers,
                10 => .shell_default_programs,
                11 => .shell_help,
                12 => .shell_run,
                else => .generic_stub,
            };
            builtin_apps.launch(app);
        }
    }
    return .none;
}

pub fn handleMenuClick(px: i32, py: i32, scr_w: i32, scr_h: i32) MenuAction {
    if (!menu_visible) return .none;
    const r = getInteractiveBounds(scr_w, scr_h);
    if (!r.contains(px, py)) return .none;
    if (@import("build_options").desktop_bisect) {
        klog.debug("startmenu: click (%d,%d) scr %d x %d", .{ px, py, scr_w, scr_h });
    }
    return handleAero7MenuClick(px, py, scr_w, scr_h);
}

fn drawPowerFlyout(scr_w: i32, scr_h: i32) void {
    const fr = powerFlyoutRect(scr_w, scr_h);
    const text_dark = rgb(0x18, 0x1C, 0x22);
    const text_white = rgb(0xFF, 0xFF, 0xFF);
    const sep = rgb(0xB8, 0xC4, 0xD4);
    const row_h: i32 = 22;
    const cr = @max(4, menuCornerRadius() - 2);
    const labels = shell_strings.powerFlyoutLabels();

    fb.fillRoundedRect(fr.x, fr.y, fr.w, fr.h, cr, rgb(0xF2, 0xF4, 0xF8));
    fb.draw3DRect(fr.x, fr.y, fr.w, fr.h, rgb(0xFF, 0xFF, 0xFF), rgb(0x70, 0x80, 0x90));
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(fr.x + 1, fr.y + 1, fr.w - 2, fr.h - 2, rgb(0x40, 0x58, 0x70), .panel);
    }

    var iy: i32 = fr.y + 3;
    for (labels, 0..) |label, i| {
        const idx: i32 = IDX_FLYOUT_BASE + 1 + @as(i32, @intCast(i));
        const row_r = hover_index == idx;
        if (row_r) {
            fb.blendTintRect(fr.x + 3, iy - 1, fr.w - 6, row_h, rgb(0x70, 0x98, 0xC8), 55, 255);
            fb.drawTextTransparentUi(fr.x + 10, iy + 4, label, text_white);
        } else {
            fb.drawTextTransparentUi(fr.x + 10, iy + 4, label, text_dark);
        }
        iy += row_h;
        if (i == 0 or i == 2 or i == 5) {
            fb.drawHLine(fr.x + 6, iy - 1, fr.w - 12, sep);
        }
    }
}

/// 搜索框内右侧简易放大镜（几何图形，非商标图标）。
fn drawSearchMagnifier(cx: i32, cy: i32, fg: u32) void {
    const ox = cx;
    const oy = cy;
    fb.drawRect(ox, oy, 9, 9, fg);
    fb.drawHLine(ox + 6, oy + 6, 6, fg);
    fb.drawVLine(ox + 6, oy + 6, 6, fg);
}

fn drawOrbGraphic(ox: i32, oy: i32) void {
    fb.fillRoundedRect(ox, oy, 36, 36, 18, rgb(0x28, 0x48, 0x78));
    fb.drawGradientV(ox + 1, oy + 1, 34, 17, rgb(0x50, 0x78, 0xA8), rgb(0x28, 0x48, 0x78));
    const inset: i32 = 9;
    const cell: i32 = 8;
    const g: i32 = 1;
    fb.fillRect(ox + inset, oy + inset, cell, cell, rgb(0xA8, 0xD4, 0xF8));
    fb.fillRect(ox + inset + cell + g, oy + inset, cell, cell, rgb(0xA8, 0xD4, 0xF8));
    fb.fillRect(ox + inset, oy + inset + cell + g, cell, cell, rgb(0x78, 0xB0, 0xE8));
    fb.fillRect(ox + inset + cell + g, oy + inset + cell + g, cell, cell, rgb(0x78, 0xB0, 0xE8));
}

fn drawAllProgramsSidePanel(scr_w: i32, scr_h: i32) void {
    if (!all_programs_open) return;
    const pr = allProgramsPanelRect(scr_w, scr_h);
    const cr = menuCornerRadius();
    const text_dark = rgb(0x18, 0x1C, 0x22);
    const text_white = rgb(0xFF, 0xFF, 0xFF);
    const sep = rgb(0xB8, 0xC4, 0xD4);

    fb.fillRoundedRect(pr.x, pr.y, pr.w, pr.h, cr, rgb(0xF4, 0xF6, 0xFA));
    fb.draw3DRect(pr.x, pr.y, pr.w, pr.h, rgb(0xFF, 0xFF, 0xFF), rgb(0x70, 0x80, 0x90));
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(pr.x + 1, pr.y + 1, pr.w - 2, pr.h - 2, rgb(0x40, 0x58, 0x70), .panel);
    }

    var iy: i32 = pr.y + 8;
    var i: i32 = 0;
    while (i < ALL_PROG_COUNT) : (i += 1) {
        const lab = allProgEntryLabel(i);
        if (!menuItemMatchesSearch(lab)) continue;
        const idx = IDX_ALLPROG_BASE + i;
        const row_r = hover_index == idx;
        if (row_r) {
            fb.blendTintRect(pr.x + 4, iy - 1, pr.w - 8, AERO7_ROW_H, rgb(0x70, 0x98, 0xC8), 55, 255);
            fb.drawTextTransparentUi(pr.x + 12, iy + 5, lab, text_white);
        } else {
            fb.drawTextTransparentUi(pr.x + 12, iy + 5, lab, text_dark);
        }
        iy += AERO7_ROW_H;
    }
    fb.drawHLine(pr.x + 8, iy + 2, pr.w - 16, sep);
    iy += 6;
    fb.drawTextTransparentUi(pr.x + 10, iy, shell_strings.startmenuLine("all_prog_stub_note"), rgb(0x78, 0x80, 0x8A)); // 仍用通用提示串
}

pub fn render(scr_w: i32, scr_h: i32) void {
    if (!menu_visible or !fb.isInitialized()) return;
    defer {
        if (menu_visible and menu_frames_since_open < 255) menu_frames_since_open +%= 1;
    }

    const r = aeroRect(scr_h);
    const L = innerLayout(scr_h);
    const text_dark = rgb(0x18, 0x1C, 0x22);
    const text_dim = rgb(0x50, 0x58, 0x62);
    const text_white = rgb(0xFF, 0xFF, 0xFF);
    const sep = rgb(0xB8, 0xC4, 0xD4);
    const rail_bg = rgb(0x10, 0x1C, 0x30);
    const cr = menuCornerRadius();
    // 前两帧 tint-only，减轻壳层刚打开时盒式模糊与首帧卡顿。
    const panel_open_lite = menu_frames_since_open <= 1;

    fb.blendTintRect(r.x + 5, r.y + 5, r.w, r.h, rgb(0x00, 0x00, 0x00), 35, 255);

    const inner_x = L.inner_x;
    const inner_y = L.inner_y;
    const inner_w = L.inner_w;
    const inner_h = L.inner_h;

    if (dwm.isGlassEnabled()) {
        // `panel_open_lite`：`renderGlassTintOnly` 无盒式模糊、不占 `blur_budget`；与 `display` 壳层 `setGlassLiteBlurEnabled` 同属交互降级（SOFTWARE_COMPOSITOR_WDDM.md）。
        if (panel_open_lite) {
            dwm.renderGlassTintOnly(inner_x, inner_y, inner_w, inner_h, rgb(0x28, 0x40, 0x60), .panel);
        } else {
            dwm.renderGlassEffect(inner_x, inner_y, inner_w, inner_h, rgb(0x28, 0x40, 0x60), .panel);
        }
    } else {
        fb.fillRoundedRect(inner_x, inner_y, inner_w, inner_h, cr, rgb(0xE8, 0xEE, 0xF6));
        fb.blendTintRect(inner_x, inner_y, inner_w, inner_h, rgb(0x88, 0xA8, 0xC8), 22, 200);
    }
    fb.draw3DRect(r.x, r.y, r.w, r.h, rgb(0xF5, 0xFA, 0xFF), rgb(0x40, 0x58, 0x70));
    fb.draw3DRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2, rgb(0xC8, 0xD8, 0xE8), rgb(0x30, 0x40, 0x55));

    const rail = AERO7_RAIL_W;
    const main_x = L.main_x;
    const main_w = L.main_w;

    fb.fillRect(inner_x, inner_y, rail, inner_h, rail_bg);
    fb.drawGradientV(inner_x, inner_y, rail, @divTrunc(inner_h, 2), rgb(0x18, 0x28, 0x40), rail_bg);
    fb.drawVLine(main_x - 1, inner_y, inner_h, rgb(0x30, 0x44, 0x5C));
    const orb_y = clampMenuI32(@as(i64, inner_y) + @as(i64, inner_h) - @as(i64, rail) - 6);
    drawOrbGraphic(inner_x + 8, orb_y);

    const hdr_h = AERO7_HEADER_H;
    fb.drawGradientH(main_x, inner_y, main_w, hdr_h, rgb(0x5C, 0x6C, 0x7C), rgb(0x88, 0x94, 0xA4));
    fb.blendTintRect(main_x, inner_y, main_w, hdr_h, rgb(0xE0, 0xE8, 0xF0), 40, 215);
    fb.addSpecularBand(main_x, inner_y, main_w, @divTrunc(hdr_h, 3), 20);
    fb.drawHLine(main_x + 2, inner_y + 2, main_w - 4, rgb(0xF8, 0xFC, 0xFF));

    const av_sz: i32 = 40;
    const av_x = clampMenuI32(@as(i64, main_x) + @as(i64, main_w) - @as(i64, av_sz) - 10);
    fb.fillRoundedRect(av_x, inner_y + 8, av_sz, av_sz, 5, rgb(0xA8, 0xB8, 0xC8));
    fb.blendTintRect(av_x, inner_y + 8, av_sz, av_sz, rgb(0xFF, 0xFF, 0xFF), 35, 255);
    fb.drawRect(av_x, inner_y + 8, av_sz, av_sz, rgb(0xD8, 0xE4, 0xF0));
    drawMenuIcon(.user, av_x + 4, inner_y + 12, 2);
    const disp_name = app_cfg.getStartMenuUserDisplayName();
    const name_w = fb.textWidth(disp_name);
    const name_right = av_x - 8;
    var name_x = name_right - name_w;
    const name_min_x = main_x + 12;
    if (name_x < name_min_x) name_x = name_min_x;
    fb.drawTextTransparentUi(name_x, inner_y + 11, disp_name, text_white);
    const sub = app_cfg.getStartMenuAccountSubtitle();
    if (sub.len > 0) {
        const sw = fb.textWidth(sub);
        var sx = name_right - sw;
        if (sx < name_min_x) sx = name_min_x;
        fb.drawTextTransparentUi(sx, inner_y + 29, sub, rgb(0xC8, 0xD4, 0xE4));
    }

    const content_y = L.content_y;
    const bottom_y = L.bottom_y;
    const split_x = L.split_x;
    const all_prog_y = L.all_prog_y;
    const col_h = @max(0, clampMenuI32(@as(i64, bottom_y) + @as(i64, AERO7_BOTTOM_BAND_H) - @as(i64, content_y)));

    // 单列模糊已在整板完成；左右仅叠色保持对比，避免二次 boxBlur 造成左淡右透不对称。
    const left_base = rgb(0xD0, 0xE0, 0xF0);
    fb.fillRect(main_x, content_y, AERO7_LEFT_W, col_h, left_base);
    fb.blendTintRect(main_x, content_y, AERO7_LEFT_W, col_h, rgb(0xF8, 0xFA, 0xFC), 38, 220);
    fb.blendTintRect(main_x, content_y, AERO7_LEFT_W, col_h, rgb(0x58, 0x78, 0x98), 22, 130);

    const right_col_w = main_w - AERO7_LEFT_W;
    const right_bg = rgb(0x1C, 0x34, 0x50);
    const right_bg_hi = rgb(0x38, 0x54, 0x74);
    fb.fillRect(split_x, content_y, right_col_w, col_h, right_bg);
    fb.drawGradientV(split_x, content_y, right_col_w, @min(100, col_h), right_bg_hi, right_bg);
    fb.blendTintRect(split_x, content_y, right_col_w, col_h, rgb(0x70, 0x98, 0xC8), 26, 110);
    fb.blendTintRect(split_x, content_y, right_col_w, col_h, rgb(0x20, 0x38, 0x50), 14, 180);
    fb.drawVLine(split_x, content_y, col_h, sep);

    var iy: i32 = content_y + 6;
    for (aero7_left, 0..) |item, li| {
        if (!menuItemMatchesSearch(item.label)) continue;
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
        if (search_len == 0 and item.separator_after) {
            fb.drawHLine(main_x + 8, iy, AERO7_LEFT_W - 14, sep);
            iy += 4;
            if (li + 1 == pinned_left_count) iy += 5;
        }
    }

    fb.drawHLine(main_x + 8, all_prog_y - 2, AERO7_LEFT_W - 14, sep);
    const ap_hov = hover_index == AERO7_IDX_ALL;
    const all_prog_lbl = shell_strings.startmenuLine("all_programs");
    if (ap_hov) {
        fb.blendTintRect(main_x + 6, all_prog_y - 1, AERO7_LEFT_W - 12, AERO7_ROW_H, rgb(0x70, 0x98, 0xC8), 50, 255);
        fb.drawTextTransparentUi(main_x + 36, all_prog_y + 5, all_prog_lbl, text_white);
        fb.drawTextTransparentUi(main_x + AERO7_LEFT_W - 22, all_prog_y + 5, ">", rgb(0xE8, 0xF4, 0xFF));
    } else {
        fb.drawTextTransparentUi(main_x + 36, all_prog_y + 5, all_prog_lbl, rgb(0x20, 0x50, 0x88));
        fb.drawTextTransparentUi(main_x + AERO7_LEFT_W - 22, all_prog_y + 5, ">", text_dim);
    }

    const icon_cell: i32 = icons.getIconTotalSize(1);
    const icon_col_x = split_x + 10;
    const text_cell_x = icon_col_x + icon_cell + 6;
    const right_bold = rgb(0xF2, 0xF6, 0xFC);
    const right_norm = rgb(0xC8, 0xD8, 0xEC);

    iy = content_y + 6;
    for (aero7_right, 0..) |item, ri| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (iy + AERO7_ROW_H > bottom_y - 6) break;
        const row_r = hover_index == 100 + @as(i32, @intCast(ri));
        const icon_y = iy + @divTrunc(AERO7_ROW_H - icon_cell, 2);
        if (row_r) {
            fb.blendTintRect(split_x + 4, iy - 1, main_w - AERO7_LEFT_W - 12, AERO7_ROW_H, rgb(0x70, 0x98, 0xC8), 50, 255);
            if (item.icon_id) |iid| {
                drawMenuIcon(iid, icon_col_x, icon_y, 1);
            }
            fb.drawTextTransparentUi(text_cell_x, iy + 5, item.label, text_white);
        } else {
            if (item.icon_id) |iid| {
                drawMenuIcon(iid, icon_col_x, icon_y, 1);
            }
            const tc = if (item.bold) right_bold else right_norm;
            fb.drawTextTransparentUi(text_cell_x, iy + 5, item.label, tc);
        }
        iy += AERO7_ROW_H;
        if (search_len == 0 and item.separator_after) {
            fb.drawHLine(split_x + 6, iy, main_w - AERO7_LEFT_W - 14, sep);
            iy += 4;
        }
    }

    fb.drawHLine(main_x, bottom_y, main_w, sep);
    const search_pad_x: i32 = 8;
    const search_y0 = bottom_y + @divTrunc(AERO7_BOTTOM_BAND_H - (AERO7_SEARCH_INNER_H + 8), 2);
    const mag_w: i32 = 20;
    const search_inner_w = AERO7_LEFT_W - search_pad_x * 2 - mag_w;
    fb.drawRect(main_x + search_pad_x, search_y0, search_inner_w + mag_w, AERO7_SEARCH_INNER_H, rgb(0x98, 0xA8, 0xB8));
    fb.fillRect(main_x + search_pad_x + 1, search_y0 + 1, search_inner_w + mag_w - 2, AERO7_SEARCH_INNER_H - 2, rgb(0xFF, 0xFF, 0xFF));
    const ph = shell_strings.startmenuLine("search_placeholder");
    if (search_len > 0) {
        fb.drawTextTransparentClipped(main_x + search_pad_x + 6, search_y0 + 5, main_x + search_pad_x + search_inner_w + 2, search_buf[0..search_len], rgb(0x20, 0x24, 0x2C));
    } else {
        fb.drawTextTransparentClipped(main_x + search_pad_x + 6, search_y0 + 5, main_x + search_pad_x + search_inner_w + 2, ph, rgb(0x98, 0xA0, 0xA8));
    }
    drawSearchMagnifier(main_x + search_pad_x + search_inner_w + 4, search_y0 + 6, rgb(0x70, 0x80, 0x90));

    const sd_x = main_x + main_w - 116;
    const sd_y = bottom_y + @divTrunc(AERO7_BOTTOM_BAND_H - 28, 2);
    const sd_body_hov = hover_index == IDX_FOOT_SHUTDOWN_BTN;
    const sd_ch_hov = hover_index == IDX_FOOT_SHUTDOWN_CHEVRON;
    const sd_hov = sd_body_hov or sd_ch_hov;
    const sd_cr = @max(3, cr - 3);
    // Aero 透明凸起：冷色玻璃 + 顶缘高光，非实心红色关机块。
    const sd_top = if (sd_hov) rgb(0xA8, 0xC8, 0xF0) else rgb(0x88, 0xA8, 0xD0);
    const sd_bot = if (sd_hov) rgb(0x58, 0x78, 0xA8) else rgb(0x48, 0x64, 0x90);
    fb.fillRoundedRect(sd_x, sd_y, 106, 28, sd_cr, sd_bot);
    fb.drawGradientV(sd_x + 1, sd_y + 1, 104, 26, sd_top, sd_bot);
    fb.blendTintRect(sd_x + 1, sd_y + 1, 104, 10, rgb(0xFF, 0xFF, 0xFF), if (sd_hov) 52 else 38, 200);
    fb.drawHLine(sd_x + 2, sd_y + 1, 102, rgb(0xF0, 0xF8, 0xFF));
    fb.blendTintRect(sd_x, sd_y, 106, 28, rgb(0x28, 0x40, 0x60), if (sd_hov) 18 else 12, 255);
    fb.drawRect(sd_x, sd_y, 106, 28, rgb(0xB8, 0xD0, 0xE8));
    fb.drawRect(sd_x + 1, sd_y + 1, 104, 26, rgb(0x40, 0x58, 0x70));
    fb.drawVLine(sd_x + 80, sd_y + 4, 20, rgb(0x68, 0x88, 0xA8));
    fb.drawTextTransparentUiCenteredInRect(sd_x + 2, sd_y, 76, 28, shell_strings.startmenuLine("foot_shut_down"), text_white);
    fb.drawTextTransparentUi(sd_x + 88, sd_y + @divTrunc(28 - 16, 2), ">", if (sd_ch_hov) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFC));

    drawAllProgramsSidePanel(scr_w, scr_h);

    if (power_flyout_open) {
        drawPowerFlyout(scr_w, scr_h);
    }
}
