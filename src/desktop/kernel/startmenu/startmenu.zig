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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/kernel/startmenu/startmenu.zig
// Purpose: Windows 7-style Start Menu (two columns, search, power flyout, optional All Programs panel).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/ (shell UX / public API names only).

//! Windows 7 风格开始菜单（NT 6.1 Shell 布局）

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const icons = @import("../icons/root.zig");
const klog = @import("../../../rtl/klog.zig");
const dwm = @import("../../../drivers/video/core/dwm.zig");
const shell_strings = @import("../strings/shell_strings.zig");
const app_cfg = @import("../../../config/config.zig");
const builtin_apps = @import("../shell/builtin_apps.zig");
const kernel32 = @import("../../../libs/kernel32.zig");

fn drawMenuIcon(id: icons.IconId, x: i32, y: i32, size_or_scale: i32) void {
    if (size_or_scale <= 0) {
        icons.drawThemedIcon(id, x, y, 0, .aero, false);
    } else {
        icons.drawSvgIconBySize(id, x, y, @as(u32, @intCast(size_or_scale)), @as(u32, @intCast(size_or_scale)));
    }
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

/// 左列固定程序列表（精简版：保留最常用的核心应用）
const aero7_left = [_]MenuItem{
    .{ .label = "Internet Explorer", .icon_id = .browser, .bold = true },
    .{ .label = "Zircon Media Player", .icon_id = .music, .separator_after = true },
    .{ .label = "Terminal", .icon_id = .terminal },
    .{ .label = "Notepad", .icon_id = .text_editor },
    .{ .label = "Calculator", .icon_id = .calculator },
    .{ .label = "Snipping Tool", .icon_id = .pictures },
};
/// Win7 右列：库 → 游戏 → 计算机/控制面板/帮助。
const aero7_right = [_]MenuItem{
    .{ .label = "Documents", .icon_id = .documents, .bold = true },
    .{ .label = "Pictures", .icon_id = .pictures, .bold = true },
    .{ .label = "Music", .icon_id = .music, .bold = true },
    .{ .label = "Games", .icon_id = .folder, .separator_after = true },
    .{ .label = "Computer", .icon_id = .computer, .bold = true },
    .{ .label = "Control Panel", .icon_id = .control_panel },
    .{ .label = "Help and Support", .icon_id = .settings, .separator_after = true },
};

pub fn getLeftMenuItems() []const MenuItem {
    return aero7_left[0..];
}

pub fn getRightMenuItems() []const MenuItem {
    return aero7_right[0..];
}

/// Win7 开始菜单布局常量（两栏设计）
/// ┌─────────────────────────┬───────────────────┐
/// │ 左侧程序列表 (228px)     │ 右侧用户/链接 (200px)│
/// │ - 小图标程序列表          │ - 用户头像 (右上角方块)│
/// │ - All Programs          │ - 用户名            │
/// │ - 搜索框 (底部)         │ - 库链接            │
/// │                         │ - 系统链接          │
/// │                         │ - 关机按钮          │
/// └─────────────────────────┴───────────────────┘
const MENU_W: i32 = 428; // 总宽度
const LEFT_COL_W: i32 = 228; // 左侧程序列表宽度
const RIGHT_COL_W: i32 = 200; // 右侧用户/链接宽度
const ROW_H: i32 = 28; // 程序行高度（小图标模式，与 Win7 一致）
const ICON_SIZE: i32 = 24; // 程序图标尺寸（16-24px）
const AVATAR_SIZE: i32 = 48; // 头像尺寸（椭圆形）
const AVATAR_BOX_SIZE: i32 = 52; // 头像方块尺寸
const SEARCH_H: i32 = 26; // 搜索框高度
const BOTTOM_H: i32 = 40; // 底部区域高度
const CORNER_R: i32 = 8; // 圆角半径

/// 大屏下 Win7 风格主面板目标高度（固定常量，用于边界检测）
const MENU_TARGET_HEIGHT: i32 = 480;

/// 底部：仅 Win7 式「关机」主按钮 + 右侧箭头（注销/睡眠/重启等均在飞出菜单内）。
const IDX_FOOT_SHUTDOWN_BTN: i32 = 201;
const IDX_FOOT_SHUTDOWN_CHEVRON: i32 = 204;

/// 左列视图状态：`pinned` 时显示固定程序列表，'all_programs' 时显示可滚动程序列表。
const LeftPaneView = enum(u8) {
    pinned,
    all_programs,
};

/// 电源弹出层（Switch user … Shut down）
const IDX_FLYOUT_BASE: i32 = 300;
/// 「返回」行（仅在 all_programs 视图下出现）。
const IDX_BACK: i32 = 50;
/// 「所有程序」列表行基索引。
const IDX_ALLPROG_BASE: i32 = 60;
/// All Programs 行索引。
const IDX_ALL: i32 = 48;

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
/// 左列视图状态（替换原 all_programs_open 侧栏语义）：pinned=固定列表，all_programs=程序列表。
var left_pane_view: LeftPaneView = .pinned;
/// all_programs 视图下的滚动行索引（0..ALL_PROG_COUNT-1），超过可视行数时自动钳位。
var all_prog_scroll_row: i32 = 0;
const ALL_PROG_COUNT: i32 = @intCast(builtin_apps.allProgramsCount());

// ========== 动画系统 ==========
/// 动画状态
const AnimState = enum {
    hidden,
    opening,
    open,
    closing,
};

/// 开始菜单展开/收起动画状态
var anim_state: AnimState = .hidden;
/// 动画进度：0.0（完全收起）到 1.0（完全展开）
var anim_progress: f32 = 0.0;
/// 目标菜单高度（用于动画计算）
var anim_target_h: i32 = 0;
/// 动画开始时的菜单高度
var anim_start_h: i32 = 0;
/// 基准菜单高度（由屏幕高度决定，在 show() 时设置，之后不再改变）
var aero_base_h: i32 = 0;

/// 电源弹出菜单滑动动画状态
var flyout_anim_progress: f32 = 0.0;
var flyout_anim_target_x: i32 = 0;
var flyout_anim_start_x: i32 = 0;

/// 悬停平滑过渡状态
/// 当前显示的悬停索引（带平滑过渡）
var hover_display_index: i32 = -1;
/// 悬停过渡进度（0.0 到 1.0）
var hover_transition_progress: f32 = 1.0;
/// 悬停过渡帧数
const HOVER_TRANSITION_FRAMES: u8 = 3;

/// 鼠标轨迹插值状态（用于快速移动时防漏检）
var last_hover_px: i32 = -1;
var last_hover_py: i32 = -1;
var hover_interp_active: bool = false;
var interp_step: u8 = 0;
const INTERP_STEPS: u8 = 4;

/// 开始 Orb 悬停状态（用于发光效果）
var orb_hover_progress: f32 = 0.0;
var orb_pressed: bool = false;
var orb_press_progress: f32 = 0.0;

/// Toggle 节流机制：防止快速连击导致状态混乱
var last_toggle_tick: u32 = 0;
const TOGGLE_THROTTLE_MS: u32 = 20; // Further reduced to 20ms for better click responsiveness

/// 动画持续时间（帧数，约 200ms @ 60fps）
const ANIM_FRAMES: u8 = 12;
/// 子菜单滑动动画帧数（约 100ms）
const SUBMENU_ANIM_FRAMES: u8 = 6;

/// 计算 ease-out 缓动曲线：快速启动，缓慢收尾
fn easeOutProgress(t: f32) f32 {
    return 1.0 - (1.0 - t) * (1.0 - t);
}

/// 获取当前动画进度对应的菜单高度
fn animCurrentHeight() i32 {
    const diff = @as(i64, anim_target_h) - @as(i64, anim_start_h);
    return anim_start_h + @as(i32, @intFromFloat(@as(f32, @floatFromInt(diff)) * easeOutProgress(anim_progress)));
}

/// 根据给定目标高度计算当前动画高度
fn animCurrentHeightFrom(target_h: i32) i32 {
    const diff = @as(i64, target_h) - @as(i64, anim_start_h);
    return anim_start_h + @as(i32, @intFromFloat(@as(f32, @floatFromInt(diff)) * easeOutProgress(anim_progress)));
}

pub fn isVisible() bool {
    return menu_visible or anim_state == .opening or anim_state == .closing;
}

/// 开始菜单是否完全展开（用于交互）
pub fn isFullyOpen() bool {
    return anim_state == .open and anim_progress >= 1.0;
}

pub fn show(_: MenuStyle) void {
    menu_visible = true;
    hover_index = -1;
    hover_prev_for_partial_repaint = -1;
    hover_display_index = -1;
    hover_transition_progress = 1.0;
    last_hover_px = -1;
    last_hover_py = -1;
    hover_interp_active = false;
    interp_step = 0;
    orb_hover_progress = 0.0;
    orb_pressed = false;
    orb_press_progress = 0.0;
    power_flyout_open = false;
    left_pane_view = .pinned;
    all_prog_scroll_row = 0;
    // 不重置 menu_frames_since_open（已删除），透明度由动画状态决定
    search_len = 0;
    search_hover_cached_bounds = null;
    search_hover_cache_tick = 0;

    // 无条件重置动画状态：每次打开都从完全收起状态开始展开
    // 这是防止多次点击导致状态混乱的关键
    anim_start_h = 0;
    anim_target_h = MENU_TARGET_HEIGHT;
    aero_base_h = MENU_TARGET_HEIGHT;
    anim_state = .opening;
    anim_progress = 0.0;

    // 初始化子菜单动画状态
    flyout_anim_progress = 0.0;
}

pub fn hide() void {
    // 启动关闭动画（保持可见直到动画完成）
    if (anim_state == .hidden) {
        // 菜单已经隐藏，标记为不可见
        menu_visible = false;
    } else {
        // 设置关闭动画：从当前高度开始收起
        anim_start_h = animCurrentHeight();
        anim_target_h = 0;
        anim_state = .closing;
    }
    // 无条件重置所有状态（视图状态是 UI 语义，不应依赖于动画状态）
    hover_index = -1;
    hover_prev_for_partial_repaint = -1;
    hover_display_index = -1;
    hover_transition_progress = 1.0;
    last_hover_px = -1;
    last_hover_py = -1;
    hover_interp_active = false;
    interp_step = 0;
    orb_hover_progress = 0.0;
    orb_pressed = false;
    orb_press_progress = 0.0;
    power_flyout_open = false;
    left_pane_view = .pinned; // 无条件重置视图状态
    all_prog_scroll_row = 0; // 无条件重置滚动状态
    search_len = 0;
    search_hover_cached_bounds = null;
    search_hover_cache_tick = 0;
    // 注意：menu_frames_since_open（已删除），透明度由动画状态决定
    // 这样每次打开菜单时，轻量渲染模式不会每次都重复
}

/// 每帧调用以推进动画状态
pub fn updateAnimation() void {
    switch (anim_state) {
        .hidden => {},
        .opening => {
            anim_progress += 1.0 / @as(f32, @floatFromInt(ANIM_FRAMES));
            if (anim_progress >= 1.0) {
                anim_progress = 1.0;
                anim_state = .open;
            }
            menu_visible = true;
        },
        .open => {
            menu_visible = true;
        },
        .closing => {
            anim_progress -= 1.0 / @as(f32, @floatFromInt(ANIM_FRAMES));
            if (anim_progress <= 0.0) {
                anim_progress = 0.0;
                anim_state = .hidden;
                menu_visible = false;
            }
        },
    }

    // 更新电源弹出菜单滑动动画（保持滑动效果）
    if (power_flyout_open) {
        if (flyout_anim_progress < 1.0) {
            flyout_anim_progress += 1.0 / @as(f32, @floatFromInt(SUBMENU_ANIM_FRAMES));
            if (flyout_anim_progress > 1.0) flyout_anim_progress = 1.0;
        }
    } else {
        if (flyout_anim_progress > 0.0) {
            flyout_anim_progress -= 1.0 / @as(f32, @floatFromInt(SUBMENU_ANIM_FRAMES));
            if (flyout_anim_progress < 0.0) flyout_anim_progress = 0.0;
        }
    }

    // 更新悬停平滑过渡：只在当前过渡已完成时才接受新目标
    // 防止快速悬停变化导致立即跳变
    if (hover_index != hover_display_index) {
        if (hover_transition_progress >= 1.0) {
            hover_display_index = hover_index;
            hover_transition_progress = 0.0;
        }
        // 目标改变时不要立即跳变，等待过渡完成
    }
    // 过渡进度始终推进（使用 ease-out 缓动）
    if (hover_transition_progress < 1.0) {
        hover_transition_progress += 1.0 / @as(f32, @floatFromInt(HOVER_TRANSITION_FRAMES));
        if (hover_transition_progress >= 1.0) {
            hover_transition_progress = 1.0;
            hover_display_index = hover_index;
        }
    }

    // 更新鼠标轨迹插值
    if (hover_interp_active and interp_step < INTERP_STEPS) {
        interp_step += 1;
        if (interp_step >= INTERP_STEPS) {
            hover_interp_active = false;
            interp_step = 0;
        }
    }

    // 更新 Orb 悬停动画
    if (orb_hover_progress < 1.0) {
        orb_hover_progress += 1.0 / @as(f32, @floatFromInt(HOVER_TRANSITION_FRAMES));
        if (orb_hover_progress > 1.0) orb_hover_progress = 1.0;
    }

    // 更新 Orb 按压动画
    if (orb_pressed) {
        if (orb_press_progress < 1.0) {
            orb_press_progress += 1.0 / 3.0;
            if (orb_press_progress > 1.0) orb_press_progress = 1.0;
        }
    } else {
        if (orb_press_progress > 0.0) {
            orb_press_progress -= 1.0 / 6.0;
            if (orb_press_progress < 0.0) orb_press_progress = 0.0;
        }
    }
}

/// 更新鼠标位置并检查是否需要插值
pub fn updateMousePosition(px: i32, py: i32, _: i32, _: i32) void {
    if (px != last_hover_px or py != last_hover_py) {
        // 鼠标位置变化，启动插值
        last_hover_px = px;
        last_hover_py = py;
        interp_step = 0;
        hover_interp_active = true;
    }
}

/// 获取当前应该显示的悬停索引
pub fn getHoverDisplayIndex() i32 {
    return hover_display_index;
}

/// 设置 Orb 悬停状态
pub fn setOrbHover(hovering: bool) void {
    if (hovering) {
        orb_hover_progress = 0.0; // 开始悬停动画
    } else {
        orb_hover_progress = 1.0; // 停止悬停效果
    }
}

/// 设置 Orb 按压状态
pub fn setOrbPressed(pressed: bool) void {
    orb_pressed = pressed;
}

/// 获取 Orb 按压状态
pub fn isOrbPressed() bool {
    return orb_pressed;
}

/// 获取 Orb 悬停进度
pub fn getOrbHoverProgress() f32 {
    return orb_hover_progress;
}

/// 获取 Orb 按压进度
pub fn getOrbPressProgress() f32 {
    return orb_press_progress;
}

/// 获取当前动画进度（0.0 到 1.0）
pub fn getAnimProgress() f32 {
    return anim_progress;
}

/// 菜单是否正在执行动画
pub fn isAnimating() bool {
    return anim_state == .opening or anim_state == .closing;
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
    if (anim_state == .hidden) return false;
    const arch = @import("../../../arch.zig");
    var dirty = false;
    while (arch.readInputChar()) |c| {
        if (c == 0x1B) { // ESC 键：关闭菜单
            hide();
            return true;
        } else if (c == 0x0D) { // Enter 键：执行当前悬停项
            return true;
        } else if (c == 0x08 or c == 127) { // 退格键
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

/// 获取当前动画状态
pub fn getAnimState() AnimState {
    return anim_state;
}

pub fn toggle(_: MenuStyle) void {
    // 节流：快速连击时播放 Orb 按压动画，但不切换菜单
    const now = kernel32.GetTickCount();
    if (now -% last_toggle_tick < TOGGLE_THROTTLE_MS) {
        setOrbPressed(true);
        return;
    }
    last_toggle_tick = now;

    // 简化状态机：菜单打开时关闭，关闭时打开
    // 动画进行中（opening/closing）时也允许切换，但用 hide/show 处理
    if (anim_state == .open or anim_state == .opening) {
        // 菜单正在显示，关闭它
        if (@import("build_options").desktop_bisect) {
            klog.debug("startmenu: toggle → hide (state={})", .{@tagName(anim_state)});
        }
        hide();
    } else {
        // 菜单隐藏或正在关闭，打开它
        if (@import("build_options").desktop_bisect) {
            klog.debug("startmenu: toggle → show (state={})", .{@tagName(anim_state)});
        }
        show(.aero);
    }
}

/// 键盘导航：向上移动选择
pub fn navigateUp() void {
    if (anim_state == .hidden) return;
    const current = hover_index;
    const left_len = @as(i32, @intCast(aero7_left.len));
    const right_len = @as(i32, @intCast(aero7_right.len));

    if (current < 0) {
        hover_index = 0;
    } else if (left_pane_view == .all_programs) {
        // all_programs 视图：程序行 ↔ 返回行。
        if (current >= IDX_ALLPROG_BASE and current < IDX_ALLPROG_BASE + ALL_PROG_COUNT) {
            if (current > IDX_ALLPROG_BASE) {
                hover_index = current - 1;
            } else {
                // 循环到最后一个程序项
                hover_index = IDX_ALLPROG_BASE + ALL_PROG_COUNT - 1;
            }
        } else if (current == IDX_BACK) {
            hover_index = IDX_ALLPROG_BASE + ALL_PROG_COUNT - 1;
        } else if (current == IDX_ALL) {
            hover_index = IDX_ALLPROG_BASE + ALL_PROG_COUNT - 1;
        }
    } else {
        // pinned 视图。
        if (current >= 0 and current < left_len) {
            if (current > 0) {
                hover_index = current - 1;
            } else {
                // 已在左列第一项，循环到右列最后一项
                hover_index = 100 + right_len - 1;
            }
        } else if (current == IDX_ALL) {
            hover_index = left_len - 1;
        } else if (current >= 100 and current < IDX_FLYOUT_BASE) {
            const ri = current - 100;
            if (ri > 0) {
                hover_index = current - 1;
            } else {
                // 已在右列第一项，循环到左列最后一项
                hover_index = left_len - 1;
            }
        }
    }
    updateHoverTransition();
}

/// 键盘导航：向下移动选择
pub fn navigateDown() void {
    if (anim_state == .hidden) return;
    const current = hover_index;
    const left_len = @as(i32, @intCast(aero7_left.len));
    const right_len = @as(i32, @intCast(aero7_right.len));

    if (current < 0) {
        hover_index = 0;
    } else if (left_pane_view == .all_programs) {
        // all_programs 视图：程序行 ↔ 返回行。
        if (current >= IDX_ALLPROG_BASE and current < IDX_ALLPROG_BASE + ALL_PROG_COUNT - 1) {
            hover_index = current + 1;
        } else if (current == IDX_ALLPROG_BASE + ALL_PROG_COUNT - 1) {
            // 循环到第一项
            hover_index = IDX_ALLPROG_BASE;
        } else if (current == IDX_BACK) {
            hover_index = IDX_ALLPROG_BASE;
        } else if (current == IDX_ALL) {
            hover_index = IDX_ALLPROG_BASE;
        } else if (current < IDX_ALLPROG_BASE) {
            hover_index = IDX_ALLPROG_BASE;
        }
    } else {
        // pinned 视图。
        if (current >= 0 and current < left_len - 1) {
            hover_index = current + 1;
        } else if (current == left_len - 1) {
            // 左列最后一项，移动到 IDX_ALL
            hover_index = IDX_ALL;
        } else if (current == IDX_ALL) {
            hover_index = 100;
        } else if (current >= 100 and current < 100 + right_len - 1) {
            hover_index = current + 1;
        } else if (current == 100 + right_len - 1) {
            // 右列最后一项，循环到左列第一项
            hover_index = 0;
        } else if (current == IDX_FOOT_SHUTDOWN_BTN) {
            hover_index = 100;
        }
    }
    updateHoverTransition();
}

/// 键盘导航：向左移动（切换到左列）
pub fn navigateLeft() void {
    if (anim_state == .hidden) return;
    const current = hover_index;

    if (left_pane_view == .all_programs) {
        // all_programs 视图：返回行。
        if (current == IDX_BACK or (current >= IDX_ALLPROG_BASE and current < IDX_ALLPROG_BASE + ALL_PROG_COUNT)) {
            hover_index = IDX_BACK;
        }
    } else {
        if (current >= 100 and current < IDX_FLYOUT_BASE) {
            hover_index = IDX_ALL;
        } else if (current == IDX_ALL) {
            hover_index = @as(i32, @intCast(aero7_left.len)) - 1;
        }
    }
    updateHoverTransition();
}

/// 键盘导航：向右移动（切换到右列）
pub fn navigateRight() void {
    if (anim_state == .hidden) return;
    const current = hover_index;

    if (left_pane_view == .all_programs) {
        // all_programs 视图下右侧无独立区，移到右列第一项。
        hover_index = 100;
    } else {
        if (current >= 0 and current < aero7_left.len) {
            hover_index = 100;
        } else if (current == IDX_ALL) {
            hover_index = 100;
        }
    }
    updateHoverTransition();
}

/// 执行当前选中项
pub fn executeSelectedItem(scr_w: i32, scr_h: i32) MenuAction {
    if (!isFullyOpen()) return .none;
    return handleAero7MenuClick(0, 0, scr_w, scr_h);
}

/// 更新悬停过渡状态：只在当前过渡已完成时才接受新目标
fn updateHoverTransition() void {
    if (hover_index != hover_display_index and hover_transition_progress >= 1.0) {
        hover_transition_progress = 0.0;
        hover_display_index = hover_index;
    }
}

pub fn setHoverIndex(idx: i32) void {
    hover_index = idx;
}

pub fn pointerHoverIndex() i32 {
    return hover_index;
}

fn aeroRect(scr_h: i32) MenuRect {
    const sh64 = @as(i64, scr_h);
    const base_h = @as(i64, aero_base_h);
    // 根据屏幕高度限制最大高度
    const max_h64 = @min(base_h, @max(40, sh64 - 8));
    const h: i32 = @intCast(std.math.clamp(max_h64, 40, @as(i64, std.math.maxInt(i32))));
    const w: i32 = 428;
    const y64 = sh64 - 40 - @as(i64, h);
    const yy: i32 = @intCast(std.math.clamp(y64, std.math.minInt(i32), std.math.maxInt(i32)));
    return .{ .x = 0, .y = yy, .w = w, .h = h };
}

/// 带动画的主面板矩形计算
/// 注意：此函数不再修改 anim_target_h，动画进度由 show()/hide() 统一管理
fn aeroRectWithAnim(scr_h: i32) MenuRect {
    const sh64 = @as(i64, scr_h);
    const base_h = @as(i64, aero_base_h);
    // 根据屏幕高度限制最大高度
    const max_h64 = @min(base_h, @max(40, sh64 - 8));
    const target_h: i32 = @intCast(std.math.clamp(max_h64, 40, @as(i64, std.math.maxInt(i32))));
    // 使用动画进度计算当前高度
    const h = animCurrentHeightFrom(target_h);
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

/// 主面板矩形：使用固定目标高度（用于点击边界检测）
pub fn getMenuRect(scr_w: i32, scr_h: i32) MenuRect {
    _ = scr_w;
    const sh64 = @as(i64, scr_h);
    // 使用固定目标高度，不依赖 aero_base_h
    const h = MENU_TARGET_HEIGHT;
    const w: i32 = 428;
    const y64 = sh64 - 40 - @as(i64, h);
    const yy: i32 = @intCast(std.math.clamp(y64, std.math.minInt(i32), std.math.maxInt(i32)));
    return .{ .x = 0, .y = yy, .w = w, .h = h };
}

fn menuCornerRadius() i32 {
    const r = app_cfg.getStartMenuCornerRadius();
    return @intCast(@max(4, @min(r, 24)));
}

/// 主菜单 + 电源飞出（点击区外关闭用）。
/// Win7 风格下「所有程序」视图切换不外扩面板，始终返回主面板矩形。
pub fn getInteractiveBounds(scr_w: i32, scr_h: i32) MenuRect {
    var u = aeroRectWithAnim(scr_h);
    if (power_flyout_open) u = rectUnion(u, powerFlyoutRect(scr_w, scr_h));
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
    const left_col_end_y = leftColumnBottomY(content_y, all_prog_y);
    // 右侧栏项目起始 Y = 用户名下方
    const right_content_start_y = content_y + 4 + 14 + 8;

    // 固定索引（pinned/all_programs 视图均存在）。
    if (idx >= 0 and idx < aero7_left.len) {
        return hoverIndexRowBoundsLeft(scr_h, idx, content_y, all_prog_y, main_x, split_x);
    }
    if (idx >= 100 and idx < IDX_FLYOUT_BASE) {
        const ri = idx - 100;
        if (ri < 0 or ri >= aero7_right.len) return null;
        return hoverIndexRowBoundsRight(scr_h, @intCast(ri), bottom_y, split_x, main_x, main_w, right_content_start_y);
    }
    if (idx == IDX_BACK) {
        // 「返回」行：左列底部。
        return .{
            .x = main_x + 4,
            .y = left_col_end_y - ROW_H - 2,
            .w = LEFT_COL_W - 8,
            .h = ROW_H,
        };
    }
    if (idx == IDX_ALL) {
        return .{
            .x = main_x + 4,
            .y = all_prog_y - 1,
            .w = LEFT_COL_W - 8,
            .h = ROW_H,
        };
    }
    if (idx == IDX_FOOT_SHUTDOWN_BTN) {
        // 关机按钮（Win7 风格按钮）
        const sd_x = main_x + main_w - 106;
        const sd_y = bottom_y + @divTrunc(BOTTOM_H - 28, 2);
        return .{ .x = sd_x, .y = sd_y, .w = 106, .h = 28 };
    }
    if (idx >= IDX_FLYOUT_BASE + 1 and idx <= IDX_FLYOUT_BASE + 7) {
        const fr = powerFlyoutRect(scr_w, scr_h);
        const row = idx - (IDX_FLYOUT_BASE + 1);
        const row_h: i32 = 22;
        const iy = fr.y + 3 + row * row_h;
        return .{ .x = fr.x + 3, .y = iy - 1, .w = fr.w - 6, .h = row_h };
    }
    // all_programs 视图下的程序行：在左列内渲染，使用左列几何。
    if (idx >= IDX_ALLPROG_BASE and idx < IDX_ALLPROG_BASE + ALL_PROG_COUNT) {
        const row_i = idx - IDX_ALLPROG_BASE;
        var iy: i32 = content_y + 8;
        var i: i32 = 0;
        while (i < ALL_PROG_COUNT) : (i += 1) {
            if (!menuItemMatchesSearch(allProgEntryLabel(i))) continue;
            if (i == row_i) {
                return .{
                    .x = main_x + 4,
                    .y = iy,
                    .w = LEFT_COL_W - 8,
                    .h = ROW_H,
                };
            }
            iy += ROW_H;
        }
        return null;
    }
    return null;
}

fn hoverIndexRowBoundsLeft(_: i32, li_target: i32, content_y: i32, all_prog_y: i32, main_x: i32, _: i32) ?MenuRect {
    var iy: i32 = content_y + 8;
    for (aero7_left, 0..) |item, li| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (iy + ROW_H > all_prog_y - 2) break;
        if (@as(i32, @intCast(li)) == li_target) {
            return .{
                .x = main_x + 4,
                .y = iy,
                .w = LEFT_COL_W - 8,
                .h = ROW_H,
            };
        }
        iy += ROW_H;
        if (search_len == 0 and item.separator_after) {
            iy += 6;
            if (li + 1 == pinned_left_count) iy += 4;
        }
    }
    return null;
}

fn hoverIndexRowBoundsRight(_: i32, ri: usize, bottom_y: i32, split_x: i32, _: i32, main_w: i32, right_start_y: i32) ?MenuRect {
    var iy: i32 = right_start_y;
    for (aero7_right, 0..) |item, rj| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (iy + ROW_H > bottom_y - 6) break;
        if (rj == ri) {
            return .{
                .x = split_x + 2,
                .y = iy,
                .w = main_w - LEFT_COL_W - 4,
                .h = ROW_H,
            };
        }
        iy += ROW_H;
        if (search_len == 0 and item.separator_after) iy += 6;
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
    const r = getMenuRect(scr_h, scr_h);
    const rx = @as(i64, r.x);
    const ry = @as(i64, r.y);
    const rw = @as(i64, r.w);
    const rh = @as(i64, r.h);
    const inner_x = clampMenuI32(rx + 4);
    const inner_y = clampMenuI32(ry + 4);
    const inner_w = @max(0, clampMenuI32(rw - 8));
    const inner_h = @max(0, clampMenuI32(rh - 8));
    const rail: i64 = 0; // No left rail in Win7 two-column layout
    const main_x = clampMenuI32(@as(i64, inner_x) + rail);
    const main_w = @max(0, clampMenuI32(@as(i64, inner_w) - rail));
    // 左列内容从顶部开始（无 header 区）
    const content_y = inner_y;
    const mid_raw = @as(i64, inner_h) - @as(i64, BOTTOM_H);
    const mid_h = @max(0, clampMenuI32(mid_raw));
    const bottom_y = clampMenuI32(@as(i64, inner_y) + @as(i64, inner_h) - @as(i64, BOTTOM_H));
    const foot_y = bottom_y;
    const search_y = bottom_y;
    const split_x = clampMenuI32(@as(i64, main_x) + @as(i64, LEFT_COL_W));
    // All Programs 行在内容区底部
    const all_prog_y = clampMenuI32(@as(i64, content_y) + @as(i64, mid_h) - @as(i64, ROW_H) - 6);
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
    if (pxi < @as(i64, main_x) + 4 or pxi >= @as(i64, split_x) or
        pyi < @as(i64, content_y) + 6 or pyi >= @as(i64, all_prog_y)) return -1;
    var iy = @as(i64, content_y) + 8;
    const row = @as(i64, ROW_H);
    for (aero7_left, 0..) |item, li| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (pyi >= iy and pyi < iy + row) return @intCast(li);
        iy += row;
        if (search_len == 0 and item.separator_after) {
            iy += 6;
            if (li + 1 == pinned_left_count) iy += 4;
        }
    }
    return -1;
}

fn rightColumnHoverIndex(px: i32, py: i32, bottom_y: i32, split_x: i32, main_x: i32, main_w: i32, right_start_y: i32) i32 {
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    if (pxi < @as(i64, split_x) + 2 or pxi >= @as(i64, main_x) + @as(i64, main_w) - 2 or
        pyi < @as(i64, right_start_y) or pyi >= @as(i64, bottom_y) - 4) return -1;
    var iy = @as(i64, right_start_y);
    const row = @as(i64, ROW_H);
    for (aero7_right, 0..) |item, ri| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (pyi >= iy and pyi < iy + row) return 100 + @as(i32, @intCast(ri));
        iy += row;
        if (search_len == 0 and item.separator_after) iy += 6;
    }
    return -1;
}

/// 计算 pinned 视图下左列内容底部 Y 坐标（含「所有程序」行高度）。
fn leftColumnBottomY(_: i32, all_prog_y: i32) i32 {
    return all_prog_y + ROW_H + 2;
}

/// 在 all_programs 视图下计算左列底部 Y（含「返回」行）。
fn allProgramsLeftBottomY(_: i32, all_prog_y: i32) i32 {
    return all_prog_y + ROW_H + 2;
}

/// all_programs 视图下左列内程序列表悬停索引（使用左列几何，非侧栏）。
fn allProgramsLeftHoverIndex(px: i32, py: i32, content_y: i32, left_end_y: i32, main_x: i32, split_x: i32) i32 {
    const pxi = @as(i64, px);
    const pyi = @as(i64, py);
    if (pxi < @as(i64, main_x) + 4 or pxi >= @as(i64, split_x) or
        pyi < @as(i64, content_y) + 6 or pyi >= @as(i64, left_end_y) - @as(i64, ROW_H) - 2) return -1;
    var iy = @as(i64, content_y) + 8;
    var i: i32 = 0;
    while (i < ALL_PROG_COUNT) : (i += 1) {
        if (!menuItemMatchesSearch(allProgEntryLabel(i))) continue;
        if (pyi >= iy and pyi < iy + @as(i64, ROW_H)) return IDX_ALLPROG_BASE + i;
        iy += @as(i64, ROW_H);
    }
    return -1;
}

fn flyoutAnimX(scr_w: i32, scr_h: i32) i32 {
    const L = innerLayout(scr_h);
    const flyout_w: i32 = 176;
    const sd_x = clampMenuI32(@as(i64, L.main_x) + @as(i64, L.main_w) - 116);
    var fx = clampMenuI32(@as(i64, sd_x) + 108);
    const sw = @as(i64, scr_w);
    if (@as(i64, fx) + @as(i64, flyout_w) > sw - 2) {
        fx = @max(2, clampMenuI32(sw - 2 - @as(i64, flyout_w)));
    }
    const r = aeroRectWithAnim(scr_h);
    if (fx < r.x) fx = r.x;

    // 计算滑动动画偏移：从右侧滑入
    const anim_offset = @as(i32, @intFromFloat(@as(f32, @floatFromInt(flyout_w)) * (1.0 - easeOutProgress(flyout_anim_progress))));
    return fx - anim_offset;
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
    const r = aeroRectWithAnim(scr_h);
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
    // 允许在展开过程中检测悬停，提供流畅的交互体验
    // 只有完全隐藏时才跳过
    if (anim_state == .hidden) return false;
    const prev = hover_index;
    hover_index = aero7HoverIndex(px, py, scr_w, scr_h);
    if (prev != hover_index) {
        hover_prev_for_partial_repaint = prev;
    }
    return prev != hover_index;
}

fn aero7HoverIndex(px: i32, py: i32, scr_w: i32, scr_h: i32) i32 {
    const r = aeroRectWithAnim(scr_h);
    const in_flyout = power_flyout_open and powerFlyoutRect(scr_w, scr_h).contains(px, py);
    if (!r.contains(px, py) and !in_flyout) {
        return -1;
    }

    if (power_flyout_open) {
        const fh = powerFlyoutHoverIndex(px, py, scr_w, scr_h);
        if (fh >= 0) return fh;
    }

    const L = innerLayout(scr_h);
    const main_x = L.main_x;
    const main_w = L.main_w;
    const content_y = L.content_y;
    const bottom_y = L.bottom_y;
    const split_x = L.split_x;
    const all_prog_y = L.all_prog_y;
    const left_col_end_y = leftColumnBottomY(content_y, all_prog_y);
    // 右侧栏项目起始 Y = 用户名下方
    const right_content_start_y = content_y + 4 + 14 + 8;

    const pyi = @as(i64, py);
    const pxi = @as(i64, px);

    // 底栏：关机按钮。
    if (pyi >= @as(i64, bottom_y) and pyi < @as(i64, L.inner_y) + @as(i64, L.inner_h)) {
        // 关机按钮（Win7 风格按钮）
        const sd_y = @as(i64, bottom_y) + @divTrunc(BOTTOM_H - 28, 2);
        if (pyi >= sd_y and pyi < sd_y + 28) {
            const sd_x = @as(i64, main_x) + @as(i64, main_w) - 106;
            if (pxi >= sd_x and pxi < sd_x + 106) {
                return IDX_FOOT_SHUTDOWN_BTN;
            }
        }
        return -1;
    }

    // all_programs 视图：左列渲染程序列表 + 底部「返回」。
    if (left_pane_view == .all_programs) {
        // 底部「返回」行。
        if (pyi >= @as(i64, left_col_end_y) - @as(i64, ROW_H) - 2 and
            pyi < @as(i64, left_col_end_y) and
            pxi >= @as(i64, main_x) + 4 and pxi < @as(i64, split_x))
            return IDX_BACK;

        // 程序列表行（左列内，带滚动偏移计算）。
        const ap = allProgramsLeftHoverIndex(px, py, content_y, left_col_end_y, main_x, split_x);
        if (ap >= 0) return ap;

        // all_programs 视图中点击右列仍可命中右列项（视图切换后右列不动）。
    }

    // pinned 视图或 all_programs 视图的右列：底部「所有程序」行（pinned 专用）。
    if (left_pane_view == .pinned and
        pyi >= @as(i64, all_prog_y) and pyi < @as(i64, all_prog_y) + @as(i64, ROW_H) and
        pxi >= @as(i64, main_x) + 4 and pxi < @as(i64, split_x))
        return IDX_ALL;

    // pinned 视图：左列固定列表。
    if (left_pane_view == .pinned) {
        const lh = leftColumnHoverIndex(px, py, content_y, all_prog_y, main_x, split_x);
        if (lh >= 0) return lh;
    }

    // 右列（两种视图均存在）。
    const rh = rightColumnHoverIndex(px, py, bottom_y, split_x, main_x, main_w, right_content_start_y);
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
    if (h == IDX_FOOT_SHUTDOWN_BTN) return .shutdown;

    // all_programs 视图：点击「返回」切回 pinned。
    if (left_pane_view == .all_programs) {
        if (h == IDX_BACK) {
            left_pane_view = .pinned;
            return .none;
        }
        if (h >= IDX_ALLPROG_BASE and h < IDX_ALLPROG_BASE + ALL_PROG_COUNT) {
            builtin_apps.launch(builtin_apps.allProgramsId(@intCast(h - IDX_ALLPROG_BASE)));
            return .none;
        }
        // all_programs 视图下点右列项仍可触发。
    }

    // pinned 视图行为。
    if (h >= 0 and h < aero7_left.len) {
        builtin_apps.launch(switch (@as(usize, @intCast(h))) {
            0 => .ie8,
            1 => .wmp,
            2 => .cmd_shell,
            3 => .notepad,
            4 => .calculator,
            5 => .paint,
            6 => .wordpad,
            7 => .snipping_tool,
            8 => .taskmgr_focus,
            9 => .control_panel,
            else => .generic_stub,
        });
        return .none;
    }
    // 点击「所有程序」进入 all_programs 视图（单向切换，不再 toggle）。
    if (h == IDX_ALL) {
        left_pane_view = .all_programs;
        all_prog_scroll_row = 0;
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
                11 => .generic_stub,
                12 => .disk_cleanup,
                13 => .shell_help,
                14 => .shell_run,
                else => .generic_stub,
            };
            builtin_apps.launch(app);
        }
    }
    return .none;
}

