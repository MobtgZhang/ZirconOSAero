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

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const dwm = @import("../../../drivers/video/core/dwm.zig");
const icons = @import("../icons/root.zig");
const startmenu = @import("../startmenu/root.zig");
const dwm_comp = @import("../../../drivers/video/core/dwm_compositor.zig");
const mat = @import("../material/root.zig");
const display = @import("../../../drivers/video/core/display.zig");
const builtin_apps = @import("../shell/builtin_apps.zig");
const shell_mui = @import("../strings/shell_mui.zig");
const explorer_vol_snap = @import("../../../fs/explorer_volume_snapshot.zig");
const explorer_format = @import("../shell/explorer_format.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const explorer_context_menu = @import("../shell/explorer_context_menu.zig");
const wallpaper_bitmap = @import("../wallpaper/root.zig");
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
        const overlap = display.anyShellHostedWindowsOverlap(w, h);
        renderDragFrame(w, h, t, tb_h, drag_state, draw_cursor, overlap);
    } else {
        renderFullFrame(w, h, t, tb_h, draw_cursor);
    }
}

pub fn renderFrame() void {
    renderFrameEx(true);
}

/// 仅 Explorer + 任务管理器标题栏带（毛玻璃/渐变 + 三键热态），供 `display.renderDesktopFrameEx` 局部刷新；不画壁纸与窗体客户区。
/// 当前壁纸预设是否支持「开始菜单脏区」局部修补。
/// 条件：`wallpaper_data` 中该预设的嵌入 PNG 宽/高非零（`presetSupportsPartialRedraw`）；**与是否「Harmony」文件名无关**，12 张构建期嵌入图均满足时均可 patch。
/// 若未来某预设占位为 0×0，此处返回 false，`display.renderDesktopFrameEx` 对 `startmenu_repaint` 回退 `.full` 路径。
pub fn startMenuRepaintCanPatchWallpaper() bool {
    return wallpaper_bitmap.presetSupportsPartialRedraw(wallpaperPresetIndex());
}

/// 与任务栏相交高度 ≤ 此阈值时视为「底边 seam 膨胀」所致，跳过整根任务栏重绘（避免 hover 每行触发全宽 Aero 任务栏合成）。
const startmenu_taskbar_seam_skip_max_h: i32 = 8;

/// 开始菜单悬停变化时：仅修补壁纸条带 + 与脏区相交的壳层，再重画菜单（避免整帧 `renderFullFrame`）。
/// 行级脏区：`getHoverHighlightRepaintBounds` 与壁纸预设无关（`startmenu` 内统一数学）；缺省时回退 `getPaintBounds`。
pub fn redrawStartMenuRegionOnly(w: i32, h: i32, t: *const theme.ThemeColors, tb_h: i32) void {
    if (!startmenu.isVisible()) return;

    const mb = startmenu.getHoverHighlightRepaintBounds(w, h) orelse startmenu.getPaintBounds(w, h);
    var dirty = display.ShellRect{ .x = mb.x, .y = mb.y, .w = mb.w, .h = mb.h };
    // 行级脏区已紧包高亮条；用小膨胀即可，减小与任务栏带的相交面积。
    dirty = display.rectInflate(dirty, 4);
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
    const win_r_shadow = display.shellRectWithAeroShadowUnion(win_r);
    if (display.rectsOverlap(dirty, win_r_shadow)) {
        renderExplorerWindow(w, h, t);
        dirty = display.rectUnion(dirty, win_r_shadow);
    }

    display.initTaskMgrPosition(w, h);
    const tm = display.getTaskMgrPos();
    const tm_sz = display.getTaskMgrSize();
    const tm_r = display.ShellRect{ .x = tm.x, .y = tm.y, .w = tm_sz.w, .h = tm_sz.h };
    const tm_r_shadow = display.shellRectWithAeroShadowUnion(tm_r);
    if (display.rectsOverlap(dirty, tm_r_shadow)) {
        display.renderTaskManagerWin(w, h, t);
        dirty = display.rectUnion(dirty, tm_r_shadow);
    }

    if (builtin_apps.anyWindowOpen()) {
        const bu_b = builtin_apps.openSlotsBoundsUnion();
        const bu = display.ShellRect{ .x = bu_b.x, .y = bu_b.y, .w = bu_b.w, .h = bu_b.h };
        const bu_shadow = display.shellRectWithAeroShadowUnion(bu);
        if (bu.w > 0 and bu.h > 0 and display.rectsOverlap(dirty, bu_shadow)) {
            builtin_apps.renderShellHostedApps(w, h, t, .normal);
            dirty = display.rectUnion(dirty, bu_shadow);
        }
    }

    const tb_r = display.taskbarBoundsRect(w, h);
    var redraw_taskbar = display.rectsOverlap(dirty, tb_r);
    if (redraw_taskbar) {
        if (display.rectIntersection(dirty, tb_r)) |inter| {
            if (inter.h <= startmenu_taskbar_seam_skip_max_h) redraw_taskbar = false;
        }
    }
    if (redraw_taskbar) {
        renderTaskbar(w, h, t, tb_h);
        dirty = display.rectUnion(dirty, tb_r);
    }

    startmenu.render(w, h);
    display.updateContextMenuAnimation();
    display.renderContextMenu();
    display.renderIconContextMenu();
    // 任务栏右键菜单
    if (display.isTaskbarContextMenuVisible()) {
        display.renderTaskbarContextMenu();
        display.renderTaskbarCtxSubmenu();
        dirty = display.rectUnion(dirty, display.getContextMenuPaintRect());
    }

    dirty = display.rectClampToScreen(dirty, w, h);
    if (dirty.w > 0 and dirty.h > 0) {
        fb.markDirtyRegion(dirty.x, dirty.y, dirty.w, dirty.h);
    }
    display.incFrameCount();
}

