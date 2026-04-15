// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// UI Components Root - 新 D3D10 DWM 的 UI 组件入口

const std = @import("std");

// UI 组件模块
pub const taskbar = @import("taskbar.zig");
pub const startmenu = @import("startmenu.zig");
pub const desktop = @import("desktop.zig");
pub const window_decorator = @import("window_decorator.zig");
pub const controls = @import("controls.zig");
pub const winlogon = @import("winlogon.zig");

// ============================================================================
// UI 组件版本信息
// ============================================================================

pub const UIVersion = struct {
    major: u32 = 1,
    minor: u32 = 0,
    patch: u32 = 0,
    name: []const u8 = "ZirconOS DWM UI Components",

    pub fn getVersion() UIVersion {
        return .{
            .major = 1,
            .minor = 0,
            .patch = 0,
            .name = "ZirconOS DWM UI Components",
        };
    }
};

pub fn getVersion() UIVersion {
    return UIVersion.getVersion();
}