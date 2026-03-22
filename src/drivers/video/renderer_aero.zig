//! Aero（Windows 7 / NT 6.1）桌面渲染器
//!
//! 与 ideas/Win7B.md、ideas/win7Desktop.md 中的 DWM 数据流对齐（概念模型）：
//!
//! ```text
//! 壁纸 / 桌面 ──→ Shell 图标、小工具 ──→ 顶层窗（Explorer 等离屏面）──→ 任务栏
//!                        │
//!                        ▼
//!              display.present() → framebuffer.flip()（Aero 整帧提交，减轻撕裂）
//! ```
//!
//! 单进程内等价：`renderFrame` 顺序绘制背景 → 图标 → 小工具 → 壳窗口 → 任务栏；
//! 毛玻璃：`dwm.renderGlassEffect`（backdrop 采样区 boxBlur → blendTint → 高光边）。

const fb = @import("framebuffer.zig");
const theme = @import("theme.zig");
const dwm = @import("dwm.zig");
const icons = @import("icons.zig");
const startmenu = @import("startmenu.zig");
const dwm_comp = @import("dwm_compositor.zig");
const mat = @import("material.zig");
const display = @import("display.zig");
const shell_strings = @import("shell_strings.zig");
const aero_tray = @import("aero_tray.zig");
const rgb = theme.rgb;

pub fn initDwm() void {
    if (dwm.isInitialized()) return;
    // 与 display.initAeroDwm 相同参数（正常启动路径下 display 已 init，此处仅作兜底）。
    dwm.init(.{
        .glass_enabled = true,
        .glass_opacity = 210,
        .glass_blur_radius = 6,
        .glass_blur_passes = 2,
        .glass_saturation = 208,
        .glass_tint_color = 0x4068A0,
        .glass_tint_opacity = 62,
        .glass_taskbar_tint_opacity = 104,
        .specular_intensity = 42,
        .animation_enabled = true,
        .peek_enabled = true,
        .shadow_enabled = true,
        .vsync_compositor = true,
        .smooth_cursor = true,
        .cursor_lerp_factor = 255,
    });

    mat.init(.glass);
    mat.configureGlass(.{
        .blur_radius = 6,
        .blur_passes = 2,
        .tint_color = 0x4068A0,
        .tint_opacity = 62,
        .saturation = 208,
        .specular_intensity = 42,
    });

    dwm_comp.initAero(.{
        .glass_enabled = true,
        .glass_opacity = 210,
        .blur_radius = 6,
        .blur_passes = 2,
        .saturation = 208,
        .tint_color = 0x4068A0,
        .tint_opacity = 62,
        .specular_intensity = 42,
        .shadow_layers = 3,
        .shadow_offset = 6,
        .peek_enabled = true,
        .flip3d_enabled = true,
        .animation_speed = 250,
    });
}

pub fn render() void {
    theme.setTheme(.aero);
    if (!dwm.isInitialized()) initDwm();
    renderFrame();
}

pub fn renderFrame() void {
    if (!fb.isInitialized()) return;

    const w: i32 = @intCast(fb.getWidth());
    const h: i32 = @intCast(fb.getHeight());
    const t = theme.getActiveTheme();
    const tb_h = theme.getTaskbarHeight();

    const drag_state = display.getDragState();
    const any_drag = drag_state.explorer_active or drag_state.taskmgr_active;

    if (any_drag) {
        renderDragFrame(w, h, t, tb_h, drag_state);
    } else {
        renderFullFrame(w, h, t, tb_h);
    }
}

fn renderFullFrame(w: i32, h: i32, t: *const theme.ThemeColors, tb_h: i32) void {
    renderBackground(w, h);
    display.renderDesktopIcons(w, h, t);
    renderGadgetCpu(w, h, tb_h, t);
    renderExplorerWindow(w, h, t);
    display.renderTaskManagerWin(w, h, t);
    renderTaskbar(w, h, t, tb_h);

    if (startmenu.isVisible()) {
        startmenu.render(w, h);
    }
    display.renderContextMenu();
    display.renderCursorAt();
    display.incFrameCount();
    fb.markFullScreenDirty();
}