/// 仅重绘 Explorer / 任务管理器等待办窗口的 **标题栏带**（`render_cap`），避免指针在标题栏三键上热跟踪时升舱为整帧 `render_full`。验收：`zig build -Dmouse_debug=true` 下横扫标题栏应见 `render_cap` 显著多于 `render_full`（[PointerPolicy_NT61.md](../../../docs/cn/PointerPolicy_NT61.md) **D2**、[AeroDesktopRuntime.md](../../../docs/cn/AeroDesktopRuntime.md)）。
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
        display.drawAeroWindowFrameBorder(wr.x, wr.y, wr.w, wr.h);
    }

    display.initTaskMgrPosition(scr_w, scr_h);
    const tm_sz = display.getTaskMgrSize();
    const tm_w = tm_sz.w;
    const tm_pos = display.getTaskMgrPos();
    if (!display.isTaskMgrWindowMinimized()) {
        redrawTaskMgrCaptionBand(tm_pos.x, tm_pos.y, tm_w, aero_tb_h, t);
        display.drawAeroWindowFrameBorder(tm_pos.x, tm_pos.y, tm_w, tm_sz.h);
    }

    var dirty = display.ShellRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    if (wr.w > 0) {
        dirty = display.rectUnion(dirty, display.shellRectWithAeroShadowUnion(.{ .x = wr.x, .y = wr.y, .w = wr.w, .h = wr.h }));
    }
    if (!display.isTaskMgrWindowMinimized()) {
        dirty = display.rectUnion(dirty, display.shellRectWithAeroShadowUnion(.{ .x = tm_pos.x, .y = tm_pos.y, .w = tm_w, .h = tm_sz.h }));
    }

    if (display.isContextMenuVisible()) {
        display.updateContextMenuAnimation();
        display.renderContextMenu();
        dirty = display.rectUnion(dirty, display.getContextMenuPaintRect());
    }

    if (display.isTaskbarContextMenuVisible()) {
        display.renderTaskbarContextMenu();
        display.renderTaskbarCtxSubmenu();
        dirty = display.rectUnion(dirty, display.getContextMenuPaintRect());
    }

    if (display.isIconContextMenuVisible()) {
        display.renderIconContextMenu();
        // 获取图标菜单的绘制区域（复用 getContextMenuPaintRect 逻辑）
        if (display.isIconContextMenuVisible()) {
            const icon_idx = 0; // 暂时忽略，实际由函数内部处理
            _ = icon_idx;
        }
    }

    const u = display.rectClampToScreen(dirty, scr_w, scr_h);
    if (u.w > 0 and u.h > 0) {
        fb.markDirtyRegion(u.x, u.y, u.w, u.h);
    }
    display.incFrameCount();
}

fn redrawExplorerCaptionBand(win_x: i32, win_y: i32, win_w: i32, aero_tb_h: i32, t: *const theme.ThemeColors) void {
    const pair = display.shellExplorerTitlebarPair(t);
    if (dwm.isGlassEnabled()) {
        // 热态刷新每帧全宽 boxBlur 极重；与任务栏一致用 TintOnly。
        dwm.renderGlassTintOnly(win_x, win_y, win_w, aero_tb_h, pair.left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, win_w, aero_tb_h, pair.left, pair.right);
    }
    drawExplorerTitlebarChrome(win_x, win_y, aero_tb_h, t);
    display.drawAeroCaptionButtons(win_x, win_y, win_w, aero_tb_h, t, display.getExplorerCaptionBtnHover());
}

fn redrawTaskMgrCaptionBand(win_x: i32, win_y: i32, tm_w: i32, th: i32, t: *const theme.ThemeColors) void {
    const pair = display.shellTaskMgrTitlebarPair(t);
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassTintOnly(win_x, win_y, tm_w, th, pair.left, .caption);
    } else {
        fb.drawGradientH(win_x, win_y, tm_w, th, pair.left, pair.right);
    }
    display.drawAeroCaptionButtons(win_x, win_y, tm_w, th, t, display.getTaskMgrCaptionBtnHover());
    fb.drawTextTransparent(win_x + 8, win_y + 5, "Zircon Task Manager", t.titlebar_text);
}

/// 按 `display.getShellKeyboardFocus()` 从后往前绘制，保证顶窗与点击焦点一致。
fn renderShellWindowsInFocusOrder(w: i32, h: i32, t: *const theme.ThemeColors) void {
    const f = display.getShellKeyboardFocus();
    const expl_ok = !display.isExplorerWindowMinimized();
    const tm_ok = !display.isTaskMgrWindowMinimized();
    const bu_ok = builtin_apps.anyWindowOpen();

    switch (f) {
        .explorer => {
            if (tm_ok) display.renderTaskManagerWin(w, h, t);
            if (bu_ok) builtin_apps.renderShellHostedApps(w, h, t, .normal);
            if (expl_ok) renderExplorerWindow(w, h, t);
        },
        .taskmgr => {
            if (expl_ok) renderExplorerWindow(w, h, t);
            if (bu_ok) builtin_apps.renderShellHostedApps(w, h, t, .normal);
            if (tm_ok) display.renderTaskManagerWin(w, h, t);
        },
        .builtin_apps => {
            if (expl_ok) renderExplorerWindow(w, h, t);
            if (tm_ok) display.renderTaskManagerWin(w, h, t);
            if (bu_ok) builtin_apps.renderShellHostedApps(w, h, t, .normal);
        },
    }
}

fn renderShellWindowsInFocusOrderDrag(w: i32, h: i32, t: *const theme.ThemeColors, ds: display.DragState) void {
    const f = display.getShellKeyboardFocus();
    const expl_ok = !display.isExplorerWindowMinimized();
    const tm_ok = !display.isTaskMgrWindowMinimized();
    const bu_ok = builtin_apps.anyWindowOpen();

    switch (f) {
        .explorer => {
            if (tm_ok) {
                if (ds.taskmgr_active) display.renderTaskManagerWinDragLight(w, h, t) else display.renderTaskManagerWin(w, h, t);
            }
            if (bu_ok) {
                if (ds.builtin_active) builtin_apps.renderShellHostedApps(w, h, t, .drag_light) else builtin_apps.renderShellHostedApps(w, h, t, .normal);
            }
            if (expl_ok) {
                if (ds.explorer_active) renderExplorerWindowDragLight(w, h, t) else renderExplorerWindow(w, h, t);
            }
        },
        .taskmgr => {
            if (expl_ok) {
                if (ds.explorer_active) renderExplorerWindowDragLight(w, h, t) else renderExplorerWindow(w, h, t);
            }
            if (bu_ok) {
                if (ds.builtin_active) builtin_apps.renderShellHostedApps(w, h, t, .drag_light) else builtin_apps.renderShellHostedApps(w, h, t, .normal);
            }
            if (tm_ok) {
                if (ds.taskmgr_active) display.renderTaskManagerWinDragLight(w, h, t) else display.renderTaskManagerWin(w, h, t);
            }
        },
        .builtin_apps => {
            if (expl_ok) {
                if (ds.explorer_active) renderExplorerWindowDragLight(w, h, t) else renderExplorerWindow(w, h, t);
            }
            if (tm_ok) {
                if (ds.taskmgr_active) display.renderTaskManagerWinDragLight(w, h, t) else display.renderTaskManagerWin(w, h, t);
            }
            if (bu_ok) {
                if (ds.builtin_active) builtin_apps.renderShellHostedApps(w, h, t, .drag_light) else builtin_apps.renderShellHostedApps(w, h, t, .normal);
            }
        },
    }
}

