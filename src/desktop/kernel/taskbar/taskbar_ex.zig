// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! Taskbar rendering helpers extracted from `core/display.zig`.

const fb = @import("../../../drivers/video/core/framebuffer.zig");
const display_primitives = @import("../../../drivers/video/core/display/display_primitives.zig");
const theme_mod = @import("../theme/root.zig");
const icons = @import("../icons/root.zig");

const klog = @import("../../../rtl/klog.zig");

const rgb = display_primitives.rgb;
const clampI32FromI64 = display_primitives.clampI32FromI64;

var start_orb_hovered: bool = false;
var start_orb_hover_progress: f32 = 0.0;
var start_orb_pressed: bool = false;
var start_orb_press_progress: f32 = 0.0;

const HOVER_ANIM_FRAMES: f32 = 8.0;
const PRESS_ANIM_IN_FRAMES: f32 = 3.0;
const PRESS_ANIM_OUT_FRAMES: f32 = 6.0;

pub fn setStartOrbHovered(hovered: bool) void {
    start_orb_hovered = hovered;
}

pub fn setStartOrbPressed(pressed: bool) void {
    start_orb_pressed = pressed;
}

pub fn updateStartOrbAnimation() void {
    if (start_orb_hovered) {
        if (start_orb_hover_progress < 1.0) {
            start_orb_hover_progress += 1.0 / HOVER_ANIM_FRAMES;
            if (start_orb_hover_progress > 1.0) start_orb_hover_progress = 1.0;
        }
    } else {
        if (start_orb_hover_progress > 0.0) {
            start_orb_hover_progress -= 1.0 / HOVER_ANIM_FRAMES;
            if (start_orb_hover_progress < 0.0) start_orb_hover_progress = 0.0;
        }
    }

    if (start_orb_pressed) {
        if (start_orb_press_progress < 1.0) {
            start_orb_press_progress += 1.0 / PRESS_ANIM_IN_FRAMES;
            if (start_orb_press_progress > 1.0) start_orb_press_progress = 1.0;
        }
    } else {
        if (start_orb_press_progress > 0.0) {
            start_orb_press_progress -= 1.0 / PRESS_ANIM_OUT_FRAMES;
            if (start_orb_press_progress < 0.0) start_orb_press_progress = 0.0;
        }
    }
}

pub fn getStartOrbHoverProgress() f32 {
    return start_orb_hover_progress;
}

pub fn getStartOrbPressProgress() f32 {
    return start_orb_press_progress;
}

pub fn renderTaskbarClassicBackground(scr_w: i32, tb_y: i32, taskbar_h: i32, t: *const theme_mod.ThemeColors) void {
    fb.drawGradientV(0, tb_y, scr_w, taskbar_h, t.taskbar_top, t.taskbar_bottom);
    fb.drawHLine(0, tb_y, scr_w, t.tray_border);
}

pub fn renderStartButtonClassic(x: i32, y: i32, w: i32, h: i32, t: *const theme_mod.ThemeColors) void {
    fb.fillRoundedRect(x + 1, y + 1, w, h - 1, 6, t.start_btn_bottom);
    fb.fillRoundedRect(x, y, w, h - 1, 6, t.start_btn_top);
    fb.drawGradientV(x + 6, y + 2, w - 12, h - 4, t.start_btn_top, t.start_btn_bottom);

    renderZirconLogo(x + 8, y + 7);

    fb.drawTextTransparent(x + 28, y + 7, t.start_label, t.start_btn_text);
}

pub fn renderZirconLogo(x: i32, y: i32) void {
    const blue = rgb(0x3F, 0xA3, 0xD8);
    const dark = rgb(0x0A, 0x3A, 0x6A);
    const white = rgb(0xFF, 0xFF, 0xFF);
    fb.fillRect(x, y, 14, 14, blue);
    fb.fillRect(clampI32FromI64(@as(i64, x) + 1), clampI32FromI64(@as(i64, y) + 1), 12, 12, dark);
    fb.drawHLine(clampI32FromI64(@as(i64, x) + 3), clampI32FromI64(@as(i64, y) + 3), 8, white);
    var i: i32 = 0;
    while (i < 8) : (i += 1) {
        const pxi = @as(i64, x) + 10 - @as(i64, i);
        const pyi = @as(i64, y) + 4 + @as(i64, i);
        const pxc = clampI32FromI64(pxi);
        const pyc = clampI32FromI64(pyi);
        if (pxc >= 0 and pyc >= 0) {
            fb.putPixel32(@intCast(pxc), @intCast(pyc), white);
        }
    }
    fb.drawHLine(clampI32FromI64(@as(i64, x) + 3), clampI32FromI64(@as(i64, y) + 11), 8, white);
}

/// 渲染 Aero 风格开始 Orb 按钮（使用 SVG 版本 + 动画效果）
pub fn renderStartButtonAero(dest_x: i32, dest_y: i32, dest_size: i32) void {
    // 背景框：任务栏上的按钮区域（圆角矩形）
    fb.fillRoundedRect(dest_x, dest_y, dest_size, dest_size, 4, rgb(0xB8, 0xD0, 0xE8));
    fb.drawRoundedRectAA(dest_x, dest_y, dest_size, dest_size, 4, rgb(0x40, 0x68, 0x90));

    // 调用 icons.drawStartOrb() 渲染 SVG Orb（支持悬停/按压动画）
    icons.drawStartOrb(dest_x, dest_y, dest_size, start_orb_hover_progress, start_orb_press_progress);
}

pub fn renderSystemTrayClassic(
    scr_w: i32,
    tb_y: i32,
    tray_clock_w: i32,
    tray_h: i32,
    taskbar_h: i32,
    t: *const theme_mod.ThemeColors,
) void {
    const tray_w: i32 = tray_clock_w + 40;
    const tray_x = scr_w - tray_w;
    const tray_y = tb_y + @divTrunc(taskbar_h - tray_h, 2);

    fb.fillRect(tray_x, tray_y, tray_w, tray_h, t.tray_bg);
    fb.drawVLine(tray_x, tray_y, tray_h, t.tray_border);

    fb.drawTextTransparent(tray_x + 8, tray_y + 3, "12:00 PM", t.clock_text);
}
