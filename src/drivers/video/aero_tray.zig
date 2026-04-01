//! Windows 7 Aero 任务栏右侧：通知区图标几何与命中（与 DWM 提交区分离，避免托盘像素重叠）。
//! 图标按「步进 = 位图宽度 + 间隙」排列，等价于 Wayland surface 独立 anchor，而非 DirectX 纹理拼合重叠。

const std = @import("std");
const icons = @import("icons.zig");

/// 与 `display.renderDesktopAeroTaskbar` 右侧 Show Desktop 条同宽。
pub const TASKBAR_PEEK_STRIP_W: i32 = 14;

pub const TrayLayout = struct {
    tb_y: i32,
    tb_h: i32,
    peek_w: i32,
    /// 第一个托盘图标（网络）左上角 X
    tray_icons_x: i32,
    tray_icons_y: i32,
    icon_s: u32,
    icon_px: i32,
    icon_step: i32,
    net_x: i32,
    /// 音量/操作区（占位图标，与 Win7 托盘第二格对齐）
    vol_x: i32,
    set_x: i32,
    chevron_x: i32,
    chevron_y: i32,
    chevron_w: i32,
    chevron_h: i32,
    /// 时钟文字左上角（与 renderer 一致）
    clk_x: i32,
    clk_y: i32,
    /// 通知区+时钟合成「托盘槽」背景（Show Desktop 条左侧）
    shelf_x: i32,
    shelf_y: i32,
    shelf_w: i32,
    shelf_h: i32,
    tray_right_inner: i32,
};

fn clampI32FromI64(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// 轴对齐命中：`px ∈ [rx, rx+rw)`、`py ∈ [ry, ry+rh)`，边界用 i64 避免 Debug 下 i32 加法溢出。
fn pointInTrayRect(px: i32, py: i32, rx: i32, ry: i32, rw: i32, rh: i32) bool {
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    const x0 = @as(i64, rx);
    const y0 = @as(i64, ry);
    const w0 = @as(i64, rw);
    const h0 = @as(i64, rh);
    return pxi >= x0 and pyi >= y0 and pxi < x0 + w0 and pyi < y0 + h0;
}

pub fn layout(scr_w: i32, scr_h: i32, tb_h: i32) TrayLayout {
    const sw = @as(i64, scr_w);
    const sh = @as(i64, scr_h);
    const tb = @as(i64, tb_h);
    const tb_y = clampI32FromI64(sh - tb);
    const peek_w: i32 = TASKBAR_PEEK_STRIP_W;
    const peek64 = @as(i64, peek_w);
    const icon_s: u32 = 2;
    const icon_px: i32 = icons.getIconTotalSize(icon_s);
    const gap: i32 = 6;
    const icon_step: i32 = icon_px + gap;
    const step64 = @as(i64, icon_step);
    const ipx64 = @as(i64, icon_px);

    const tray_icons_y = clampI32FromI64(@as(i64, tb_y) + @divTrunc(@as(i64, tb_h) - ipx64, 2));
    const tray_right = sw - peek64 - 2;
    const tray_icons_w = step64 * 3 + 22;
    const tray_icons_x = clampI32FromI64(tray_right - tray_icons_w);

    const net_x = tray_icons_x;
    const vol_x = clampI32FromI64(@as(i64, tray_icons_x) + step64);
    const set_x = clampI32FromI64(@as(i64, tray_icons_x) + step64 * 2);
    const chevron_x = clampI32FromI64(@as(i64, set_x) + step64);
    const chevron_y = clampI32FromI64(@as(i64, tray_icons_y) + 2);
    const chevron_w: i32 = 14;
    const chevron_h: i32 = @max(0, icon_px - 4);

    const line_time = "12:00 PM";
    const line_date = "3/21/2026";
    const fb = @import("framebuffer.zig");
    const tw_time = fb.textWidth(line_time);
    const tw_date = fb.textWidth(line_date);
    const clock_block_w = @max(tw_time, tw_date);
    const clk_right = clampI32FromI64(@as(i64, tray_icons_x) - 10);
    const clk_x = clampI32FromI64(@as(i64, clk_right) - @as(i64, clock_block_w));
    const line_h: i32 = 14;
    const text_blk_h = line_h * 2 + 1;
    const clk_y = clampI32FromI64(@as(i64, tb_y) + @divTrunc(@as(i64, tb_h) - @as(i64, text_blk_h), 2));

    const tray_right_inner = clampI32FromI64(sw - peek64 - 2);
    const shelf_x = @max(4, clk_x - 8);
    const shelf_y = tb_y + 2;
    const shelf_h = tb_h - 4;
    const shelf_w = clampI32FromI64(@as(i64, tray_right_inner) - @as(i64, shelf_x));

    return .{
        .tb_y = tb_y,
        .tb_h = tb_h,
        .peek_w = peek_w,
        .tray_icons_x = tray_icons_x,
        .tray_icons_y = tray_icons_y,
        .icon_s = icon_s,
        .icon_px = icon_px,
        .icon_step = icon_step,
        .net_x = net_x,
        .vol_x = vol_x,
        .set_x = set_x,
        .chevron_x = chevron_x,
        .chevron_y = chevron_y,
        .chevron_w = chevron_w,
        .chevron_h = chevron_h,
        .clk_x = clk_x,
        .clk_y = clk_y,
        .shelf_x = shelf_x,
        .shelf_y = shelf_y,
        .shelf_w = shelf_w,
        .shelf_h = shelf_h,
        .tray_right_inner = tray_right_inner,
    };
}

pub const TrayHit = enum { none, network, volume, settings, chevron };

pub fn hitTest(px: i32, py: i32, scr_w: i32, scr_h: i32, tb_h: i32) TrayHit {
    const L = layout(scr_w, scr_h, tb_h);
    const pyi = @as(i64, py);
    const tby = @as(i64, L.tb_y);
    const tbhi = @as(i64, L.tb_h);
    if (pyi < tby or pyi >= tby + tbhi) return .none;

    if (pointInTrayRect(px, py, L.net_x, L.tray_icons_y, L.icon_px, L.icon_px))
        return .network;
    if (pointInTrayRect(px, py, L.vol_x, L.tray_icons_y, L.icon_px, L.icon_px))
        return .volume;
    if (pointInTrayRect(px, py, L.set_x, L.tray_icons_y, L.icon_px, L.icon_px))
        return .settings;
    if (pointInTrayRect(px, py, L.chevron_x, L.chevron_y, L.chevron_w, L.chevron_h))
        return .chevron;

    return .none;
}