fn renderDragFrame(w: i32, h: i32, t: *const theme.ThemeColors, tb_h: i32, ds: display.DragState) void {
    patchDragBackground(w, h);

    display.renderDesktopIcons(w, h, t);

    if (ds.explorer_active) {
        renderExplorerWindowFast(w, h, t);
    } else {
        renderExplorerWindow(w, h, t);
    }
    display.renderTaskManagerWin(w, h, t);

    renderTaskbar(w, h, t, tb_h);
    fb.markDirtyRegion(0, h - tb_h, w, tb_h);

    if (startmenu.isVisible()) {
        startmenu.render(w, h);
    }
    display.renderContextMenu();

    display.renderCursorAt();
    display.incFrameCount();

    if (ds.explorer_active) {
        const wr = display.getWindowRect(w, h);
        const cur = display.ShellRect{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h };
        var u = display.rectUnion(ds.explorer_prev, cur);
        u = display.rectInflate(u, 14);
        u = display.rectClampToScreen(u, w, h);
        fb.markDirtyRegion(u.x, u.y, u.w, u.h);
    }
    if (ds.taskmgr_active) {
        const tm_pos = display.getTaskMgrPos();
        const cur = display.ShellRect{ .x = tm_pos.x, .y = tm_pos.y, .w = 320, .h = 260 };
        var u = display.rectUnion(ds.taskmgr_prev, cur);
        u = display.rectInflate(u, 14);
        u = display.rectClampToScreen(u, w, h);
        fb.markDirtyRegion(u.x, u.y, u.w, u.h);
    }
}

fn renderExplorerWindowFast(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors) void {
    const wr = display.getWindowRect(scr_w, scr_h);
    const win_w = wr.w;
    const win_h = wr.h;
    const win_x = wr.x;
    const win_y = wr.y;
    const aero_tb_h: i32 = display.AERO_TITLEBAR_H;

    fb.fillRect(win_x + 3, win_y + 3, win_w, win_h, rgb(0x30, 0x30, 0x30));
    fb.fillRect(win_x, win_y + aero_tb_h, win_w, win_h - aero_tb_h, t.window_bg);
    fb.drawGradientH(win_x, win_y, win_w, aero_tb_h, t.titlebar_active_left, t.titlebar_active_right);

    icons.drawThemedIcon(.computer, win_x + 6, win_y + 8, 1, .aero);
    fb.drawTextTransparent(win_x + 26, win_y + 6, "Computer", t.titlebar_text);
    fb.drawTextTransparent(win_x + 26, win_y + 22, "Local Disk (C:)", rgb(0xD8, 0xE8, 0xF8));

    display.drawAeroCaptionButtons(win_x, win_y, win_w, aero_tb_h, t);

    display.drawAeroWindowFrameBorder(win_x, win_y, win_w, win_h);
    renderExplorerContent(win_x + 2, win_y + aero_tb_h, win_w - 4, win_h - aero_tb_h - 2, t);
}

fn renderBackground(w: i32, h: i32) void {
    // 首帧仅渐变壁纸，避免大块 blendTint 拖长「首屏可见」时间；后续整屏重绘再画 Harmony。
    if (display.getPresentCount() == 0) {
        fb.drawGradientV(0, 0, w, h, rgb(0x08, 0x1E, 0x42), rgb(0x04, 0x12, 0x28));
    } else {
        renderHarmonyWallpaper(w, h);
    }
}

pub fn renderHarmonyWallpaper(w: i32, h: i32) void {
    fb.drawGradientV(0, 0, w, h, rgb(0x08, 0x1E, 0x42), rgb(0x04, 0x12, 0x28));
    fb.blendTintRect(@divTrunc(w, 4), @divTrunc(h, 10), @divTrunc(w, 2), @divTrunc(h * 2, 5), rgb(0x28, 0x58, 0x90), 20, 255);
    const mx = @divTrunc(w, 2);
    const my = @divTrunc(h * 2, 5);
    fb.blendTintRect(mx - 200, my - 130, 400, 300, rgb(0x38, 0x68, 0xA0), 16, 255);
    fb.blendTintRect(@divTrunc(w, 8), @divTrunc(h, 6), @divTrunc(w, 3), @divTrunc(h, 4), rgb(0x50, 0x78, 0xA8), 12, 255);
    const vstrip: i32 = 28;
    fb.blendTintRect(0, 0, w, vstrip, rgb(0x00, 0x04, 0x12), 38, 255);
    fb.blendTintRect(0, h - vstrip, w, vstrip, rgb(0x00, 0x02, 0x0A), 48, 255);
    fb.blendTintRect(0, 0, vstrip, h, rgb(0x00, 0x04, 0x10), 32, 255);
    fb.blendTintRect(w - vstrip, 0, vstrip, h, rgb(0x00, 0x04, 0x10), 32, 255);
}

