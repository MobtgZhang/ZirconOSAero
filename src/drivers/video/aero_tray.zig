//! Windows 7 Aero 任务栏右侧：通知区图标几何与命中（与 DWM 提交区分离，避免托盘像素重叠）。
//! 图标按「步进 = 位图宽度 + 间隙」排列，等价于 Wayland surface 独立 anchor，而非 DirectX 纹理拼合重叠。

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

pub fn layout(scr_w: i32, scr_h: i32, tb_h: i32) TrayLayout {
    const tb_y = scr_h - tb_h;
    const peek_w: i32 = TASKBAR_PEEK_STRIP_W;
    const icon_s: u32 = 2;
    const icon_px: i32 = icons.getIconTotalSize(icon_s);
    const gap: i32 = 6;
    const icon_step: i32 = icon_px + gap;

    const tray_icons_y = tb_y + @divTrunc(tb_h - icon_px, 2);
    const tray_right = scr_w - peek_w - 2;
    const tray_icons_w = icon_step * 3 + 22;
    const tray_icons_x = tray_right - tray_icons_w;

    const net_x = tray_icons_x;
    const vol_x = tray_icons_x + icon_step;
    const set_x = tray_icons_x + icon_step * 2;
    const chevron_x = set_x + icon_step;
    const chevron_y = tray_icons_y + 2;
    const chevron_w: i32 = 14;
    const chevron_h: i32 = icon_px - 4;

    const line_time = "12:00 PM";
    const line_date = "3/21/2026";
    const fb = @import("framebuffer.zig");
    const tw_time = fb.textWidth(line_time);
    const tw_date = fb.textWidth(line_date);
    const clock_block_w = @max(tw_time, tw_date);
    const clk_right = tray_icons_x - 10;
    const clk_x = clk_right - clock_block_w;
    const line_h: i32 = 14;
    const text_blk_h = line_h * 2 + 1;
    const clk_y = tb_y + @divTrunc(tb_h - text_blk_h, 2);

    const tray_right_inner = scr_w - peek_w - 2;
    const shelf_x = @max(4, clk_x - 8);
    const shelf_y = tb_y + 2;
    const shelf_h = tb_h - 4;
    const shelf_w = tray_right_inner - shelf_x;

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
    if (py < L.tb_y or py >= L.tb_y + L.tb_h) return .none;

    if (px >= L.net_x and px < L.net_x + L.icon_px and py >= L.tray_icons_y and py < L.tray_icons_y + L.icon_px)
        return .network;
    if (px >= L.vol_x and px < L.vol_x + L.icon_px and py >= L.tray_icons_y and py < L.tray_icons_y + L.icon_px)
        return .volume;
    if (px >= L.set_x and px < L.set_x + L.icon_px and py >= L.tray_icons_y and py < L.tray_icons_y + L.icon_px)
        return .settings;
    if (px >= L.chevron_x and px < L.chevron_x + L.chevron_w and py >= L.chevron_y and py < L.chevron_y + L.chevron_h)
        return .chevron;

    return .none;
}
