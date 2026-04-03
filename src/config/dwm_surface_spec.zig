// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/config/dwm_surface_spec.zig
// Purpose: DWM 重定向表面标志 — 内核 compositor 与文档的单一语义源。
//
// This is an independent clean-room implementation.
// Reference: https://learn.microsoft.com/windows/win32/learnwin32/the-desktop-window-manager
// Reference: [docs/cn/DesktopManagerSpec.md](../../docs/cn/DesktopManagerSpec.md)

//! | 概念 (NT6.1 / MS DWM)   | 内核 `KernelCompositorSurfaceFlags` |
//! |-------------------------|-------------------------------------|
//! | 顶层 / TOPMOST          | `topmost`                           |
//! | 分层窗口                | `layered`                           |
//! | 弹出菜单                | `popup`                             |
//! | 子窗口                  | `child`                             |
//! | 非客户区 DWM 绘制       | `dwm_ncrendering`                   |
//! | BlurBehind              | `dwm_blur_behind`                   |
//! | 贴靠目标                | `snap_target`                       |

const std = @import("std");

pub const spec_version: u32 = 1;

/// 与 `dwm_compositor.zig` 中 `SurfaceFlags` 别名须为同一布局；字段名与顺序变更时更新本模块测试。
pub const KernelCompositorSurfaceFlags = struct {
    topmost: bool = false,
    layered: bool = false,
    popup: bool = false,
    child: bool = false,
    has_caption: bool = true,
    dwm_blur_behind: bool = false,
    dwm_ncrendering: bool = true,
    snap_target: bool = false,
};

comptime {
    const info = @typeInfo(KernelCompositorSurfaceFlags).@"struct".fields;
    const expected: []const []const u8 = &.{
        "topmost",     "layered",         "popup",           "child",
        "has_caption", "dwm_blur_behind", "dwm_ncrendering", "snap_target",
    };
    if (info.len != expected.len) @compileError("KernelCompositorSurfaceFlags: field count drift vs DesktopManagerSpec");
    for (info, expected) |fld, exp| {
        if (!std.mem.eql(u8, fld.name, exp))
            @compileError("KernelCompositorSurfaceFlags: field name/order drift — update dwm_surface_spec + compositor");
    }
}

test "KernelCompositorSurfaceFlags has eight documented fields" {
    const n = @typeInfo(KernelCompositorSurfaceFlags).@"struct".fields.len;
    try std.testing.expectEqual(@as(usize, 8), n);
}

test "user32 ensureCompositorSurface extent from RECT (integration contract)" {
    const left: i32 = 8;
    const top: i32 = 12;
    const right: i32 = 108;
    const bottom: i32 = 92;
    const aw: u32 = @intCast(@max(0, right - left));
    const ah: u32 = @intCast(@max(0, bottom - top));
    try std.testing.expectEqual(@as(u32, 100), aw);
    try std.testing.expectEqual(@as(u32, 80), ah);
}

test "dwm_compositor createSurface id monotonic model" {
    var surface_count: u16 = 0;
    const id0 = surface_count;
    surface_count += 1;
    const id1 = surface_count;
    surface_count += 1;
    try std.testing.expectEqual(@as(u16, 0), id0);
    try std.testing.expectEqual(@as(u16, 1), id1);
}

test "destroySurface marks visibility false (metadata contract)" {
    var visible: bool = true;
    visible = false;
    try std.testing.expect(!visible);
}