pub fn handleMenuClick(px: i32, py: i32, scr_w: i32, scr_h: i32) MenuAction {
    // 只要菜单可见（包含动画展开/关闭过程）就处理点击，提供即时反馈
    if (!isVisible()) return .none;
    // 使用完整高度进行边界检测，而不是动画高度
    const r = getMenuRect(scr_w, scr_h);
    if (!r.contains(px, py)) return .none;
    if (@import("build_options").desktop_bisect) {
        klog.debug("startmenu: click (%d,%d) scr %d x %d", .{ px, py, scr_w, scr_h });
    }
    return handleAero7MenuClick(px, py, scr_w, scr_h);
}

fn drawPowerFlyout(scr_w: i32, scr_h: i32) void {
    const fr = powerFlyoutRect(scr_w, scr_h);
    // 应用滑动动画
    const anim_x = flyoutAnimX(scr_w, scr_h);
    const text_dark = rgb(0x18, 0x1C, 0x22);
    const text_white = rgb(0xFF, 0xFF, 0xFF);
    const sep = rgb(0xB8, 0xC4, 0xD4);
    const row_h: i32 = 22;
    const cr = @max(4, menuCornerRadius() - 2);
    const labels = shell_strings.powerFlyoutLabels();

    fb.fillRoundedRect(anim_x, fr.y, fr.w, fr.h, cr, rgb(0xF2, 0xF4, 0xF8));
    fb.draw3DRect(anim_x, fr.y, fr.w, fr.h, rgb(0xFF, 0xFF, 0xFF), rgb(0x70, 0x80, 0x90));
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(anim_x + 1, fr.y + 1, fr.w - 2, fr.h - 2, rgb(0x40, 0x58, 0x70), .panel);
    }

    var iy: i32 = fr.y + 3;
    for (labels, 0..) |label, i| {
        const idx: i32 = IDX_FLYOUT_BASE + 1 + @as(i32, @intCast(i));
        const row_r = hover_display_index == idx;
        if (row_r) {
            fb.blendTintRect(anim_x + 3, iy - 1, fr.w - 6, row_h, rgb(0x70, 0x98, 0xC8), 55, 255);
            fb.drawTextTransparentUi(anim_x + 10, iy + 4, label, text_white);
        } else {
            fb.drawTextTransparentUi(anim_x + 10, iy + 4, label, text_dark);
        }
        iy += row_h;
        if (i == 0 or i == 2 or i == 5) {
            fb.drawHLine(anim_x + 6, iy - 1, fr.w - 12, sep);
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

/// 绘制开始 Orb（Windows 图标）— 使用预光栅化 SVG start_orb.rgba
/// orb_hover: 悬停进度（0.0 到 1.0）
/// orb_press: 按压进度（0.0 到 1.0，1.0 表示完全按下）
fn drawOrbGraphic(ox: i32, oy: i32, orb_hover: f32, orb_press: f32) void {
    const display_size: i32 = 36;
    // 添加Aero发光效果，根据hover进度
    const glow_size = display_size + 8 + @as(i32, @intFromFloat(orb_hover * 4.0));
    const glow_alpha = @as(u8, @intFromFloat(60.0 + orb_hover * 80.0)); // 更亮的Aero发光效果
    const glow_r = @divTrunc(glow_size, 2);
    const r_sq = glow_r * glow_r;
    const center_x = ox + @divTrunc(display_size, 2);
    const center_y = oy + @divTrunc(display_size, 2);
    var y: i32 = -glow_r;
    while (y < glow_r) : (y += 1) {
        var x: i32 = -glow_r;
        while (x < glow_r) : (x += 1) {
            const dist_sq = x * x + y * y;
            if (dist_sq <= r_sq) {
                const alpha = glow_alpha - @as(u8, @intFromFloat(@as(f32, @floatFromInt(dist_sq)) / @as(f32, @floatFromInt(r_sq)) * 40.0));
                fb.blendTintRect(center_x + x, center_y + y, 1, 1, rgb(0x40, 0xA0, 0xFF), alpha, 255); // 更鲜艳的Aero蓝色发光
            }
        }
    }
    icons.drawStartOrb(ox, oy, display_size, orb_hover, orb_press);
}

pub fn render(scr_w: i32, scr_h: i32) void {
    if (!fb.isInitialized()) return;

    // 更新动画状态
    updateAnimation();

    // 如果完全隐藏，不再渲染
    if (anim_state == .hidden) return;

    // 注意：透明度现在由动画状态（anim_progress）决定，不再依赖帧计数器

    // 使用固定高度进行渲染，确保与边界检测一致
    _ = getMenuRect(scr_w, scr_h);
    const L = innerLayout(scr_h);

    const text_dark = rgb(0x18, 0x1C, 0x22);
    const text_dim = rgb(0x50, 0x58, 0x62);
    const sep = rgb(0xB8, 0xC4, 0xD4);
    const cr = menuCornerRadius();

    const inner_x = L.inner_x;
    const inner_y = L.inner_y;
    const inner_w = L.inner_w;
    const inner_h = L.inner_h;

    // ========== Aero 投影效果 ==========
    const shadow_size = 8;
    const shadow_color = rgb(0, 0, 0);
    // 右侧和底部投影
    var s: i32 = 0;
    while (s < shadow_size) : (s += 1) {
        const alpha = @as(u8, @intCast(30 - @divTrunc(30 * s, shadow_size)));
        // 右侧阴影
        fb.blendTintRect(inner_x + inner_w + s, inner_y + shadow_size, 1, inner_h, shadow_color, alpha, 255);
        // 底部阴影
        fb.blendTintRect(inner_x + shadow_size, inner_y + inner_h + s, inner_w, 1, shadow_color, alpha, 255);
    }

    // ========== Aero 玻璃效果 ==========
    // 使用 DWM 玻璃模糊效果（如果启用）
    const glass_bg_color = rgb(0xF8, 0xFC, 0xFF); // 更亮的Aero玻璃效果，减少暗色
    if (dwm.isGlassEnabled()) {
        dwm.renderGlassEffect(inner_x, inner_y, inner_w, inner_h, glass_bg_color, .panel);
    } else {
        fb.fillRoundedRect(inner_x, inner_y, inner_w, inner_h, cr, glass_bg_color);
    }
    // Aero 高光边框（顶部和左侧）
    fb.blendTintRect(inner_x, inner_y, inner_w, 2, rgb(0xFF, 0xFF, 0xFF), 60, 200);
    fb.blendTintRect(inner_x, inner_y, 2, inner_h, rgb(0xFF, 0xFF, 0xFF), 40, 180);

    const main_x = L.main_x;
    const main_w = L.main_w;
    const split_x = L.split_x;
    const content_y = L.content_y;
    const bottom_y = L.bottom_y;

    // ========== 左列：白色背景程序列表 ==========
    const left_bg_color = rgb(0xF8, 0xF9, 0xFC);
    fb.fillRect(main_x, content_y, LEFT_COL_W, bottom_y - content_y, left_bg_color);
    // 左列顶部高光线
    fb.blendTintRect(main_x, content_y, LEFT_COL_W, 1, rgb(0xFF, 0xFF, 0xFF), 80, 200);

    // ========== 右列：渐变蓝色用户区 ==========
    const right_col_w = main_w - LEFT_COL_W;
    const right_bg_top = rgb(0xF0, 0xF8, 0xFF); // 更亮的渐变，符合Aero效果
    const right_bg_bottom = rgb(0xE0, 0xF0, 0xFA); // 更亮的渐变，减少暗色
    fb.drawGradientV(split_x, content_y, right_col_w, bottom_y - content_y, right_bg_top, right_bg_bottom);
    // 右列左侧分隔线（渐变效果）
    fb.drawVLine(split_x, content_y, bottom_y - content_y, rgb(0xB8, 0xC4, 0xD4));

    // ========== 头像区域（正方形，一半在菜单外，一半在菜单内，右侧居中）==========
    // 头像尺寸：64x64 正方形
    const av_sq_size: i32 = 64;
    // 头像在右列内水平居中
    const av_x = split_x + @divTrunc(right_col_w - av_sq_size, 2);
    // 头像中心与菜单顶部对齐，一半在菜单内，一半在菜单外
    const av_center_y = content_y;
    const av_top_y = av_center_y - @divTrunc(av_sq_size, 2);
    const av_bottom_y = av_center_y + @divTrunc(av_sq_size, 2);
    const av_icon_r = @divTrunc(av_sq_size, 2);

    // 头像正方形背景（灰色边框 + 浅色填充）
    // 正方形一半在菜单内（底部），一半在菜单外（顶部）
    fb.fillRect(av_x, av_top_y, av_sq_size, av_sq_size, rgb(0xA0, 0xA8, 0xB0));
    fb.fillRect(av_x + 1, av_top_y + 1, av_sq_size - 2, av_sq_size - 2, rgb(0xF8, 0xF8, 0xF8));

    // 圆形头像：圆心在 av_bottom_y（菜单顶部），半径为 32
    // 圆形的下半部分在菜单内，上半部分在菜单外
    const r_sq = av_icon_r * av_icon_r;
    var cy2: i32 = 0;
    while (cy2 < av_sq_size) : (cy2 += 1) {
        const dx_sq = (cy2 - av_icon_r) * (cy2 - av_icon_r);
        var cx2: i32 = 0;
        while (cx2 < av_sq_size) : (cx2 += 1) {
            const dy_sq = (cx2 - av_icon_r) * (cx2 - av_icon_r);
            if (dx_sq + dy_sq <= r_sq) {
                const px = av_x + cx2;
                const py = av_top_y + cy2;
                // 绘制整个圆形，一半在菜单内，一半在菜单外
                fb.putPixel32(@intCast(px), @intCast(py), rgb(0xD8, 0xE8, 0xF8));
            }
        }
    }
    // 头像圆形边框（亮边）
    const r_inner_sq = (av_icon_r - 1) * (av_icon_r - 1);
    const r_outer_sq = (av_icon_r - 2) * (av_icon_r - 2);
    var cy3: i32 = 0;
    while (cy3 < av_sq_size) : (cy3 += 1) {
        const dx_sq = (cy3 - av_icon_r) * (cy3 - av_icon_r);
        var cx3: i32 = 0;
        while (cx3 < av_sq_size) : (cx3 += 1) {
            const dy_sq = (cx3 - av_icon_r) * (cx3 - av_icon_r);
            const d2 = dx_sq + dy_sq;
            if (d2 <= r_inner_sq and d2 > r_outer_sq) {
                const px = av_x + cx3;
                const py = av_top_y + cy3;
                // 绘制整个圆形边框，一半在菜单内，一半在菜单外
                fb.putPixel32(@intCast(px), @intCast(py), rgb(0xB8, 0xD0, 0xE8));
            }
        }
    }

    // 用户图标在圆形头像内（居中）
    const av_icon_x = av_x + av_icon_r - 12;
    const av_icon_y = av_top_y + av_icon_r - 12;
    drawMenuIcon(.user, av_icon_x, av_icon_y, 2);

    // 用户名（在头像下方，菜单内）
    const disp_name = app_cfg.getStartMenuUserDisplayName();
    const name_y = av_bottom_y + 4;
    const name_w = fb.textWidth(disp_name);
    const name_x = av_x + @divTrunc(av_sq_size - name_w, 2);
    fb.drawTextTransparentUi(name_x, name_y, disp_name, text_dark);

    // ========== 左列：程序列表 ==========
    const all_prog_y = L.all_prog_y;
    const icon_cell: i32 = 14; // 图标尺寸（缩小到14px，与Win7比例协调）

    // 左列：根据视图状态渲染 pinned 程序列表 或 all_programs 程序列表。
    if (left_pane_view == .pinned) {
        var iy: i32 = content_y + 8;
        for (aero7_left, 0..) |item, li| {
            if (!menuItemMatchesSearch(item.label)) continue;
            if (iy + ROW_H > all_prog_y - 2) break;
            const row_r = hover_display_index == @as(i32, @intCast(li));
            if (row_r) {
                fb.fillRoundedRect(main_x + 4, iy, LEFT_COL_W - 8, ROW_H, 4, rgb(0xCC, 0xDD, 0xF0));
            }
            // 图标（14px，与行高协调）
            const icon_x = main_x + 8;
            const icon_y = iy + @divTrunc(ROW_H - icon_cell, 2);
            if (item.icon_id) |iid| {
                drawMenuIcon(iid, icon_x, icon_y, icon_cell);
            }
            // 文字
            const text_x = main_x + 8 + icon_cell + 6;
            const tc = if (row_r) text_dark else if (item.bold) text_dark else text_dim;
            fb.drawTextTransparentUi(text_x, iy + @divTrunc(ROW_H - 14, 2), item.label, tc);
            iy += ROW_H;
            if (search_len == 0 and item.separator_after) {
                fb.drawHLine(main_x + 8, iy + 2, LEFT_COL_W - 16, sep);
                iy += 6;
                if (li + 1 == pinned_left_count) iy += 4;
            }
        }

        fb.drawHLine(main_x + 8, all_prog_y - 2, LEFT_COL_W - 16, sep);
        const ap_hov = hover_display_index == IDX_ALL;
        const all_prog_lbl = shell_strings.startmenuLine("all_programs");
        if (ap_hov) {
            fb.fillRoundedRect(main_x + 4, all_prog_y - 1, LEFT_COL_W - 8, ROW_H, 4, rgb(0xCC, 0xDD, 0xF0));
            fb.drawTextTransparentUi(main_x + 36, all_prog_y + @divTrunc(ROW_H - 14, 2), all_prog_lbl, text_dark);
            fb.drawTextTransparentUi(main_x + LEFT_COL_W - 24, all_prog_y + @divTrunc(ROW_H - 14, 2), ">", text_dim);
        } else {
            fb.drawTextTransparentUi(main_x + 36, all_prog_y + @divTrunc(ROW_H - 14, 2), all_prog_lbl, rgb(0x20, 0x50, 0x88));
            fb.drawTextTransparentUi(main_x + LEFT_COL_W - 24, all_prog_y + @divTrunc(ROW_H - 14, 2), ">", text_dim);
        }
    } else {
        // all_programs 视图：在左列内渲染程序列表，底部「返回」行。
        var iy: i32 = content_y + 6;
        var i: i32 = 0;
        while (i < ALL_PROG_COUNT) : (i += 1) {
            const lab = allProgEntryLabel(i);
            if (!menuItemMatchesSearch(lab)) continue;
            if (iy + ROW_H > all_prog_y) break;
            const idx = IDX_ALLPROG_BASE + i;
            const row_r = hover_display_index == idx;
            if (row_r) {
                fb.fillRoundedRect(main_x + 4, iy, LEFT_COL_W - 8, ROW_H, 4, rgb(0xCC, 0xDD, 0xF0));
                fb.drawTextTransparentUi(main_x + 36, iy + @divTrunc(ROW_H - 14, 2), lab, text_dark);
            } else {
                fb.drawTextTransparentUi(main_x + 36, iy + @divTrunc(ROW_H - 14, 2), lab, text_dim);
            }
            iy += ROW_H;
        }

        // 底部「返回」行：Win7 左箭头 + "Back" 文案。
        const back_bottom_y = leftColumnBottomY(content_y, all_prog_y);
        const back_hov = hover_display_index == IDX_BACK;
        const back_lbl = shell_strings.startmenuLine("back");
        if (back_hov) {
            fb.fillRoundedRect(main_x + 4, back_bottom_y - ROW_H - 2, LEFT_COL_W - 8, ROW_H, 4, rgb(0xCC, 0xDD, 0xF0));
            fb.drawTextTransparentUi(main_x + 36, back_bottom_y - ROW_H + @divTrunc(ROW_H - 14, 2), back_lbl, text_dark);
            fb.drawTextTransparentUi(main_x + LEFT_COL_W - 24, back_bottom_y - ROW_H + @divTrunc(ROW_H - 14, 2), "<", text_dim);
        } else {
            fb.drawTextTransparentUi(main_x + 36, back_bottom_y - ROW_H + @divTrunc(ROW_H - 14, 2), back_lbl, rgb(0x20, 0x50, 0x88));
            fb.drawTextTransparentUi(main_x + LEFT_COL_W - 24, back_bottom_y - ROW_H + @divTrunc(ROW_H - 14, 2), "<", text_dim);
        }
    }

    // ========== 右列：库链接 ==========
    // 右列内容从用户名下方开始（头像下方）
    const right_content_start_y = av_bottom_y + 4 + 14 + 8;
    const right_icon_cell: i32 = 14; // 与左列图标尺寸一致
    const icon_col_x = split_x + 10;
    const text_cell_x = icon_col_x + right_icon_cell + 6;
    const right_bold = rgb(0x10, 0x38, 0x78);
    const right_norm = rgb(0x40, 0x40, 0x40);

    // 右侧栏项目
    var iy: i32 = right_content_start_y;
    for (aero7_right, 0..) |item, ri| {
        if (!menuItemMatchesSearch(item.label)) continue;
        if (iy + ROW_H > bottom_y - 6) break;
        const row_r = hover_display_index == 100 + @as(i32, @intCast(ri));
        const icon_y = iy + @divTrunc(ROW_H - right_icon_cell, 2);
        if (row_r) {
            fb.fillRoundedRect(split_x + 2, iy, RIGHT_COL_W - 4, ROW_H, 4, rgb(0xCC, 0xDD, 0xF0));
            if (item.icon_id) |iid| {
                drawMenuIcon(iid, icon_col_x, icon_y, right_icon_cell);
            }
            const tc = if (item.bold) rgb(0x00, 0x30, 0x70) else rgb(0x00, 0x00, 0x00);
            fb.drawTextTransparentUi(text_cell_x, iy + @divTrunc(ROW_H - 14, 2), item.label, tc);
        } else {
            if (item.icon_id) |iid| {
                drawMenuIcon(iid, icon_col_x, icon_y, right_icon_cell);
            }
            const tc = if (item.bold) right_bold else right_norm;
            fb.drawTextTransparentUi(text_cell_x, iy + @divTrunc(ROW_H - 14, 2), item.label, tc);
        }
        iy += ROW_H;
        if (search_len == 0 and item.separator_after) {
            fb.drawHLine(split_x + 6, iy + 2, RIGHT_COL_W - 12, sep);
            iy += 6;
        }
    }

    fb.drawHLine(main_x, bottom_y, main_w, sep);

    // ========== 搜索框 ==========
    const search_pad_x: i32 = 8;
    const search_y0 = bottom_y + @divTrunc(BOTTOM_H - SEARCH_H, 2);
    const mag_w: i32 = 20;
    const search_inner_w = LEFT_COL_W - search_pad_x * 2 - mag_w;
    fb.drawRect(main_x + search_pad_x, search_y0, search_inner_w + mag_w, SEARCH_H, rgb(0x98, 0xA8, 0xB8));
    fb.fillRect(main_x + search_pad_x + 1, search_y0 + 1, search_inner_w + mag_w - 2, SEARCH_H - 2, rgb(0xFF, 0xFF, 0xFF));
    const ph = shell_strings.startmenuLine("search_placeholder");
    if (search_len > 0) {
        fb.drawTextTransparentClipped(main_x + search_pad_x + 6, search_y0 + @divTrunc(SEARCH_H - 14, 2), main_x + search_pad_x + search_inner_w + 2, search_buf[0..search_len], rgb(0x20, 0x24, 0x2C));
    } else {
        fb.drawTextTransparentClipped(main_x + search_pad_x + 6, search_y0 + @divTrunc(SEARCH_H - 14, 2), main_x + search_pad_x + search_inner_w + 2, ph, rgb(0x98, 0xA0, 0xA8));
    }
    drawSearchMagnifier(main_x + search_pad_x + search_inner_w + 4, search_y0 + @divTrunc(SEARCH_H - 16, 2), rgb(0x70, 0x80, 0x90));

    // ========== 关机按钮（Win7 风格）==========
    const sd_x = main_x + main_w - 106;
    const sd_y = bottom_y + @divTrunc(BOTTOM_H - 28, 2);
    const sd_body_hov = hover_display_index == IDX_FOOT_SHUTDOWN_BTN;
    const sd_cr = @max(3, cr - 3);
    // Win7 Aero 透明凸起按钮：冷色玻璃 + 顶缘高光
    const sd_top = if (sd_body_hov) rgb(0xA8, 0xC8, 0xF0) else rgb(0x88, 0xA8, 0xD0);
    const sd_bot = if (sd_body_hov) rgb(0x58, 0x78, 0xA8) else rgb(0x48, 0x64, 0x90);
    fb.fillRoundedRect(sd_x, sd_y, 106, 28, sd_cr, sd_bot);
    fb.drawGradientV(sd_x + 1, sd_y + 1, 104, 26, sd_top, sd_bot);
    fb.blendTintRect(sd_x + 1, sd_y + 1, 104, 10, rgb(0xFF, 0xFF, 0xFF), if (sd_body_hov) 52 else 38, 200);
    fb.drawHLine(sd_x + 2, sd_y + 1, 102, rgb(0xF0, 0xF8, 0xFF));
    fb.blendTintRect(sd_x, sd_y, 106, 28, rgb(0x28, 0x40, 0x60), if (sd_body_hov) 18 else 12, 255);
    fb.drawRect(sd_x, sd_y, 106, 28, rgb(0xB8, 0xD0, 0xE8));
    fb.drawRect(sd_x + 1, sd_y + 1, 104, 26, rgb(0x40, 0x58, 0x70));
    fb.drawTextTransparentUiCenteredInRect(sd_x + 2, sd_y, 106, 28, shell_strings.startmenuLine("foot_shut_down"), rgb(0xFF, 0xFF, 0xFF));

    // 电源弹出菜单：即使未打开，只要有动画进度就渲染
    if (power_flyout_open or flyout_anim_progress > 0.0) {
        drawPowerFlyout(scr_w, scr_h);
    }
}