fn renderGadgetCpu(w: i32, h: i32, tb_h: i32, t: *const theme.ThemeColors) void {
    _ = tb_h;
    const cx = w - 110;
    const cy = @divTrunc(h, 4);
    const r: i32 = 46;
    const bx = cx - r;
    const by = cy - r;
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(bx, by, r * 2, r * 2, dwm.getConfig().glass_tint_color, .panel);
    } else {
        fb.fillRoundedRect(bx, by, r * 2, r * 2, r, rgb(0x20, 0x34, 0x50));
    }
    fb.drawTextTransparent(bx + 30, by + 16, "23%", t.icon_text);
    fb.drawTextTransparent(bx + 26, by + 32, "0K/s", rgb(0xAA, 0xCC, 0xEE));
}

fn renderTaskbar(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors, tb_h: i32) void {
    const tb_y = scr_h - tb_h;
    // 拖动时走 Win7 合成器「交互态」路径：任务栏避免对整宽做毛玻璃采样，仅渐变填充（类似 DirectComposition 的 cached visual）。
    const drag_fast = display.isDragging();
    if (drag_fast) {
        fb.drawGradientV(0, tb_y, scr_w, tb_h, t.taskbar_top, t.taskbar_bottom);
    } else if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(0, tb_y, scr_w, tb_h, rgb(0x28, 0x40, 0x60), .taskbar);
    } else {
        fb.drawGradientV(0, tb_y, scr_w, tb_h, t.taskbar_top, t.taskbar_bottom);
    }
    fb.drawHLine(0, tb_y, scr_w, rgb(0x58, 0x78, 0xA8));

    const peek_w: i32 = 12;
    const icon_s: u32 = 2;
    const icon_px: i32 = icons.getIconTotalSize(icon_s);
    const icon_s_apps: u32 = 1;
    const pill_h: i32 = 20;

    const orb_x: i32 = 4;
    const orb_y = tb_y + @divTrunc(tb_h - 36, 2);
    const orb_sz: i32 = 36;
    fb.fillRoundedRect(orb_x, orb_y, orb_sz, orb_sz, 18, rgb(0x24, 0x4A, 0x80));
    fb.drawGradientV(orb_x + 1, orb_y + 1, orb_sz - 2, @divTrunc(orb_sz - 2, 2), rgb(0x50, 0x82, 0xC0), rgb(0x28, 0x50, 0x88));
    fb.blendTintRect(orb_x + 6, orb_y + 4, orb_sz - 12, 8, rgb(0xE8, 0xF4, 0xFF), 55, 255);
    display.renderZirconLogo(orb_x + 11, orb_y + 11);

    const ql_ids = [_]icons.IconId{ .browser, .terminal, .documents };
    var qx: i32 = orb_x + orb_sz + 6;
    const ql_y = tb_y + @divTrunc(tb_h - icon_px, 2);
    for (ql_ids) |iid| {
        icons.drawThemedIcon(iid, qx, ql_y, icon_s, .aero);
        qx += icon_px + 4;
    }
    fb.drawVLine(qx + 2, tb_y + 6, tb_h - 12, rgb(0x50, 0x70, 0x90));

    const app_items = [_]struct { id: icons.IconId, text: []const u8, active: bool }{
        .{ .id = .computer, .text = "Computer", .active = true },
        .{ .id = .computer, .text = "Core", .active = false },
        .{ .id = .terminal, .text = "CMD", .active = false },
    };
    var ax = qx + 8;
    const ay = tb_y + @divTrunc(tb_h - pill_h, 2);
    for (app_items) |app| {
        const bw: i32 = 58;
        if (app.active) {
            fb.fillRoundedRect(ax, ay, bw, pill_h, 3, rgb(0x50, 0x80, 0xB8));
            fb.fillRect(ax + 2, ay + 2, bw - 4, 8, rgb(0x78, 0xA8, 0xD8));
            fb.drawRect(ax, ay, bw, pill_h, rgb(0x90, 0xB8, 0xE8));
        } else {
            fb.fillRoundedRect(ax, ay, bw, pill_h, 3, rgb(0x30, 0x48, 0x68));
            fb.drawRect(ax, ay, bw, pill_h, rgb(0x48, 0x60, 0x80));
        }
        icons.drawThemedIcon(app.id, ax + 3, ay + 3, icon_s_apps, .aero);
        fb.drawTextTransparent(ax + 17, ay + 5, app.text, rgb(0xFF, 0xFF, 0xFF));
        ax += bw + 4;
    }

    const tray = aero_tray.layout(scr_w, scr_h, tb_h);
    if (tray.shelf_w > 4 and tray.shelf_h > 4) {
        fb.fillRoundedRect(tray.shelf_x, tray.shelf_y, tray.shelf_w, tray.shelf_h, 5, rgb(0x10, 0x1C, 0x30));
        fb.blendTintRect(tray.shelf_x, tray.shelf_y, tray.shelf_w, tray.shelf_h, rgb(0x50, 0x70, 0x98), 22, 100);
        fb.drawRect(tray.shelf_x, tray.shelf_y, tray.shelf_w, tray.shelf_h, rgb(0x38, 0x50, 0x68));
    }
    icons.drawThemedIcon(.network, tray.net_x, tray.tray_icons_y, tray.icon_s, .aero);
    icons.drawThemedIcon(.browser, tray.vol_x, tray.tray_icons_y, tray.icon_s, .aero);
    icons.drawThemedIcon(.settings, tray.set_x, tray.tray_icons_y, tray.icon_s, .aero);
    fb.drawTextTransparent(tray.chevron_x, tray.chevron_y, "^", rgb(0xB0, 0xC8, 0xE8));

    const line_h_clk: i32 = 14;
    const line_time = "12:00 PM";
    const line_date = "3/21/2026";
    fb.drawTextTransparent(tray.clk_x, tray.clk_y, line_time, t.clock_text);
    fb.drawTextTransparent(tray.clk_x, tray.clk_y + line_h_clk + 1, line_date, rgb(0xC8, 0xD8, 0xE8));

    display.renderAeroTrayFlyout(scr_w, scr_h);

    fb.drawGradientV(scr_w - peek_w, tb_y, peek_w, tb_h, rgb(0x50, 0x70, 0x90), rgb(0x28, 0x40, 0x60));
    fb.drawVLine(scr_w - peek_w, tb_y, tb_h, rgb(0x70, 0x90, 0xB0));
}