fn renderFullFrame(w: i32, h: i32, t: *const theme.ThemeColors, tb_h: i32, draw_cursor: bool) void {
    const bisect = @import("build_options").desktop_bisect;
    if (bisect) @import("../../../rtl/panic_context.zig").setPhase(0x0002_0080);
    renderBackground(w, h);
    if (bisect) @import("../../../rtl/panic_context.zig").setPhase(0x0002_0081);
    display.renderDesktopIcons(w, h, t);
    if (bisect) @import("../../../rtl/panic_context.zig").setPhase(0x0002_0082);
    renderShellWindowsInFocusOrder(w, h, t);
    if (bisect) @import("../../../rtl/panic_context.zig").setPhase(0x0002_0085);
    renderTaskbar(w, h, t, tb_h);

    if (startmenu.isVisible()) {
        if (bisect) @import("../../../rtl/panic_context.zig").setPhase(0x0002_0086);
        startmenu.render(w, h);
    }
    if (bisect) @import("../../../rtl/panic_context.zig").setPhase(0x0002_0087);
    display.updateContextMenuAnimation();
    display.renderContextMenu();
    display.renderIconContextMenu();
    explorer_context_menu.renderExplorerContextMenu();
    if (display.isTaskbarContextMenuVisible()) {
        display.renderTaskbarContextMenu();
        display.renderTaskbarCtxSubmenu();
    }
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

fn renderDragFrame(w: i32, h: i32, t: *const theme.ThemeColors, tb_h: i32, ds: display.DragState, draw_cursor: bool, shell_windows_overlap: bool) void {
    // 渲染顺序（与 renderFullFrame 一致）：
    //   1. 壁纸（或局部 patch）
    //   2. 窗口（按焦点序，轻量阴影）
    //   3. 桌面图标 + 任务栏（在窗口之后绘制，确保不被窗口覆盖）
    //
    // 问题根因：之前的渲染顺序是 壁纸→图标→任务栏→窗口，窗口会覆盖图标/任务栏。
    // 解决方案：图标/任务栏必须在窗口之后重绘。
    const dirty_pad: i32 = 22;
    const bisect = @import("build_options").desktop_bisect;

    if (shell_windows_overlap) {
        // 多窗重叠时：整幅壁纸重绘 + 窗口 + 图标 + 任务栏
        renderBackground(w, h);
        renderShellWindowsInFocusOrderDrag(w, h, t, ds);
        // 图标和任务栏无条件重绘（与 renderFullFrame 一致）
        display.renderDesktopIcons(w, h, t);
        if (bisect) @import("../../../rtl/panic_context.zig").setPhase(0x0002_00A0);
        renderTaskbar(w, h, t, tb_h);
    } else {
        // 单窗拖动：局部 patch 壁纸 + 窗口 + 图标 + 任务栏
        patchDragBackground(w, h);
        renderShellWindowsInFocusOrderDrag(w, h, t, ds);
        // 图标和任务栏在窗口之后绘制，确保不被窗口覆盖
        // 这与 renderFullFrame 的行为一致：图标和任务栏是场景的最上层
        display.renderDesktopIcons(w, h, t);
        if (bisect) @import("../../../rtl/panic_context.zig").setPhase(0x0002_00A0);
        renderTaskbar(w, h, t, tb_h);
    }

    if (startmenu.isVisible()) {
        startmenu.render(w, h);
    }
    display.updateContextMenuAnimation();
    display.renderContextMenu();
    display.renderIconContextMenu();
    display.renderExplorerListContextMenu();
    if (display.isTaskbarContextMenuVisible()) {
        display.renderTaskbarContextMenu();
        display.renderTaskbarCtxSubmenu();
    }

    if (draw_cursor) {
        display.renderCursorAt();
    }
    display.incFrameCount();

    // 脏区标记：多窗重叠时标记全屏（整个渲染区都需要更新），单窗拖动时标记具体窗口脏区
    if (shell_windows_overlap) {
        // 多窗重叠时全屏标记，避免逐窗标记与全屏重绘不一致
        fb.markFullScreenDirty();
    } else {
        // 单窗拖动：标记具体窗口脏区
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
}

/// 拖动态：保留轻量阴影（2层、较低透明度）以保持视觉反馈，
/// 避免纯黑矩形与邻窗 Aero 边框 blend 后产生「邻窗发灰」观感。
fn renderExplorerWindowDragLight(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors) void {
    renderExplorerWindowShared(scr_w, scr_h, t, .light);
}

fn renderExplorerWindowFast(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors) void {
    renderExplorerWindowShared(scr_w, scr_h, t, .fast);
}

/// Explorer 窗口渲染提示枚举，用于 `renderExplorerWindowShared` 选择不同阴影/glass 路径.
const ExplorerRenderHint = enum {
    full,
    light,
    fast,
};

/// Explorer 窗口共享渲染实现.
/// 根据 hint 选择阴影层数和 glass 渲染方式.
/// 三个包装函数 `renderExplorerWindow*` 调用此函数,消除约 70% 的重复代码.
fn renderExplorerWindowShared(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors, hint: ExplorerRenderHint) void {
    const wr = display.getWindowRect(scr_w, scr_h);
    const win_w = wr.w;
    const win_h = wr.h;
    const win_x = wr.x;
    const win_y = wr.y;
    const aero_tb_h: i32 = display.AERO_TITLEBAR_H;

    const layers: u8 = switch (hint) {
        .full => 4,
        .light => 2,
        .fast => 3,
    };
    const shadow_offset: u8 = switch (hint) {
        .full => 8,
        .light => 4,
        .fast => 6,
    };

    if (dwm.isShadowEnabled() and display.getPresentCount() > 0) {
        mat.renderShadow(win_x, win_y, win_w, win_h, shadow_offset, layers);
    } else {
        fb.fillRect(win_x + 3, win_y + 3, win_w, win_h, rgb(0x30, 0x30, 0x30));
    }

    fb.fillRect(win_x, win_y + aero_tb_h, win_w, win_h - aero_tb_h, t.window_bg);
    const ex_pair = display.shellExplorerTitlebarPair(t);
    if (dwm.isGlassEnabled()) {
        if (hint == .light) {
            dwm.renderGlassTintOnly(win_x, win_y, win_w, aero_tb_h, ex_pair.left, .caption);
        } else {
            dwm.renderGlassEffect(win_x, win_y, win_w, aero_tb_h, ex_pair.left, .caption);
        }
    } else {
        fb.drawGradientH(win_x, win_y, win_w, aero_tb_h, ex_pair.left, ex_pair.right);
    }
    drawExplorerTitlebarChrome(win_x, win_y, aero_tb_h, t);
    display.drawAeroCaptionButtons(win_x, win_y, win_w, aero_tb_h, t, display.getExplorerCaptionBtnHover());
    display.drawAeroWindowFrameBorder(win_x, win_y, win_w, win_h);
    renderExplorerContent(win_x + 2, win_y + aero_tb_h, win_w - 4, win_h - aero_tb_h - 2, t);
}

/// 壁纸预设数量（与 resource_loader / wallpaper_data 嵌入顺序一致,0..11 对应 12 张 PNG）.
const WALLPAPER_PRESET_COUNT: u8 = 12;

/// 任务栏与开始菜单衔接区域的最大垂直重叠像素（防止任务栏底部有细缝）.
const TASKBAR_STARTMENU_SEAM_SKIP_MAX_H: i32 = 8;

var aero_wallpaper_preset: u8 = 0;
pub const wallpaper_preset_count: u8 = WALLPAPER_PRESET_COUNT;

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
    var scratch: [1]u8 = undefined;
    return switch (display.getExplorerShellView()) {
        .computer => shell_mui.loadString(.ex_addr_computer, &scratch),
        .libraries => shell_mui.loadString(.ex_lib_title, &scratch),
    };
}

fn drawExplorerTitlebarChrome(win_x: i32, win_y: i32, aero_tb_h: i32, t: *const theme.ThemeColors) void {
    icons.drawThemedIcon(.computer, win_x + 6, win_y + 8, 1, .aero, false);
    var sub_buf: [16]u8 = undefined;
    const sub = display.getExplorerTitleSubline(&sub_buf);
    if (sub.len == 0) {
        const ty = win_y + @divTrunc(aero_tb_h - 14, 2);
        fb.drawTextTransparentUi(win_x + 26, ty, explorerCaptionMain(), t.titlebar_text);
    } else {
        fb.drawTextTransparentUi(win_x + 26, win_y + 6, explorerCaptionMain(), t.titlebar_text);
        fb.drawTextTransparentUi(win_x + 26, win_y + 22, sub, rgb(0xD8, 0xE8, 0xF8));
    }
}

fn renderExplorerWindow(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors) void {
    renderExplorerWindowShared(scr_w, scr_h, t, .full);
}

fn renderExplorerContent(x: i32, y: i32, w: i32, h: i32, t: *const theme.ThemeColors) void {
    switch (display.getExplorerShellView()) {
        .libraries => renderExplorerLibrariesClient(x, y, w, h, t),
        .computer => renderExplorerComputerClient(x, y, w, h, t),
    }
}

fn explorerNavLetterUpper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

fn explorerComputerNavRowHilite(ri: usize) bool {
    return switch (display.getExplorerLocation()) {
        .computer_root => ri == 7,
        .drive_root => |L| {
            const u = explorerNavLetterUpper(L);
            display.explorerEnsureVolumeSnapshot();
            const vols = display.explorerVolumes();
            var di: usize = 0;
            while (di < vols.len) : (di += 1) {
                if (ri == 8 + di and vols[di].letter == u) return true;
            }
            return false;
        },
        else => false,
    };
}

fn drawExplorerComputerNavLine(
    win_x: i32,
    ny: *i32,
    row_index: *usize,
    body_bottom: i32,
    nav_w: i32,
    label: []const u8,
    indent: i32,
    icon_id: icons.IconId,
) void {
    const ri = row_index.*;
    if (ny.* + 18 > body_bottom) return;
    const hilite = explorerComputerNavRowHilite(ri);
    if (hilite) {
        fb.fillRect(win_x + 2, ny.*, nav_w - 4, 18, rgb(0xD8, 0xE8, 0xF8));
        fb.drawRect(win_x + 2, ny.*, nav_w - 4, 18, rgb(0xA8, 0xC8, 0xE0));
    }
    const tc: u32 = if (hilite) rgb(0x00, 0x3C, 0x80) else rgb(0x1A, 0x1A, 0x1A);
    const ix = win_x + 4 + indent;
    icons.drawThemedIcon(icon_id, ix, ny.* + 1, 1, .aero, @as(bool, hilite));
    fb.drawTextTransparent(ix + 20, ny.* + 2, label, tc);
    ny.* += 20;
    row_index.* += 1;
}

fn renderExplorerComputerClient(x: i32, y: i32, w: i32, h: i32, t: *const theme.ThemeColors) void {
    _ = t;
    var mui_scratch: [1]u8 = undefined;
    const Lc = display.explorerComputerClientLayout(w, h);
    const cmd_h = Lc.cmd_h;
    const addr_h = Lc.addr_h;
    const status_h = Lc.status_h;

    fb.drawGradientH(x, y, w, cmd_h, rgb(0xF2, 0xF4, 0xF8), rgb(0xE4, 0xE8, 0xF0));
    fb.drawHLine(x, y + cmd_h, w, rgb(0xB8, 0xC4, 0xD4));
    const cmd_row1_ty = y + 6;
    const cmds = [_][]const u8{
        shell_mui.loadString(.ex_cmp_organize, &mui_scratch),
        shell_mui.loadString(.ex_cmp_open, &mui_scratch),
        shell_mui.loadString(.ex_cmp_more, &mui_scratch),
    };
    var bx64 = @as(i64, x) + 8;
    for (cmds, 0..cmds.len) |cmd, ci| {
        const tc: u32 = if (ci == 2) rgb(0x40, 0x40, 0x40) else rgb(0x00, 0x51, 0x9E);
        fb.drawTextTransparent(display.clampI32FromI64(bx64), cmd_row1_ty, cmd, tc);
        bx64 += @as(i64, fb.textWidth(cmd)) + @as(i64, if (ci == 1) 16 else 12);
    }
    const div_x = display.clampI32FromI64(bx64 + 4);
    fb.drawVLine(div_x, y + 4, cmd_h - 8, rgb(0xC8, 0xD0, 0xDC));
    const inc = shell_mui.loadString(.ex_cmp_include_lib, &mui_scratch);
    const share = shell_mui.loadString(.ex_cmp_share_with, &mui_scratch);
    const inc_w = fb.textWidth(inc);
    const share_w = fb.textWidth(share);
    const link_gap: i32 = 18;
    const lx_div: i32 = div_x + 8;
    const cmd_right = display.clampI32FromI64(@as(i64, x) + @as(i64, w) - 6);
    const fits_all = @as(i64, lx_div) + @as(i64, inc_w) + @as(i64, link_gap) + @as(i64, share_w) <= @as(i64, cmd_right);
    const fits_inc = @as(i64, lx_div) + @as(i64, inc_w) <= @as(i64, cmd_right);
    if (fits_all) {
        fb.drawTextTransparent(lx_div, cmd_row1_ty, inc, rgb(0x00, 0x51, 0x9E));
        fb.drawTextTransparent(display.clampI32FromI64(@as(i64, lx_div) + @as(i64, inc_w) + @as(i64, link_gap)), cmd_row1_ty, share, rgb(0x00, 0x51, 0x9E));
    } else if (fits_inc) {
        fb.drawTextTransparent(lx_div, cmd_row1_ty, inc, rgb(0x00, 0x51, 0x9E));
    }

    const cmd_row2_ty = y + 30;
    const cmd2 = [_][]const u8{
        shell_mui.loadString(.ex_cmd_properties, &mui_scratch),
        shell_mui.loadString(.ex_cmd_system_properties, &mui_scratch),
        shell_mui.loadString(.ex_cmd_view, &mui_scratch),
    };
    var bx2 = @as(i64, x) + 8;
    for (cmd2, 0..cmd2.len) |cmd, ci| {
        fb.drawTextTransparent(display.clampI32FromI64(bx2), cmd_row2_ty, cmd, rgb(0x00, 0x51, 0x9E));
        bx2 += @as(i64, fb.textWidth(cmd)) + @as(i64, if (ci + 1 < cmd2.len) 14 else 0);
    }

    // 地址栏区域：后退/前进/向上按钮 + 地址文本框
    const addr_y = y + cmd_h + 1;
    const go_btn_w: i32 = display.AERO_EXPLORER_GO_BTN_W;
    const addr_field_x: i32 = x + 100; // 为导航按钮留出空间
    const go_x = display.clampI32FromI64(@as(i64, x) + @as(i64, w) - @as(i64, go_btn_w) - @as(i64, display.AERO_EXPLORER_GO_MARGIN_END));
    const addr_field_w = @max(64, go_x - 4 - addr_field_x);

    fb.fillRect(x, addr_y, w, addr_h, rgb(0xF8, 0xF9, 0xFC));
    fb.drawHLine(x, addr_y + addr_h, w, rgb(0xC0, 0xC8, 0xD4));

    // 绘制导航按钮
    const nav_btn_x: i32 = x + 52;
    const nav_btn_y: i32 = addr_y + 3;
    const nav_btn_w: i32 = 14;
    const nav_btn_h: i32 = 20;

    // 后退按钮
    const can_back = display.explorerCanNavigateBack();
    fb.fillRect(nav_btn_x, nav_btn_y, nav_btn_w, nav_btn_h, rgb(if (can_back) 0xFF else 0xE0, 0xF0, 0xF8));
    fb.drawRect(nav_btn_x, nav_btn_y, nav_btn_w, nav_btn_h, rgb(0x9C, 0xA8, 0xB8));
    fb.drawTextTransparent(nav_btn_x + 2, nav_btn_y + 4, "<", if (can_back) rgb(0x20, 0x20, 0x20) else rgb(0xC0, 0xC0, 0xC0));

    // 前进按钮
    const nav_btn2_x: i32 = nav_btn_x + nav_btn_w + 2;
    const can_fwd = display.explorerCanNavigateForward();
    fb.fillRect(nav_btn2_x, nav_btn_y, nav_btn_w, nav_btn_h, rgb(if (can_fwd) 0xFF else 0xE0, 0xF0, 0xF8));
    fb.drawRect(nav_btn2_x, nav_btn_y, nav_btn_w, nav_btn_h, rgb(0x9C, 0xA8, 0xB8));
    fb.drawTextTransparent(nav_btn2_x + 2, nav_btn_y + 4, ">", if (can_fwd) rgb(0x20, 0x20, 0x20) else rgb(0xC0, 0xC0, 0xC0));

    // 向上按钮
    const nav_btn3_x: i32 = nav_btn2_x + nav_btn_w + 2;
    const can_up = display.explorerCanNavigateUp();
    fb.fillRect(nav_btn3_x, nav_btn_y, nav_btn_w, nav_btn_h, rgb(if (can_up) 0xFF else 0xE0, 0xF0, 0xF8));
    fb.drawRect(nav_btn3_x, nav_btn_y, nav_btn_w, nav_btn_h, rgb(0x9C, 0xA8, 0xB8));
    fb.drawTextTransparent(nav_btn3_x + 2, nav_btn_y + 4, "^", if (can_up) rgb(0x20, 0x20, 0x20) else rgb(0xC0, 0xC0, 0xC0));

    // 地址标签和文本框
    fb.drawTextTransparent(x + 8, addr_y + @divTrunc(addr_h - 14, 2), shell_mui.loadString(.ex_cmp_address, &mui_scratch), rgb(0x50, 0x58, 0x60));
    fb.fillRect(addr_field_x, addr_y + 3, addr_field_w, 20, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(addr_field_x, addr_y + 3, addr_field_w, 20, rgb(0x9C, 0xA8, 0xB8));

    // 根据当前位置获取子目录路径
    var addr_buf: [256]u8 = undefined;
    const addr_line = if (display.getExplorerSubdirectoryPath()) |sub|
        explorer_format.formatAddressBarWithSubpath(&addr_buf, display.getExplorerAddressBarKind(), sub.letter, sub.path)
    else
        explorer_format.formatAddressBar(&addr_buf, display.getExplorerAddressBarKind(), display.getExplorerAddressDriveLetter());
    fb.drawTextTransparent(addr_field_x + 6, addr_y + @divTrunc(addr_h - 14, 2), addr_line, rgb(0x00, 0x00, 0x00));

    const go_lbl = shell_mui.loadString(.ex_cmp_go, &mui_scratch);
    fb.fillRoundedRect(go_x, addr_y + 4, go_btn_w, 18, 2, rgb(0xE8, 0xEC, 0xF2));
    fb.drawTextTransparent(go_x + @divTrunc(go_btn_w - fb.textWidth(go_lbl), 2), addr_y + @divTrunc(addr_h - 14, 2), go_lbl, rgb(0x00, 0x00, 0x00));

    const body_y = addr_y + addr_h;
    const body_h = Lc.body_h;
    if (body_h <= 10) return;

    display.explorerEnsureVolumeSnapshot();
    const vols_all = display.explorerVolumes();

    const nav_w = Lc.nav_w;
    const nav_hdr_h: i32 = @min(24, body_h);
    fb.drawGradientV(x, body_y, nav_w, nav_hdr_h, rgb(0xF0, 0xF4, 0xFA), rgb(0xE8, 0xEC, 0xF4));
    fb.fillRect(x, body_y + nav_hdr_h, nav_w, body_h - nav_hdr_h, rgb(0xFC, 0xFC, 0xFE));
    fb.drawVLine(x + nav_w, body_y, body_h, rgb(0xC8, 0xD0, 0xD8));

    var ri: usize = 0;
    var ny: i32 = body_y + 4;
    const body_bottom = body_y + body_h;
    var vol_label_buf: [48]u8 = undefined;

    drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_nav_fav, &mui_scratch), 0, .favorites);
    drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_desktop, &mui_scratch), 10, .shell_desktop);
    drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_downloads, &mui_scratch), 10, .downloads);
    drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_nav_lib, &mui_scratch), 0, .library_root);
    drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_documents, &mui_scratch), 10, .documents);
    drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_music, &mui_scratch), 10, .music);
    drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_pictures, &mui_scratch), 10, .pictures);
    drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_nav_comp, &mui_scratch), 0, .computer);
    for (vols_all) |v| {
        const vlab = explorer_format.formatDriveNavLabel(&vol_label_buf, v.letter);
        drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, vlab, 10, v.iconId());
    }
    drawExplorerComputerNavLine(x, &ny, &ri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_nav_net, &mui_scratch), 0, .network);

    const list_x = x + Lc.list_x;
    const list_w = Lc.list_w;
    const drive_sec_h = Lc.drive_sec_h;
    fb.fillRect(list_x, body_y, list_w, body_h, rgb(0xFF, 0xFF, 0xFF));

    if (drive_sec_h > 0) {
        var any_fixed = false;
        for (vols_all) |v| {
            if (v.kind == .fixed) {
                any_fixed = true;
                break;
            }
        }
        if (any_fixed) {
            fb.drawTextTransparent(list_x + 8, body_y + 4, shell_mui.loadString(.ex_grp_hard_disks, &mui_scratch), rgb(0x38, 0x40, 0x48));
        }
        const tiles = display.layoutExplorerComputerDriveTilesClient(Lc.nav_w, body_y - y, w);
        if (tiles.first_removable_idx != 255 and tiles.first_removable_idx < tiles.count) {
            const fr = tiles.first_removable_idx;
            fb.drawTextTransparent(list_x + 8, y + tiles.ry[fr] - 16, shell_mui.loadString(.ex_grp_removable, &mui_scratch), rgb(0x38, 0x40, 0x48));
        }
        var cap_buf: [80]u8 = undefined;
        const sel_letter = display.explorerComputerDriveSelected();
        var ti: u32 = 0;
        while (ti < tiles.count) : (ti += 1) {
            const ix = @as(usize, @intCast(ti));
            const letter = tiles.letter[ix];
            const vol = explorer_vol_snap.volumeByLetter(vols_all, letter) orelse continue;
            const tx = x + tiles.rx[ix];
            const ty = y + tiles.ry[ix];
            if (sel_letter != 0 and explorerNavLetterUpper(letter) == sel_letter) {
                fb.fillRect(tx - 2, ty - 2, tiles.rw + 24, tiles.rh + 8, rgb(0xE8, 0xF0, 0xFA));
                fb.drawRect(tx - 2, ty - 2, tiles.rw + 24, tiles.rh + 8, rgb(0x78, 0xB0, 0xE8));
            }
            icons.drawThemedIcon(vol.iconId(), tx, ty, 1, .aero, false);
            const sub = explorer_format.formatDriveTileSubtitle(&cap_buf, letter, vol.kind);
            fb.drawTextTransparent(tx + 20, ty + 2, sub, rgb(0x00, 0x00, 0x00));
            const bbx = tx + 20;
            const bby = ty + 22;
            fb.fillRect(bbx, bby, 100, 6, rgb(0xE4, 0xE8, 0xEC));
            const pct: i32 = if (vol.space_known and vol.total_mb > 0)
                @intCast(@min(@as(u64, 100), @as(u64, vol.free_mb) * 100 / @max(@as(u64, vol.total_mb), 1)))
            else
                0;
            const bar_rgb = if (!vol.space_known)
                rgb(0xC8, 0xCC, 0xD0)
            else if (pct < 10)
                rgb(0xE0, 0x68, 0x58)
            else
                rgb(0x38, 0xB8, 0xD0);
            fb.fillRect(bbx, bby, pct, 6, bar_rgb);
            const cap_txt = explorer_format.formatVolumeFreeCaption(&cap_buf, vol.free_mb, vol.total_mb, vol.space_known);
            fb.drawTextTransparent(bbx + 106, bby - 2, cap_txt, rgb(0x50, 0x58, 0x60));
        }
    }

    if (Lc.detail_h > 0) {
        const dpy = body_y + drive_sec_h;
        const sel = display.explorerComputerDriveSelected();
        if (explorer_vol_snap.volumeByLetter(vols_all, sel)) |dv| {
            fb.fillRect(list_x, dpy, list_w, Lc.detail_h, rgb(0xF4, 0xF7, 0xFC));
            fb.drawHLine(list_x, dpy, list_w, rgb(0xD0, 0xD4, 0xDC));
            fb.drawHLine(list_x, dpy + Lc.detail_h - 1, list_w, rgb(0xD0, 0xD4, 0xDC));
            icons.drawThemedIcon(dv.iconId(), list_x + 10, dpy + 10, 2, .aero, false);
            var dtitle: [96]u8 = undefined;
            const title_ln = explorer_format.formatDriveTileSubtitle(&dtitle, dv.letter, dv.kind);
            fb.drawTextTransparent(list_x + 48, dpy + 12, title_ln, rgb(0x00, 0x00, 0x00));
            const fs_lbl = shell_mui.loadString(.ex_detail_fs_label, &mui_scratch);
            var fs_scratch: [32]u8 = undefined;
            const fs_val = shell_mui.fsTypeLabel(dv.fs_type, &fs_scratch);
            fb.drawTextTransparent(list_x + 48, dpy + 28, fs_lbl, rgb(0x50, 0x58, 0x60));
            fb.drawTextTransparent(list_x + 48 + fb.textWidth(fs_lbl) + 6, dpy + 28, fs_val, rgb(0x20, 0x20, 0x20));
            const free_lbl = shell_mui.loadString(.ex_detail_free_label, &mui_scratch);
            const tot_lbl = shell_mui.loadString(.ex_detail_total_label, &mui_scratch);
            var free_cap: [80]u8 = undefined;
            const free_txt = explorer_format.formatVolumeFreeCaption(&free_cap, dv.free_mb, dv.total_mb, dv.space_known);
            var sz_buf: [64]u8 = undefined;
            const tot_txt = if (dv.space_known)
                std.fmt.bufPrint(&sz_buf, "{d} GB", .{@max(dv.total_mb / 1024, 1)}) catch free_txt
            else
                shell_mui.loadString(.ex_space_unknown, &mui_scratch);
            fb.drawTextTransparent(list_x + 48, dpy + 42, free_lbl, rgb(0x50, 0x58, 0x60));
            fb.drawTextTransparent(list_x + 48 + fb.textWidth(free_lbl) + 6, dpy + 42, free_txt, rgb(0x20, 0x20, 0x20));
            fb.drawTextTransparent(list_x + 260, dpy + 42, tot_lbl, rgb(0x50, 0x58, 0x60));
            fb.drawTextTransparent(list_x + 260 + fb.textWidth(tot_lbl) + 6, dpy + 42, tot_txt, rgb(0x20, 0x20, 0x20));
        }
    }

    const list_top = body_y + Lc.list_top_rel;
    fb.fillRect(list_x, list_top, list_w, 20, rgb(0xF5, 0xF5, 0xF8));
    fb.drawHLine(list_x, list_top + 20, list_w, rgb(0xD0, 0xD0, 0xD5));
    const hdr_y = list_top + 3;
    const col_date_x = list_x + @max(160, list_w - 200);
    const col_size_x = list_x + list_w - 56;
    const date_hdr = shell_mui.loadString(.ex_col_date_modified, &mui_scratch);
    const hdr_extra = @as(i64, col_date_x) + @as(i64, fb.textWidth(date_hdr)) + 8 < @as(i64, col_size_x);
    fb.drawTextTransparent(list_x + 28, hdr_y, shell_mui.loadString(.col_name, &mui_scratch), rgb(0x40, 0x40, 0x40));
    if (hdr_extra) {
        fb.drawTextTransparent(col_date_x, hdr_y, date_hdr, rgb(0x40, 0x40, 0x40));
        fb.drawTextTransparent(col_size_x, hdr_y, shell_mui.loadString(.col_size, &mui_scratch), rgb(0x40, 0x40, 0x40));
    }

    var list_entries: [64]explorer_vol_snap.ExplorerListEntry = undefined;
    const entry_n: usize = switch (display.getExplorerLocation()) {
        .drive_root => |L| display.readExplorerDriveRootSorted(L, list_entries[0..]),
        else => 0,
    };
    // 如果有子目录路径，也读取子目录内容（使用当前排序设置）
    const subdir_n: usize = if (display.getExplorerSubdirectoryPath()) |sub| blk: {
        const n = display.readExplorerSubdirectorySorted(sub.letter, sub.path, list_entries[entry_n..]);
        break :blk entry_n + n;
    } else entry_n;
    const entries = list_entries[0..subdir_n];

    var ey: i32 = list_top + 22;
    if (entries.len == 0 and display.getExplorerLocation() == .computer_root) {
        fb.drawTextTransparent(list_x + 28, ey + 4, shell_mui.loadString(.ex_expl_empty_list, &mui_scratch), rgb(0x78, 0x80, 0x88));
    } else {
        const sel = display.getExplorerListSelectedRow();
        for (entries, 0..) |entry, i| {
            if (ey + 20 > body_y + body_h) break;
            if (sel == i) {
                fb.fillRect(list_x, ey, list_w - 16, 20, rgb(0xD0, 0xE8, 0xF8));
            } else if (i % 2 == 1) {
                fb.fillRect(list_x, ey, list_w - 16, 20, rgb(0xF5, 0xF8, 0xFC));
            }
            const row_text_y = ey + 4;
            const name_slice = entry.name[0..entry.name_len];
            const date_slice = entry.date[0..entry.date_len];
            const size_slice = entry.size[0..entry.size_len];
            icons.drawThemedIcon(entry.icon, list_x + 6, ey + 2, 1, .aero, false);
            fb.drawTextTransparent(list_x + 28, row_text_y, name_slice, rgb(0x00, 0x00, 0x00));
            if (hdr_extra) {
                fb.drawTextTransparent(col_date_x, row_text_y, date_slice, rgb(0x60, 0x60, 0x60));
                fb.drawTextTransparent(col_size_x, row_text_y, size_slice, rgb(0x60, 0x60, 0x60));
            }
            ey += 20;
        }
    }

    const sb_x = list_x + list_w - 16;
    const sb_h = body_h - (list_top + 21 - body_y);
    fb.fillRect(sb_x, list_top + 21, 16, sb_h, rgb(0xF0, 0xF0, 0xF2));
    fb.drawVLine(sb_x, list_top + 21, sb_h, rgb(0xD0, 0xD0, 0xD5));
    fb.fillRect(sb_x + 3, list_top + 24, 10, 40, rgb(0xC0, 0xC4, 0xCC));

    const status_y = y + h - status_h;
    fb.fillRect(x, status_y, w, status_h, rgb(0xF0, 0xF0, 0xF2));
    fb.drawHLine(x, status_y, w, rgb(0xD0, 0xD0, 0xD5));
    var place_buf: [256]u8 = undefined;
    const place_line: []const u8 = switch (display.getExplorerLocation()) {
        .computer_root => shell_mui.loadString(.ex_addr_computer, &mui_scratch),
        .drive_root => |L| if (display.getExplorerSubdirectoryPath()) |sub|
            explorer_format.formatSubdirectoryPath(&place_buf, sub.letter, sub.path)
        else
            explorer_format.formatDriveRootPath(&place_buf, L),
        .libraries_root => shell_mui.loadString(.ex_lib_title, &mui_scratch),
    };
    var st_buf: [160]u8 = undefined;
    const brand = shell_mui.loadString(.ex_status_brand, &mui_scratch);
    const status_txt = shell_mui.formatExplorerStatusBar(&st_buf, entries.len, place_line, brand);
    fb.drawTextTransparent(x + 8, status_y + 3, status_txt, rgb(0x40, 0x40, 0x40));

    // 选中文件的详情面板（当有选中项且不在 computer_root 时显示）
    if (display.getExplorerLocation() != .computer_root and display.getExplorerListSelectedRow() != 0xFFFF_FFFF) {
        const detail_panel_h: i32 = 60;
        const detail_y = status_y - detail_panel_h - 1;
        fb.fillRect(x, detail_y, w, detail_panel_h, rgb(0xF8, 0xF8, 0xFC));
        fb.drawHLine(x, detail_y, w, rgb(0xD0, 0xD0, 0xD5));

        if (display.getExplorerSelectedEntry()) |entry| {
            // 显示选中文件的图标
            icons.drawThemedIcon(entry.icon, x + 8, detail_y + 8, 2, .aero, false);

            // 显示文件名
            const name_slice = entry.name[0..entry.name_len];
            fb.drawTextTransparent(x + 48, detail_y + 8, name_slice, rgb(0x10, 0x10, 0x10));

            // 显示类型和大小
            var size_buf: [32]u8 = undefined;
            const size_txt = display.getExplorerSelectedEntrySize(&size_buf);
            const type_txt: []const u8 = if (entry.is_directory) "文件夹" else "文件";
            const info_txt = if (size_txt.len > 0)
                std.fmt.bufPrint(&mui_scratch, "{s} | {s}", .{ type_txt, size_txt }) catch type_txt
            else
                type_txt;
            fb.drawTextTransparent(x + 48, detail_y + 28, info_txt, rgb(0x50, 0x58, 0x60));

            // 显示修改时间
            const date_txt = entry.date[0..entry.date_len];
            fb.drawTextTransparent(x + 48, detail_y + 44, date_txt, rgb(0x50, 0x58, 0x60));
        }
    }
}

