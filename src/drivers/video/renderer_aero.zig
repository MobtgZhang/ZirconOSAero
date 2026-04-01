//! Aero（Windows 7 / NT 6.1）桌面渲染器
//!
//! 与 docs/cn/DesktopManagerSpec.md 及 Microsoft Learn「Desktop Window Manager」数据流对齐（概念模型）：
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
const builtin_apps = @import("builtin_apps.zig");
const shell_strings = @import("shell_strings.zig");
const wallpaper_bitmap = @import("wallpaper_bitmap.zig");
const rgb = theme.rgb;

pub fn initDwm() void {
    if (dwm.isInitialized()) return;
    // 与 display.initAeroDwm 相同参数（`nt61_aero_defaults` 单一源；正常启动路径下 display 已 init）。
    const cfg = dwm.DwmConfig{};
    dwm.init(cfg);

    mat.init(.glass);
    mat.configureGlass(.{
        .blur_radius = cfg.glass_blur_radius,
        .blur_passes = cfg.glass_blur_passes,
        .tint_color = cfg.glass_tint_color,
        .tint_opacity = cfg.glass_tint_opacity,
        .saturation = cfg.glass_saturation,
        .specular_intensity = cfg.specular_intensity,
    });

    dwm_comp.initAero(.{});
}

pub fn render() void {
    theme.setTheme(.aero);
    if (!dwm.isInitialized()) initDwm();
    renderFrameEx(true);
}

/// `draw_cursor=false` 时由 `display` 软件光标层在场景合成后单独叠加（save-under 快速路径）。
pub fn renderFrameEx(draw_cursor: bool) void {
    if (!fb.isInitialized()) return;

    const w: i32 = @intCast(fb.getWidth());
    const h: i32 = @intCast(fb.getHeight());
    const t = theme.getActiveTheme();
    const tb_h = theme.getTaskbarHeight();

    const drag_state = display.getDragState();
    const any_drag = drag_state.explorer_active or drag_state.taskmgr_active or drag_state.builtin_active;

    if (any_drag) {
        renderDragFrame(w, h, t, tb_h, drag_state, draw_cursor);
    } else {
        renderFullFrame(w, h, t, tb_h, draw_cursor);
    }
}

pub fn renderFrame() void {
    renderFrameEx(true);
}

/// 仅 Explorer + 任务管理器标题栏带（毛玻璃/渐变 + 三键热态），供 `display.renderDesktopFrameEx` 局部刷新；不画壁纸与窗体客户区。
/// 当前壁纸预设是否支持「开始菜单脏区」局部修补（与 `patchHarmonyWallpaperRegion` 一致）。
pub fn startMenuRepaintCanPatchWallpaper() bool {
    return true;
}

/// 开始菜单悬停变化时：仅修补壁纸条带 + 与脏区相交的壳层，再重画菜单（避免整帧 `renderFullFrame`）。
pub fn redrawStartMenuRegionOnly(w: i32, h: i32, t: *const theme.ThemeColors, tb_h: i32) void {
    if (!startmenu.isVisible()) return;

    const mb = startmenu.getPaintBounds(w, h);
    var dirty = display.ShellRect{ .x = mb.x, .y = mb.y, .w = mb.w, .h = mb.h };
    dirty = display.rectInflate(dirty, 8);
    dirty = display.rectClampToScreen(dirty, w, h);
    if (dirty.w <= 0 or dirty.h <= 0) return;

    display.patchHarmonyWallpaperRegion(w, h, dirty.x, dirty.y, dirty.w, dirty.h);

    const ib = display.desktopIconStripBounds(w, h);
    if (display.rectsOverlap(dirty, ib)) {
        display.renderDesktopIcons(w, h, t);
        dirty = display.rectUnion(dirty, ib);
    }

    const wr = display.getWindowRect(w, h);
    const win_r = display.ShellRect{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h };
    if (display.rectsOverlap(dirty, win_r)) {
        renderExplorerWindow(w, h, t);
        dirty = display.rectUnion(dirty, win_r);
    }

    display.initTaskMgrPosition(w, h);
    const tm = display.getTaskMgrPos();
    const tm_sz = display.getTaskMgrSize();
    const tm_r = display.ShellRect{ .x = tm.x, .y = tm.y, .w = tm_sz.w, .h = tm_sz.h };
    if (display.rectsOverlap(dirty, tm_r)) {
        display.renderTaskManagerWin(w, h, t);
        dirty = display.rectUnion(dirty, tm_r);
    }

    if (builtin_apps.anyWindowOpen()) {
        const bu_b = builtin_apps.openSlotsBoundsUnion();
        const bu = display.ShellRect{ .x = bu_b.x, .y = bu_b.y, .w = bu_b.w, .h = bu_b.h };
        if (bu.w > 0 and bu.h > 0 and display.rectsOverlap(dirty, bu)) {
            builtin_apps.renderShellHostedApps(w, h, t, .normal);
            dirty = display.rectUnion(dirty, bu);
        }
    }

    const tb_r = display.taskbarBoundsRect(w, h);
    if (display.rectsOverlap(dirty, tb_r)) {
        renderTaskbar(w, h, t, tb_h);
        dirty = display.rectUnion(dirty, tb_r);
    }

    startmenu.render(w, h);
    display.renderContextMenu();

    dirty = display.rectClampToScreen(dirty, w, h);
    if (dirty.w > 0 and dirty.h > 0) {
        fb.markDirtyRegion(dirty.x, dirty.y, dirty.w, dirty.h);
    }
    display.incFrameCount();
}