fn renderExplorerWindow(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors) void {
    const wr = display.getWindowRect(scr_w, scr_h);
    const win_w = wr.w;
    const win_h = wr.h;
    const win_x = wr.x;
    const win_y = wr.y;
    const aero_tb_h: i32 = display.AERO_TITLEBAR_H;

    // 多层阴影对整窗做 blendTint，首帧与毛玻璃快速路径一并推迟。
    if (dwm.isShadowEnabled() and display.getPresentCount() > 0) {
        mat.renderShadow(win_x, win_y, win_w, win_h, 8, 4);
    } else {
        fb.fillRect(win_x + 3, win_y + 3, win_w, win_h, rgb(0x30, 0x30, 0x30));
    }

    fb.fillRect(win_x, win_y + aero_tb_h, win_w, win_h - aero_tb_h, t.window_bg);

    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(win_x, win_y, win_w, aero_tb_h, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, win_w, aero_tb_h, t.titlebar_active_left, t.titlebar_active_right);
    }

    icons.drawThemedIcon(.computer, win_x + 6, win_y + 8, 1, .aero);
    fb.drawTextTransparent(win_x + 26, win_y + 6, "Computer", t.titlebar_text);
    fb.drawTextTransparent(win_x + 26, win_y + 22, "Local Disk (C:)", rgb(0xD8, 0xE8, 0xF8));

    display.drawAeroCaptionButtons(win_x, win_y, win_w, aero_tb_h, t);

    display.drawAeroWindowFrameBorder(win_x, win_y, win_w, win_h);
    renderExplorerContent(win_x + 2, win_y + aero_tb_h, win_w - 4, win_h - aero_tb_h - 2, t);
}