fn explorerLibrariesNavRowHilite(row_index: usize) bool {
    if (row_index == 9 and display.getExplorerLocation() == .computer_root) return true;
    display.explorerEnsureVolumeSnapshot();
    const vols = display.explorerVolumes();
    if (row_index >= 10 and row_index < 10 + vols.len) {
        switch (display.getExplorerLocation()) {
            .drive_root => |L| {
                const u = explorerNavLetterUpper(L);
                return vols[row_index - 10].letter == u;
            },
            else => {},
        }
    }
    return false;
}

fn drawExplorerLibNavLine(
    win_x: i32,
    ny: *i32,
    row_index: *usize,
    body_bottom: i32,
    nav_w: i32,
    label: []const u8,
    indent: i32,
    heading: bool,
    icon_id: icons.IconId,
) void {
    const ri = row_index.*;
    const row_h: i32 = if (heading) 18 else 16;
    if (ny.* + row_h > body_bottom) return;
    const hilite = explorerLibrariesNavRowHilite(ri);
    if (hilite) {
        fb.fillRect(win_x + 2, ny.*, nav_w - 4, row_h, rgb(0xD8, 0xE8, 0xF8));
        fb.drawRect(win_x + 2, ny.*, nav_w - 4, row_h, rgb(0xA8, 0xC8, 0xE0));
    }
    const tc: u32 = if (heading) rgb(0x50, 0x58, 0x60) else if (hilite) rgb(0x00, 0x3C, 0x80) else rgb(0x18, 0x18, 0x18);
    const ixl = win_x + 4 + indent;
    const iy = ny.* + if (heading) @as(i32, 1) else @as(i32, 0);
    icons.drawThemedIcon(icon_id, ixl, iy, 1, .aero, false);
    fb.drawTextTransparent(ixl + 18, ny.*, label, tc);
    ny.* += row_h;
    row_index.* += 1;
}