pub fn redrawCaptionBandsOnly() void {
    if (!fb.isInitialized()) return;
    theme.setTheme(.aero);
    if (!dwm.isInitialized()) initDwm();

    const scr_w: i32 = @intCast(fb.getWidth());
    const scr_h: i32 = @intCast(fb.getHeight());
    const t = theme.getActiveTheme();
    const aero_tb_h: i32 = display.AERO_TITLEBAR_H;

    const wr = display.getWindowRect(scr_w, scr_h);
    if (wr.w > 0) {
        redrawExplorerCaptionBand(wr.x, wr.y, wr.w, aero_tb_h, t);
    }

    display.initTaskMgrPosition(scr_w, scr_h);
    const tm_sz = display.getTaskMgrSize();
    const tm_w = tm_sz.w;
    const tm_pos = display.getTaskMgrPos();
    if (!display.isTaskMgrWindowMinimized()) {
        redrawTaskMgrCaptionBand(tm_pos.x, tm_pos.y, tm_w, aero_tb_h, t);
    }

    var dirty = display.ShellRect{ .x = wr.x, .y = wr.y, .w = wr.w, .h = if (wr.w > 0) aero_tb_h else 0 };
    if (!display.isTaskMgrWindowMinimized()) {
        const tm_dirty = display.ShellRect{ .x = tm_pos.x, .y = tm_pos.y, .w = tm_w, .h = aero_tb_h };
        dirty = display.rectUnion(dirty, tm_dirty);
    }

    if (display.isContextMenuVisible()) {
        display.renderContextMenu();
        dirty = display.rectUnion(dirty, display.getContextMenuPaintRect());
    }

    const u = display.rectClampToScreen(dirty, scr_w, scr_h);
    if (u.w > 0 and u.h > 0) {
        fb.markDirtyRegion(u.x, u.y, u.w, u.h);
    }
    display.incFrameCount();
}

fn redrawExplorerCaptionBand(win_x: i32, win_y: i32, win_w: i32, aero_tb_h: i32, t: *const theme.ThemeColors) void {
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(win_x, win_y, win_w, aero_tb_h, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, win_w, aero_tb_h, t.titlebar_active_left, t.titlebar_active_right);
    }
    drawExplorerTitlebarChrome(win_x, win_y, aero_tb_h, t);
    display.drawAeroCaptionButtons(win_x, win_y, win_w, aero_tb_h, t, display.getExplorerCaptionBtnHover());
}

fn redrawTaskMgrCaptionBand(win_x: i32, win_y: i32, tm_w: i32, th: i32, t: *const theme.ThemeColors) void {
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(win_x, win_y, tm_w, th, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, tm_w, th, t.titlebar_active_left, t.titlebar_active_right);
    }
    display.drawAeroCaptionButtons(win_x, win_y, tm_w, th, t, display.getTaskMgrCaptionBtnHover());
    fb.drawTextTransparent(win_x + 8, win_y + 5, "Zircon Task Manager", t.titlebar_text);
}