fn renderExplorerContent(x: i32, y: i32, w: i32, h: i32, t: *const theme.ThemeColors) void {
    _ = t;
    const cmd_h: i32 = display.AERO_EXPLORER_CMD_H;
    const addr_h: i32 = display.AERO_EXPLORER_ADDR_H;
    fb.drawGradientH(x, y, w, cmd_h, rgb(0xF2, 0xF4, 0xF8), rgb(0xE4, 0xE8, 0xF0));
    fb.drawHLine(x, y + cmd_h, w, rgb(0xB8, 0xC4, 0xD4));
    const cmds = [_][]const u8{ "Organize", "Open", "▼" };
    const cmd_ty = y + @divTrunc(cmd_h - 14, 2);
    var bx: i32 = x + 8;
    for (cmds, 0..cmds.len) |cmd, ci| {
        const tc: u32 = if (ci == 2) rgb(0x40, 0x40, 0x40) else rgb(0x00, 0x51, 0x9E);
        fb.drawTextTransparent(bx, cmd_ty, cmd, tc);
        bx += fb.textWidth(cmd) + @as(i32, if (ci == 1) 16 else 12);
    }
    const div_x = bx + 4;
    fb.drawVLine(div_x, y + 6, cmd_h - 12, rgb(0xC8, 0xD0, 0xDC));
    const inc = "Include in library";
    const share = "Share with";
    const inc_w = fb.textWidth(inc);
    const share_w = fb.textWidth(share);
    const link_gap: i32 = 18;
    const lx: i32 = div_x + 8;
    const cmd_right = x + w - 6;
    if (lx + inc_w + link_gap + share_w <= cmd_right) {
        fb.drawTextTransparent(lx, cmd_ty, inc, rgb(0x00, 0x51, 0x9E));
        fb.drawTextTransparent(lx + inc_w + link_gap, cmd_ty, share, rgb(0x00, 0x51, 0x9E));
    } else if (lx + inc_w <= cmd_right) {
        fb.drawTextTransparent(lx, cmd_ty, inc, rgb(0x00, 0x51, 0x9E));
    }

    const addr_y = y + cmd_h + 1;
    const go_btn_w: i32 = 40;
    const addr_field_x: i32 = x + 52;
    const go_x = x + w - go_btn_w - 6;
    const addr_field_w = @max(64, go_x - 4 - addr_field_x);
    fb.fillRect(x, addr_y, w, addr_h, rgb(0xF8, 0xF9, 0xFC));
    fb.drawHLine(x, addr_y + addr_h, w, rgb(0xC0, 0xC8, 0xD4));
    fb.drawTextTransparent(x + 8, addr_y + @divTrunc(addr_h - 14, 2), "Address", rgb(0x50, 0x58, 0x60));
    fb.fillRect(addr_field_x, addr_y + 3, addr_field_w, 20, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(addr_field_x, addr_y + 3, addr_field_w, 20, rgb(0x9C, 0xA8, 0xB8));
    fb.drawTextTransparent(addr_field_x + 6, addr_y + @divTrunc(addr_h - 14, 2), "Computer ▸ Local Disk (C:)", rgb(0x00, 0x00, 0x00));
    fb.fillRoundedRect(go_x, addr_y + 4, go_btn_w, 18, 2, rgb(0xE8, 0xEC, 0xF2));
    fb.drawTextTransparent(go_x + @divTrunc(go_btn_w - fb.textWidth("Go"), 2), addr_y + @divTrunc(addr_h - 14, 2), "Go", rgb(0x00, 0x00, 0x00));

    const body_y = addr_y + addr_h;
    const status_h: i32 = 22;
    const body_h = h - cmd_h - 1 - addr_h - status_h - 1;
    if (body_h <= 10) return;

    const nav_w: i32 = @min(160, @max(100, @divTrunc(w, 4)));
    const nav_hdr_h: i32 = @min(24, body_h);
    fb.drawGradientV(x, body_y, nav_w, nav_hdr_h, rgb(0xF0, 0xF4, 0xFA), rgb(0xE8, 0xEC, 0xF4));
    fb.fillRect(x, body_y + nav_hdr_h, nav_w, body_h - nav_hdr_h, rgb(0xFC, 0xFC, 0xFE));
    fb.drawVLine(x + nav_w, body_y, body_h, rgb(0xC8, 0xD0, 0xD8));

    const nav_items = [_]struct { label: []const u8, indent: i32, sel: bool }{
        .{ .label = "Favorites", .indent = 0, .sel = false },
        .{ .label = "  Desktop", .indent = 10, .sel = false },
        .{ .label = "  Downloads", .indent = 10, .sel = false },
        .{ .label = "Libraries", .indent = 0, .sel = false },
        .{ .label = "Computer", .indent = 0, .sel = true },
        .{ .label = "  C:\\", .indent = 10, .sel = false },
        .{ .label = "  D:\\", .indent = 10, .sel = false },
        .{ .label = "Network", .indent = 0, .sel = false },
    };
    var ny: i32 = body_y + 4;
    for (nav_items) |item| {
        if (ny + 18 > body_y + body_h) break;
        if (item.sel) {
            fb.fillRect(x + 2, ny, nav_w - 4, 18, rgb(0xD8, 0xE8, 0xF8));
            fb.drawRect(x + 2, ny, nav_w - 4, 18, rgb(0xA8, 0xC8, 0xE0));
        }
        const tc: u32 = if (item.sel) rgb(0x00, 0x3C, 0x80) else rgb(0x1A, 0x1A, 0x1A);
        fb.drawTextTransparent(x + 8 + item.indent, ny + 2, item.label, tc);
        ny += 20;
    }

    const list_x = x + nav_w + 1;
    const list_w = w - nav_w - 1;
    fb.fillRect(list_x, body_y, list_w, body_h, rgb(0xFF, 0xFF, 0xFF));

    fb.fillRect(list_x, body_y, list_w, 20, rgb(0xF5, 0xF5, 0xF8));
    fb.drawHLine(list_x, body_y + 20, list_w, rgb(0xD0, 0xD0, 0xD5));
    const hdr_y = body_y + 3;
    const col_date_x = list_x + @max(160, list_w - 200);
    const col_size_x = list_x + list_w - 56;
    const hdr_extra = col_date_x + fb.textWidth("Date modified") + 8 < col_size_x;
    fb.drawTextTransparent(list_x + 28, hdr_y, "Name", rgb(0x40, 0x40, 0x40));
    if (hdr_extra) {
        fb.drawTextTransparent(col_date_x, hdr_y, "Date modified", rgb(0x40, 0x40, 0x40));
        fb.drawTextTransparent(col_size_x, hdr_y, "Size", rgb(0x40, 0x40, 0x40));
    }

    const entries = [_]struct { name: []const u8, date: []const u8, size: []const u8, icon: icons.IconId }{
        .{ .name = "Users", .date = "2026/01/15", .size = "", .icon = .documents },
        .{ .name = "Program Files", .date = "2026/03/20", .size = "", .icon = .documents },
        .{ .name = "Windows", .date = "2026/02/10", .size = "", .icon = .documents },
        .{ .name = "PerfLogs", .date = "2026/01/01", .size = "", .icon = .documents },
        .{ .name = "boot.ini", .date = "2026/01/01", .size = "1 KB", .icon = .computer },
        .{ .name = "pagefile.sys", .date = "2026/03/21", .size = "2 GB", .icon = .computer },
    };
    var ey: i32 = body_y + 22;
    for (entries, 0..) |entry, i| {
        if (ey + 20 > body_y + body_h) break;
        if (i % 2 == 1) {
            fb.fillRect(list_x, ey, list_w - 16, 20, rgb(0xF5, 0xF8, 0xFC));
        }
        const row_text_y = ey + 4;
        icons.drawThemedIcon(entry.icon, list_x + 6, ey + 2, 1, .aero);
        fb.drawTextTransparent(list_x + 28, row_text_y, entry.name, rgb(0x00, 0x00, 0x00));
        if (hdr_extra) {
            fb.drawTextTransparent(col_date_x, row_text_y, entry.date, rgb(0x60, 0x60, 0x60));
            fb.drawTextTransparent(col_size_x, row_text_y, entry.size, rgb(0x60, 0x60, 0x60));
        }
        ey += 20;
    }

    const sb_x = list_x + list_w - 16;
    fb.fillRect(sb_x, body_y + 21, 16, body_h - 21, rgb(0xF0, 0xF0, 0xF2));
    fb.drawVLine(sb_x, body_y + 21, body_h - 21, rgb(0xD0, 0xD0, 0xD5));
    fb.fillRect(sb_x + 3, body_y + 24, 10, 40, rgb(0xC0, 0xC4, 0xCC));

    const status_y = y + h - status_h;
    fb.fillRect(x, status_y, w, status_h, rgb(0xF0, 0xF0, 0xF2));
    fb.drawHLine(x, status_y, w, rgb(0xD0, 0xD0, 0xD5));
    fb.drawTextTransparent(x + 8, status_y + 3, "6 items | Computer | Aero DWM", rgb(0x40, 0x40, 0x40));
}

fn patchDragBackground(scr_w: i32, scr_h: i32) void {
    const pad: i32 = 10;
    const drag_state = display.getDragState();
    if (drag_state.explorer_active) {
        const wr = display.getWindowRect(scr_w, scr_h);
        const cur = display.ShellRect{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h };
        var u = display.rectUnion(drag_state.explorer_prev, cur);
        u = display.rectInflate(u, pad);
        u = display.rectClampToScreen(u, scr_w, scr_h);
        if (u.w > 0 and u.h > 0) {
            patchHarmonyRegion(scr_w, scr_h, u.x, u.y, u.w, u.h);
        }
        display.setExplorerDragPrev(cur);
    }
    if (drag_state.taskmgr_active) {
        const tm_pos = display.getTaskMgrPos();
        const cur = display.ShellRect{ .x = tm_pos.x, .y = tm_pos.y, .w = 320, .h = 260 };
        var u = display.rectUnion(drag_state.taskmgr_prev, cur);
        u = display.rectInflate(u, pad);
        u = display.rectClampToScreen(u, scr_w, scr_h);
        if (u.w > 0 and u.h > 0) {
            patchHarmonyRegion(scr_w, scr_h, u.x, u.y, u.w, u.h);
        }
        display.setTaskMgrDragPrev(cur);
    }
}

fn patchHarmonyRegion(scr_w: i32, scr_h: i32, rx: i32, ry: i32, rw: i32, rh: i32) void {
    const topc = rgb(0x08, 0x1E, 0x42);
    const botc = rgb(0x04, 0x12, 0x28);
    display.patchVerticalGradientRegion(scr_w, scr_h, rx, ry, rw, rh, topc, botc);
    var r = display.ShellRect{ .x = rx, .y = ry, .w = rw, .h = rh };
    r = display.rectClampToScreen(r, scr_w, scr_h);
    if (r.w <= 0 or r.h <= 0) return;
    const bloom1 = display.ShellRect{ .x = @divTrunc(scr_w, 4), .y = @divTrunc(scr_h, 10), .w = @divTrunc(scr_w, 2), .h = @divTrunc(scr_h * 2, 5) };
    if (display.rectIntersection(r, bloom1)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x28, 0x58, 0x90), 20, 255);
    }
    const mx = @divTrunc(scr_w, 2);
    const my = @divTrunc(scr_h * 2, 5);
    const bloom2 = display.ShellRect{ .x = mx - 200, .y = my - 130, .w = 400, .h = 300 };
    if (display.rectIntersection(r, bloom2)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x38, 0x68, 0xA0), 16, 255);
    }
    const bloom3 = display.ShellRect{ .x = @divTrunc(scr_w, 8), .y = @divTrunc(scr_h, 6), .w = @divTrunc(scr_w, 3), .h = @divTrunc(scr_h, 4) };
    if (display.rectIntersection(r, bloom3)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x50, 0x78, 0xA8), 12, 255);
    }
    const vstrip: i32 = 28;
    const vig_top = display.ShellRect{ .x = 0, .y = 0, .w = scr_w, .h = vstrip };
    if (display.rectIntersection(r, vig_top)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x00, 0x04, 0x12), 38, 255);
    }
    const vig_bot = display.ShellRect{ .x = 0, .y = scr_h - vstrip, .w = scr_w, .h = vstrip };
    if (display.rectIntersection(r, vig_bot)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x00, 0x02, 0x0A), 48, 255);
    }
    const vig_left = display.ShellRect{ .x = 0, .y = 0, .w = vstrip, .h = scr_h };
    if (display.rectIntersection(r, vig_left)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x00, 0x04, 0x10), 32, 255);
    }
    const vig_right = display.ShellRect{ .x = scr_w - vstrip, .y = 0, .w = vstrip, .h = scr_h };
    if (display.rectIntersection(r, vig_right)) |is| {
        fb.blendTintRect(is.x, is.y, is.w, is.h, rgb(0x00, 0x04, 0x10), 32, 255);
    }
}
