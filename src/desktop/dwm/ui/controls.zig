// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// Controls - D3D10 渲染的基础 UI 控件
// 支持按钮、文本框、复选框、进度条等基础控件

const std = @import("std");
const theme = @import("../config/theme.zig");

// ============================================================================
// 控件状态
// ============================================================================

pub const ControlState = enum(u8) {
    normal,
    hovered,
    pressed,
    disabled,
    focused,
};

pub const ControlType = enum(u8) {
    button,
    textbox,
    checkbox,
    progressbar,
    slider,
    listbox,
};

// ============================================================================
// 基础控件
// ============================================================================

pub const Control = struct {
    id: u32,
    control_type: ControlType,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    state: ControlState,
    enabled: bool,
    visible: bool,
    text: []const u8,
};

// ============================================================================
// 按钮控件
// ============================================================================

pub const Button = struct {
    base: Control,
    is_default: bool,
};

pub fn createButton(id: u32, x: i32, y: i32, width: i32, height: i32, text: []const u8) Button {
    return .{
        .base = .{
            .id = id,
            .control_type = .button,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .state = .normal,
            .enabled = true,
            .visible = true,
            .text = text,
        },
        .is_default = false,
    };
}

// ============================================================================
// 文本框控件
// ============================================================================

pub const TextBox = struct {
    base: Control,
    max_length: usize,
    password_char: u8,
    read_only: bool,
    multiline: bool,
};

pub fn createTextBox(id: u32, x: i32, y: i32, width: i32, height: i32) TextBox {
    return .{
        .base = .{
            .id = id,
            .control_type = .textbox,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .state = .normal,
            .enabled = true,
            .visible = true,
            .text = "",
        },
        .max_length = 256,
        .password_char = 0,
        .read_only = false,
        .multiline = false,
    };
}

// ============================================================================
// 复选框控件
// ============================================================================

pub const CheckBox = struct {
    base: Control,
    checked: bool,
};

pub fn createCheckBox(id: u32, x: i32, y: i32, text: []const u8) CheckBox {
    return .{
        .base = .{
            .id = id,
            .control_type = .checkbox,
            .x = x,
            .y = y,
            .width = 100,
            .height = 20,
            .state = .normal,
            .enabled = true,
            .visible = true,
            .text = text,
        },
        .checked = false,
    };
}

// ============================================================================
// 进度条控件
// ============================================================================

pub const ProgressBar = struct {
    base: Control,
    min_value: i32,
    max_value: i32,
    current_value: i32,
    show_percentage: bool,
};

pub fn createProgressBar(id: u32, x: i32, y: i32, width: i32, height: i32) ProgressBar {
    return .{
        .base = .{
            .id = id,
            .control_type = .progressbar,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .state = .normal,
            .enabled = true,
            .visible = true,
            .text = "",
        },
        .min_value = 0,
        .max_value = 100,
        .current_value = 0,
        .show_percentage = false,
    };
}

pub fn setProgressValue(progress: *ProgressBar, value: i32) void {
    progress.current_value = @max(progress.min_value, @min(progress.max_value, value));
}

pub fn getProgressValue(progress: *const ProgressBar) i32 {
    return progress.current_value;
}

// ============================================================================
// 命中测试
// ============================================================================

pub fn hitTestControl(ctrl: *const Control, px: i32, py: i32) bool {
    if (!ctrl.visible) return false;
    return px >= ctrl.x and px < ctrl.x + ctrl.width and
        py >= ctrl.y and py < ctrl.y + ctrl.height;
}

// ============================================================================
// 状态管理
// ============================================================================

pub fn setControlState(ctrl: *Control, state: ControlState) void {
    ctrl.state = state;
}

pub fn enableControl(ctrl: *Control, enabled: bool) void {
    ctrl.enabled = enabled;
    ctrl.state = if (enabled) .normal else .disabled;
}

pub fn showControl(ctrl: *Control, visible: bool) void {
    ctrl.visible = visible;
}

// ============================================================================
// 工具函数
// ============================================================================

pub fn getButtonFaceColor(state: ControlState) u32 {
    return switch (state) {
        .normal => theme.button_face,
        .hovered => theme.theme.rgb(0xD8, 0xD8, 0xD8),
        .pressed => theme.theme.rgb(0xC0, 0xC0, 0xC0),
        .disabled => theme.theme.rgb(0xE0, 0xE0, 0xE0),
        .focused => theme.button_face,
    };
}

pub fn getTextColor(state: ControlState) u32 {
    return switch (state) {
        .normal => theme.theme.rgb(0x00, 0x00, 0x00),
        .hovered => theme.theme.rgb(0x00, 0x00, 0x00),
        .pressed => theme.theme.rgb(0x00, 0x00, 0x00),
        .disabled => theme.theme.rgb(0x80, 0x80, 0x80),
        .focused => theme.theme.rgb(0x00, 0x00, 0x00),
    };
}