fn renderFullFrame(w: i32, h: i32, t: *const theme.ThemeColors, tb_h: i32, draw_cursor: bool) void {
    const panic_ctx = @import("../../rtl/panic_context.zig");
    panic_ctx.setPhase(0x0002_0080);
    renderBackground(w, h);
    panic_ctx.setPhase(0x0002_0081);
    display.renderDesktopIcons(w, h, t);
    panic_ctx.setPhase(0x0002_0082);
    if (!display.isExplorerWindowMinimized()) {
        renderExplorerWindow(w, h, t);
    }
    panic_ctx.setPhase(0x0002_0083);
    if (!display.isTaskMgrWindowMinimized()) {
        display.renderTaskManagerWin(w, h, t);
    }
    panic_ctx.setPhase(0x0002_0084);
    builtin_apps.renderShellHostedApps(w, h, t, .normal);
    panic_ctx.setPhase(0x0002_0085);
    renderTaskbar(w, h, t, tb_h);

    if (startmenu.isVisible()) {
        panic_ctx.setPhase(0x0002_0086);
        startmenu.render(w, h);
    }
    panic_ctx.setPhase(0x0002_0087);
    display.renderContextMenu();
    if (draw_cursor) {
        display.renderCursorAt();
    }
    display.incFrameCount();
    fb.markFullScreenDirty();
}

fn dragFrameDirtyUnion(scr_w: i32, scr_h: i32, ds: display.DragState, pad: i32) ?display.ShellRect {
    var acc: ?display.ShellRect = null;
    if (ds.explorer_active) {
        const wr = display.getWindowRect(scr_w, scr_h);
        const cur = display.ShellRect{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h };
        var u = display.rectUnion(ds.explorer_prev, cur);
        u = display.rectInflate(u, pad);
        u = display.rectClampToScreen(u, scr_w, scr_h);
        acc = u;
    }
    if (ds.taskmgr_active) {
        const tm_pos = display.getTaskMgrPos();
        const tm_sz = display.getTaskMgrSize();
        const cur = display.ShellRect{ .x = tm_pos.x, .y = tm_pos.y, .w = tm_sz.w, .h = tm_sz.h };
        var u = display.rectUnion(ds.taskmgr_prev, cur);
        u = display.rectInflate(u, pad);
        u = display.rectClampToScreen(u, scr_w, scr_h);
        acc = if (acc) |a| display.rectUnion(a, u) else u;
    }
    if (ds.builtin_active) {
        if (builtin_apps.topDraggedWindowRect()) |br| {
            const cur = display.ShellRect{ .x = br.x, .y = br.y, .w = br.w, .h = br.h };
            var u = display.rectUnion(ds.builtin_prev, cur);
            u = display.rectInflate(u, pad);
            u = display.rectClampToScreen(u, scr_w, scr_h);
            acc = if (acc) |a| display.rectUnion(a, u) else u;
        }
    }
    return acc;
}

fn renderDragFrame(w: i32, h: i32, t: *const theme.ThemeColors, tb_h: i32, ds: display.DragState, draw_cursor: bool) void {
    // 略大于拖影/伪阴影外扩，避免局部重绘与 `paint_icons`/`paint_taskbar` 判定漏区。
    const dirty_pad: i32 = 22;
    const dirty_u = dragFrameDirtyUnion(w, h, ds, dirty_pad);

    patchDragBackground(w, h);

    const icon_b = display.desktopIconStripBounds(w, h);
    const tb_b = display.taskbarBoundsRect(w, h);
    const paint_icons = if (dirty_u) |du| display.rectsOverlap(du, icon_b) else true;
    const paint_taskbar = if (dirty_u) |du| display.rectsOverlap(du, tb_b) else true;

    if (paint_icons) {
        display.renderDesktopIcons(w, h, t);
    }

    if (ds.explorer_active) {
        renderExplorerWindowDragLight(w, h, t);
    } else {
        renderExplorerWindow(w, h, t);
    }
    if (ds.taskmgr_active) {
        display.renderTaskManagerWinDragLight(w, h, t);
    } else {
        display.renderTaskManagerWin(w, h, t);
    }

    if (ds.builtin_active) {
        builtin_apps.renderShellHostedApps(w, h, t, .drag_light);
    } else {
        builtin_apps.renderShellHostedApps(w, h, t, .normal);
    }

    if (paint_taskbar) {
        renderTaskbar(w, h, t, tb_h);
        const tb_y = display.clampI32FromI64(@as(i64, h) - @as(i64, tb_h));
        fb.markDirtyRegion(0, tb_y, w, tb_h);
    }

    if (startmenu.isVisible()) {
        startmenu.render(w, h);
    }
    display.renderContextMenu();

    if (draw_cursor) {
        display.renderCursorAt();
    }
    display.incFrameCount();

    if (ds.explorer_active) {
        const wr = display.getWindowRect(w, h);
        const cur = display.ShellRect{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h };
        var u = display.rectUnion(ds.explorer_prev, cur);
        u = display.rectInflate(u, dirty_pad);
        u = display.rectClampToScreen(u, w, h);
        fb.markDirtyRegion(u.x, u.y, u.w, u.h);
    }
    if (ds.taskmgr_active) {
        const tm_pos = display.getTaskMgrPos();
        const tm_sz = display.getTaskMgrSize();
        const cur = display.ShellRect{ .x = tm_pos.x, .y = tm_pos.y, .w = tm_sz.w, .h = tm_sz.h };
        var u = display.rectUnion(ds.taskmgr_prev, cur);
        u = display.rectInflate(u, dirty_pad);
        u = display.rectClampToScreen(u, w, h);
        fb.markDirtyRegion(u.x, u.y, u.w, u.h);
    }
    if (ds.builtin_active) {
        if (builtin_apps.topDraggedWindowRect()) |br| {
            const cur = display.ShellRect{ .x = br.x, .y = br.y, .w = br.w, .h = br.h };
            var u = display.rectUnion(ds.builtin_prev, cur);
            u = display.rectInflate(u, dirty_pad);
            u = display.rectClampToScreen(u, w, h);
            fb.markDirtyRegion(u.x, u.y, u.w, u.h);
        }
    }

    display.markCursorMotionDirtyRegions();
}