/// Win7「库」视图：命令栏、圆形导航钮、面包屑与搜索、侧栏分区、四库大图标与状态栏。
fn renderExplorerLibrariesClient(x: i32, y: i32, w: i32, h: i32, t: *const theme.ThemeColors) void {
    _ = t;
    var lib_mui: [1]u8 = undefined;
    const Ll = display.explorerLibrariesClientLayout(w, h);
    const cmd_h = Ll.cmd_h;
    const addr_h = Ll.addr_h;
    const status_h = Ll.status_h;

    fb.drawGradientH(x, y, w, cmd_h, rgb(0xF2, 0xF4, 0xF8), rgb(0xE4, 0xE8, 0xF0));
    fb.drawHLine(x, y + cmd_h, w, rgb(0xB8, 0xC4, 0xD4));
    const cmd_ty = y + @divTrunc(cmd_h - 14, 2);
    const org = shell_mui.loadString(.ex_lib_organize, &lib_mui);
    const nl = shell_mui.loadString(.ex_lib_new_lib, &lib_mui);
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
    icons.drawThemedIcon(.folder, field_x + 4, addr_y + 5, 1, .aero, false);
    var lib_addr_buf: [120]u8 = undefined;
    const crumb = explorer_format.formatAddressBar(&lib_addr_buf, .libraries, 0);
    fb.drawTextTransparent(field_x + 24, addr_y + @divTrunc(addr_h - 14, 2), crumb, rgb(0x00, 0x00, 0x00));

    fb.fillRect(search_x, addr_y + 3, search_w, 20, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(search_x, addr_y + 3, search_w, 20, rgb(0x9C, 0xA8, 0xB8));
    const sh = shell_mui.loadString(.ex_lib_search, &lib_mui);
    fb.drawTextTransparent(search_x + 6, addr_y + @divTrunc(addr_h - 14, 2), sh, rgb(0x78, 0x80, 0x88));

    const body_y = addr_y + addr_h;
    const body_h = Ll.body_h;
    if (body_h <= 10) return;

    const nav_w = Ll.nav_w;
    fb.fillRect(x, body_y, nav_w, body_h, rgb(0xFC, 0xFC, 0xFE));
    fb.drawVLine(x + nav_w, body_y, body_h, rgb(0xC8, 0xD0, 0xD8));

    var ny: i32 = body_y + 6;
    var lri: usize = 0;
    const body_bottom = body_y + body_h;
    var lib_vol_buf: [48]u8 = undefined;

    display.explorerEnsureVolumeSnapshot();
    const lib_vols = display.explorerVolumes();

    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_nav_fav, &lib_mui), 0, true, .favorites);
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_desktop, &lib_mui), 8, false, .shell_desktop);
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_downloads, &lib_mui), 8, false, .downloads);
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_recent, &lib_mui), 8, false, .recent_places);
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_nav_lib, &lib_mui), 0, true, .library_root);
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_documents, &lib_mui), 8, false, .documents);
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_music, &lib_mui), 8, false, .music);
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_pictures, &lib_mui), 8, false, .pictures);
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_videos, &lib_mui), 8, false, .videos);
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_nav_comp, &lib_mui), 0, true, .computer);
    for (lib_vols) |v| {
        const vlab = explorer_format.formatDriveNavLabel(&lib_vol_buf, v.letter);
        drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, vlab, 8, false, v.iconId());
    }
    drawExplorerLibNavLine(x, &ny, &lri, body_bottom, nav_w, shell_mui.loadString(.ex_lib_nav_net, &lib_mui), 0, true, .network);

    const list_x = x + nav_w + 1;
    const list_w = w - nav_w - 1;
    fb.fillRect(list_x, body_y, list_w, body_h, rgb(0xFF, 0xFF, 0xFF));

    fb.drawTextTransparent(list_x + 24, body_y + 16, shell_mui.loadString(.ex_lib_title, &lib_mui), rgb(0x12, 0x18, 0x22));
    fb.drawTextTransparent(list_x + 24, body_y + 36, shell_mui.loadString(.ex_lib_subtitle, &lib_mui), rgb(0x50, 0x58, 0x60));

    const tile: i32 = 88;
    const gap: i32 = 32;
    const grid_w = 2 * tile + gap;
    const gx0 = list_x + @max(24, @divTrunc(list_w - grid_w, 2));
    const gy0 = body_y + 80;
    const libs = [_]struct { label: []const u8, icon: icons.IconId }{
        .{ .label = shell_mui.loadString(.ex_lib_videos, &lib_mui), .icon = .videos },
        .{ .label = shell_mui.loadString(.ex_lib_pictures, &lib_mui), .icon = .pictures },
        .{ .label = shell_mui.loadString(.ex_lib_documents, &lib_mui), .icon = .documents },
        .{ .label = shell_mui.loadString(.ex_lib_music, &lib_mui), .icon = .music },
    };
    for (libs, 0..) |lib, i| {
        const col: i32 = @intCast(i % 2);
        const row: i32 = @intCast(i / 2);
        const ix = gx0 + col * (tile + gap);
        const iy = gy0 + row * (tile + gap);
        fb.blendTintRect(ix, iy + 28, tile, 28, rgb(0x58, 0x88, 0xC8), 35, 200);
        icons.drawThemedIcon(lib.icon, ix + @divTrunc(tile - 32, 2), iy + 8, 2, .aero, false);
        const tw = fb.textWidth(lib.label);
        fb.drawTextTransparent(ix + @divTrunc(tile - tw, 2), iy + tile - 14, lib.label, rgb(0x10, 0x14, 0x1A));
    }

    const status_y = display.clampI32FromI64(@as(i64, y) + @as(i64, h) - @as(i64, status_h));
    fb.fillRect(x, status_y, w, status_h, rgb(0xE8, 0xEE, 0xF6));
    fb.drawHLine(x, status_y, w, rgb(0xC0, 0xC8, 0xD4));
    fb.drawTextTransparent(x + 8, status_y + 4, shell_mui.loadString(.ex_lib_status, &lib_mui), rgb(0x30, 0x38, 0x42));
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

/// 拖动时修补壁纸后重新绘制桌面图标和任务栏（避免图标/任务栏被壁纸覆盖后消失）。
/// 主题参数由调用方从 `theme.getActiveTheme()` 传入，避免在 patch 函数内重复获取。
fn patchDragOverlays(scr_w: i32, scr_h: i32, t: *const theme.ThemeColors, tb_h: i32) void {
    display.renderDesktopIcons(scr_w, scr_h, t);
    renderTaskbar(scr_w, scr_h, t, tb_h);
}