/// 拖动态：仅标题栏玻璃 + 窗框 + 单色客户区，避免每帧重绘导航/列表。
fn renderExplorerWindowDragLight(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors) void {
    const wr = display.getWindowRect(scr_w, scr_h);
    const win_w = wr.w;
    const win_h = wr.h;
    const win_x = wr.x;
    const win_y = wr.y;
    const aero_tb_h: i32 = display.AERO_TITLEBAR_H;

    fb.fillRect(win_x + 3, win_y + 3, win_w, win_h, rgb(0x30, 0x30, 0x30));
    fb.fillRect(win_x, win_y + aero_tb_h, win_w, win_h - aero_tb_h, t.window_bg);
    if (dwm.isGlassEnabled()) {
        // 拖动时每帧不重跑标题栏 boxBlur，仅 tint+高光，避免拖窗卡顿。
        dwm.renderGlassTintOnly(win_x, win_y, win_w, aero_tb_h, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, win_w, aero_tb_h, t.titlebar_active_left, t.titlebar_active_right);
    }

    drawExplorerTitlebarChrome(win_x, win_y, aero_tb_h, t);

    display.drawAeroCaptionButtons(win_x, win_y, win_w, aero_tb_h, t, display.getExplorerCaptionBtnHover());

    display.drawAeroWindowFrameBorder(win_x, win_y, win_w, win_h);
    fb.fillRect(win_x + 2, win_y + aero_tb_h, win_w - 4, win_h - aero_tb_h - 2, rgb(0xFE, 0xFE, 0xFF));
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
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(win_x, win_y, win_w, aero_tb_h, t.titlebar_active_left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, win_w, aero_tb_h, t.titlebar_active_left, t.titlebar_active_right);
    }

    drawExplorerTitlebarChrome(win_x, win_y, aero_tb_h, t);

    display.drawAeroCaptionButtons(win_x, win_y, win_w, aero_tb_h, t, display.getExplorerCaptionBtnHover());

    display.drawAeroWindowFrameBorder(win_x, win_y, win_w, win_h);
    renderExplorerContent(win_x + 2, win_y + aero_tb_h, win_w - 4, win_h - aero_tb_h - 2, t);
}

/// 与 `resource_loader` / `wallpaper_data` 预设顺序对齐（0…11 对应构建期嵌入的 12 张 PNG）。
var aero_wallpaper_preset: u8 = 0;
pub const wallpaper_preset_count: u8 = 12;

pub fn cycleWallpaperPreset() void {
    aero_wallpaper_preset = (aero_wallpaper_preset + 1) % wallpaper_preset_count;
}

pub fn wallpaperPresetIndex() u8 {
    return aero_wallpaper_preset;
}

fn renderBackground(w: i32, h: i32) void {
    renderWallpaperByPreset(w, h, aero_wallpaper_preset);
}

fn renderWallpaperByPreset(w: i32, h: i32, preset: u8) void {
    const p = preset % wallpaper_preset_count;
    wallpaper_bitmap.drawPreset(p, w, h);
}

fn renderTaskbar(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors, tb_h: i32) void {
    display.renderDesktopAeroTaskbar(scr_w, scr_h, t, tb_h);
}

fn explorerCaptionMain() []const u8 {
    return switch (display.getExplorerShellView()) {
        .computer => "Computer",
        .libraries => shell_strings.explorerLine("ex_lib_title"),
    };
}

fn explorerCaptionSub() []const u8 {
    return switch (display.getExplorerShellView()) {
        .computer => "Local Disk (C:)",
        .libraries => "",
    };
}

fn drawExplorerTitlebarChrome(win_x: i32, win_y: i32, aero_tb_h: i32, t: *const theme.ThemeColors) void {
    icons.drawThemedIcon(.computer, win_x + 6, win_y + 8, 1, .aero);
    const sub = explorerCaptionSub();
    if (sub.len == 0) {
        const ty = win_y + @divTrunc(aero_tb_h - 14, 2);
        fb.drawTextTransparentUi(win_x + 26, ty, explorerCaptionMain(), t.titlebar_text);
    } else {
        fb.drawTextTransparentUi(win_x + 26, win_y + 6, explorerCaptionMain(), t.titlebar_text);
        fb.drawTextTransparentUi(win_x + 26, win_y + 22, sub, rgb(0xD8, 0xE8, 0xF8));
    }
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

    drawExplorerTitlebarChrome(win_x, win_y, aero_tb_h, t);

    display.drawAeroCaptionButtons(win_x, win_y, win_w, aero_tb_h, t, display.getExplorerCaptionBtnHover());

    display.drawAeroWindowFrameBorder(win_x, win_y, win_w, win_h);
    renderExplorerContent(win_x + 2, win_y + aero_tb_h, win_w - 4, win_h - aero_tb_h - 2, t);
}

fn renderExplorerContent(x: i32, y: i32, w: i32, h: i32, t: *const theme.ThemeColors) void {
    switch (display.getExplorerShellView()) {
        .libraries => renderExplorerLibrariesClient(x, y, w, h, t),
        .computer => renderExplorerComputerClient(x, y, w, h, t),
    }
}

fn renderExplorerComputerClient(x: i32, y: i32, w: i32, h: i32, t: *const theme.ThemeColors) void {
    _ = t;
    const cmd_h: i32 = display.AERO_EXPLORER_CMD_H;
    const addr_h: i32 = display.AERO_EXPLORER_ADDR_H;
    fb.drawGradientH(x, y, w, cmd_h, rgb(0xF2, 0xF4, 0xF8), rgb(0xE4, 0xE8, 0xF0));
    fb.drawHLine(x, y + cmd_h, w, rgb(0xB8, 0xC4, 0xD4));
    const cmds = [_][]const u8{ "Organize", "Open", "▼" };
    const cmd_ty = y + @divTrunc(cmd_h - 14, 2);
    var bx64 = @as(i64, x) + 8;
    for (cmds, 0..cmds.len) |cmd, ci| {
        const tc: u32 = if (ci == 2) rgb(0x40, 0x40, 0x40) else rgb(0x00, 0x51, 0x9E);
        fb.drawTextTransparent(display.clampI32FromI64(bx64), cmd_ty, cmd, tc);
        bx64 += @as(i64, fb.textWidth(cmd)) + @as(i64, if (ci == 1) 16 else 12);
    }
    const div_x = display.clampI32FromI64(bx64 + 4);
    fb.drawVLine(div_x, y + 6, cmd_h - 12, rgb(0xC8, 0xD0, 0xDC));
    const inc = "Include in library";
    const share = "Share with";
    const inc_w = fb.textWidth(inc);
    const share_w = fb.textWidth(share);
    const link_gap: i32 = 18;
    const lx: i32 = div_x + 8;
    const cmd_right = display.clampI32FromI64(@as(i64, x) + @as(i64, w) - 6);
    const fits_all = @as(i64, lx) + @as(i64, inc_w) + @as(i64, link_gap) + @as(i64, share_w) <= @as(i64, cmd_right);
    const fits_inc = @as(i64, lx) + @as(i64, inc_w) <= @as(i64, cmd_right);
    if (fits_all) {
        fb.drawTextTransparent(lx, cmd_ty, inc, rgb(0x00, 0x51, 0x9E));
        fb.drawTextTransparent(display.clampI32FromI64(@as(i64, lx) + @as(i64, inc_w) + @as(i64, link_gap)), cmd_ty, share, rgb(0x00, 0x51, 0x9E));
    } else if (fits_inc) {
        fb.drawTextTransparent(lx, cmd_ty, inc, rgb(0x00, 0x51, 0x9E));
    }

    const addr_y = y + cmd_h + 1;
    const go_btn_w: i32 = display.AERO_EXPLORER_GO_BTN_W;
    const addr_field_x: i32 = x + 52;
    const go_x = display.clampI32FromI64(@as(i64, x) + @as(i64, w) - @as(i64, go_btn_w) - @as(i64, display.AERO_EXPLORER_GO_MARGIN_END));
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
        .{ .label = shell_strings.explorerLine("ex_lib_nav_fav"), .indent = 0, .sel = false },
        .{ .label = shell_strings.explorerLine("ex_lib_desktop"), .indent = 10, .sel = false },
        .{ .label = shell_strings.explorerLine("ex_lib_downloads"), .indent = 10, .sel = false },
        .{ .label = shell_strings.explorerLine("ex_lib_nav_lib"), .indent = 0, .sel = false },
        .{ .label = shell_strings.explorerLine("ex_lib_documents"), .indent = 10, .sel = false },
        .{ .label = shell_strings.explorerLine("ex_lib_music"), .indent = 10, .sel = false },
        .{ .label = shell_strings.explorerLine("ex_lib_pictures"), .indent = 10, .sel = false },
        .{ .label = shell_strings.explorerLine("ex_lib_nav_comp"), .indent = 0, .sel = true },
        .{ .label = shell_strings.explorerLine("ex_lib_disk_c"), .indent = 10, .sel = false },
        .{ .label = shell_strings.explorerLine("ex_lib_dvd"), .indent = 10, .sel = false },
        .{ .label = shell_strings.explorerLine("ex_lib_nav_net"), .indent = 0, .sel = false },
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
    const hdr_extra = @as(i64, col_date_x) + @as(i64, fb.textWidth("Date modified")) + 8 < @as(i64, col_size_x);
    fb.drawTextTransparent(list_x + 28, hdr_y, "Name", rgb(0x40, 0x40, 0x40));
    if (hdr_extra) {
        fb.drawTextTransparent(col_date_x, hdr_y, "Date modified", rgb(0x40, 0x40, 0x40));
        fb.drawTextTransparent(col_size_x, hdr_y, "Size", rgb(0x40, 0x40, 0x40));
    }

    const entries = [_]struct { name: []const u8, date: []const u8, size: []const u8, icon: icons.IconId }{
        .{ .name = "Users", .date = "2026/01/15", .size = "", .icon = .documents },
        .{ .name = "Program Files", .date = "2026/03/20", .size = "", .icon = .documents },
        .{ .name = "ZirconOSAero", .date = "2026/02/10", .size = "", .icon = .documents },
        .{ .name = "PerfLogs", .date = "2026/01/01", .size = "", .icon = .documents },
        .{ .name = "boot.ini", .date = "2026/01/01", .size = "1 KB", .icon = .text_editor },
        .{ .name = "pagefile.sys", .date = "2026/03/21", .size = "2 GB", .icon = .text_editor },
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

/// Win7「库」视图：命令栏、圆形导航钮、面包屑与搜索、侧栏分区、四库大图标与状态栏。
fn renderExplorerLibrariesClient(x: i32, y: i32, w: i32, h: i32, t: *const theme.ThemeColors) void {
    _ = t;
    const cmd_h: i32 = display.AERO_EXPLORER_CMD_H;
    const addr_h: i32 = display.AERO_EXPLORER_ADDR_H;

    fb.drawGradientH(x, y, w, cmd_h, rgb(0xF2, 0xF4, 0xF8), rgb(0xE4, 0xE8, 0xF0));
    fb.drawHLine(x, y + cmd_h, w, rgb(0xB8, 0xC4, 0xD4));
    const cmd_ty = y + @divTrunc(cmd_h - 14, 2);
    const org = shell_strings.explorerLine("ex_lib_organize");
    const nl = shell_strings.explorerLine("ex_lib_new_lib");
    fb.drawTextTransparent(x + 8, cmd_ty, org, rgb(0x00, 0x51, 0x9E));
    const nl_x = display.clampI32FromI64(@as(i64, x) + 8 + @as(i64, fb.textWidth(org)) + 18);
    fb.drawTextTransparent(nl_x, cmd_ty, nl, rgb(0x00, 0x51, 0x9E));

    const addr_y = y + cmd_h + 1;
    fb.fillRect(x, addr_y, w, addr_h, rgb(0xF8, 0xF9, 0xFC));
    fb.drawHLine(x, addr_y + addr_h, w, rgb(0xC0, 0xC8, 0xD4));

    const acy = addr_y + @divTrunc(addr_h, 2);
    fb.fillCircle(x + 12, acy, 9, rgb(0xE8, 0xEE, 0xF6));
    fb.drawRect(x + 3, acy - 9, 18, 18, rgb(0xA8, 0xB8, 0xC8));
    fb.fillCircle(x + 34, acy, 9, rgb(0xE8, 0xEE, 0xF6));
    fb.drawRect(x + 25, acy - 9, 18, 18, rgb(0xA8, 0xB8, 0xC8));

    const field_x = x + display.AERO_EXPLORER_LIB_ADDR_FIELD_X;
    const search_w = display.AERO_EXPLORER_LIB_SEARCH_W;
    const search_x = display.clampI32FromI64(@as(i64, x) + @as(i64, w) - 6 - @as(i64, search_w));
    const field_w = @max(48, search_x - 4 - field_x);
    fb.fillRect(field_x, addr_y + 3, field_w, 20, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(field_x, addr_y + 3, field_w, 20, rgb(0x9C, 0xA8, 0xB8));
    icons.drawThemedIcon(.folder, field_x + 4, addr_y + 5, 1, .aero);
    const crumb = shell_strings.explorerLine("ex_lib_title");
    fb.drawTextTransparent(field_x + 24, addr_y + @divTrunc(addr_h - 14, 2), crumb, rgb(0x00, 0x00, 0x00));

    fb.fillRect(search_x, addr_y + 3, search_w, 20, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(search_x, addr_y + 3, search_w, 20, rgb(0x9C, 0xA8, 0xB8));
    const sh = shell_strings.explorerLine("ex_lib_search");
    fb.drawTextTransparent(search_x + 6, addr_y + @divTrunc(addr_h - 14, 2), sh, rgb(0x78, 0x80, 0x88));

    const body_y = addr_y + addr_h;
    const status_h: i32 = 22;
    const body_h = h - cmd_h - 1 - addr_h - status_h - 1;
    if (body_h <= 10) return;

    const nav_w: i32 = @min(168, @max(104, @divTrunc(w, 4)));
    fb.fillRect(x, body_y, nav_w, body_h, rgb(0xFC, 0xFC, 0xFE));
    fb.drawVLine(x + nav_w, body_y, body_h, rgb(0xC8, 0xD0, 0xD8));

    var ny: i32 = body_y + 6;
    const nav_rows = [_]struct { s: []const u8, indent: i32, heading: bool }{
        .{ .s = shell_strings.explorerLine("ex_lib_nav_fav"), .indent = 0, .heading = true },
        .{ .s = shell_strings.explorerLine("ex_lib_desktop"), .indent = 8, .heading = false },
        .{ .s = shell_strings.explorerLine("ex_lib_downloads"), .indent = 8, .heading = false },
        .{ .s = shell_strings.explorerLine("ex_lib_recent"), .indent = 8, .heading = false },
        .{ .s = shell_strings.explorerLine("ex_lib_nav_lib"), .indent = 0, .heading = true },
        .{ .s = shell_strings.explorerLine("ex_lib_documents"), .indent = 8, .heading = false },
        .{ .s = shell_strings.explorerLine("ex_lib_music"), .indent = 8, .heading = false },
        .{ .s = shell_strings.explorerLine("ex_lib_pictures"), .indent = 8, .heading = false },
        .{ .s = shell_strings.explorerLine("ex_lib_videos"), .indent = 8, .heading = false },
        .{ .s = shell_strings.explorerLine("ex_lib_nav_comp"), .indent = 0, .heading = true },
        .{ .s = shell_strings.explorerLine("ex_lib_disk_c"), .indent = 8, .heading = false },
        .{ .s = "D:", .indent = 8, .heading = false },
        .{ .s = "E:", .indent = 8, .heading = false },
        .{ .s = "F:", .indent = 8, .heading = false },
        .{ .s = shell_strings.explorerLine("ex_lib_dvd"), .indent = 8, .heading = false },
        .{ .s = shell_strings.explorerLine("ex_lib_nav_net"), .indent = 0, .heading = true },
    };
    for (nav_rows) |nr| {
        if (ny + 17 > body_y + body_h) break;
        const tc: u32 = if (nr.heading) rgb(0x50, 0x58, 0x60) else rgb(0x18, 0x18, 0x18);
        fb.drawTextTransparent(x + 6 + nr.indent, ny, nr.s, tc);
        ny += if (nr.heading) @as(i32, 18) else @as(i32, 16);
    }

    const list_x = x + nav_w + 1;
    const list_w = w - nav_w - 1;
    fb.fillRect(list_x, body_y, list_w, body_h, rgb(0xFF, 0xFF, 0xFF));

    fb.drawTextTransparent(list_x + 24, body_y + 16, shell_strings.explorerLine("ex_lib_title"), rgb(0x12, 0x18, 0x22));
    fb.drawTextTransparent(list_x + 24, body_y + 36, shell_strings.explorerLine("ex_lib_subtitle"), rgb(0x50, 0x58, 0x60));

    const tile: i32 = 88;
    const gap: i32 = 32;
    const grid_w = 2 * tile + gap;
    const gx0 = list_x + @max(24, @divTrunc(list_w - grid_w, 2));
    const gy0 = body_y + 80;
    const libs = [_]struct { label: []const u8, icon: icons.IconId }{
        .{ .label = shell_strings.explorerLine("ex_lib_videos"), .icon = .folder },
        .{ .label = shell_strings.explorerLine("ex_lib_pictures"), .icon = .pictures },
        .{ .label = shell_strings.explorerLine("ex_lib_documents"), .icon = .documents },
        .{ .label = shell_strings.explorerLine("ex_lib_music"), .icon = .music },
    };
    for (libs, 0..) |lib, i| {
        const col: i32 = @intCast(i % 2);
        const row: i32 = @intCast(i / 2);
        const ix = gx0 + col * (tile + gap);
        const iy = gy0 + row * (tile + gap);
        fb.blendTintRect(ix, iy + 28, tile, 28, rgb(0x58, 0x88, 0xC8), 35, 200);
        icons.drawThemedIcon(lib.icon, ix + @divTrunc(tile - 32, 2), iy + 8, 2, .aero);
        const tw = fb.textWidth(lib.label);
        fb.drawTextTransparent(ix + @divTrunc(tile - tw, 2), iy + tile - 14, lib.label, rgb(0x10, 0x14, 0x1A));
    }

    const status_y = display.clampI32FromI64(@as(i64, y) + @as(i64, h) - @as(i64, status_h));
    fb.fillRect(x, status_y, w, status_h, rgb(0xE8, 0xEE, 0xF6));
    fb.drawHLine(x, status_y, w, rgb(0xC0, 0xC8, 0xD4));
    fb.drawTextTransparent(x + 8, status_y + 4, shell_strings.explorerLine("ex_lib_status"), rgb(0x30, 0x38, 0x42));
}

fn patchDragBackground(scr_w: i32, scr_h: i32) void {
    // 与全帧 `renderWallpaperByPreset` 一致：拖动态必须用嵌入壁纸 cover 修补，否则脏区是 Harmony 渐变块、其余是 PNG，出现「方块留影」。
    const pad: i32 = 20;
    const drag_state = display.getDragState();
    if (drag_state.explorer_active) {
        const wr = display.getWindowRect(scr_w, scr_h);
        const cur = display.ShellRect{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h };
        var u = display.rectUnion(drag_state.explorer_prev, cur);
        u = display.rectInflate(u, pad);
        u = display.rectClampToScreen(u, scr_w, scr_h);
        if (u.w > 0 and u.h > 0) {
            display.patchHarmonyWallpaperRegion(scr_w, scr_h, u.x, u.y, u.w, u.h);
        }
        display.setExplorerDragPrev(cur);
    }
    if (drag_state.taskmgr_active) {
        const tm_pos = display.getTaskMgrPos();
        const tm_sz = display.getTaskMgrSize();
        const cur = display.ShellRect{ .x = tm_pos.x, .y = tm_pos.y, .w = tm_sz.w, .h = tm_sz.h };
        var u = display.rectUnion(drag_state.taskmgr_prev, cur);
        u = display.rectInflate(u, pad);
        u = display.rectClampToScreen(u, scr_w, scr_h);
        if (u.w > 0 and u.h > 0) {
            display.patchHarmonyWallpaperRegion(scr_w, scr_h, u.x, u.y, u.w, u.h);
        }
        display.setTaskMgrDragPrev(cur);
    }
    if (drag_state.builtin_active) {
        if (builtin_apps.topDraggedWindowRect()) |br| {
            const cur = display.ShellRect{ .x = br.x, .y = br.y, .w = br.w, .h = br.h };
            var u = display.rectUnion(drag_state.builtin_prev, cur);
            u = display.rectInflate(u, pad);
            u = display.rectClampToScreen(u, scr_w, scr_h);
            if (u.w > 0 and u.h > 0) {
                display.patchHarmonyWallpaperRegion(scr_w, scr_h, u.x, u.y, u.w, u.h);
            }
        }
        builtin_apps.advanceBuiltinDragPrev();
    }
}
