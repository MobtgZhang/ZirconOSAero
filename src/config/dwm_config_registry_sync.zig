// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/config/dwm_config_registry_sync.zig
// Purpose: Pure helpers for HKLM\\DWM → `dwm.DwmConfig` 差异检测，驱动 `WM_DWM*` 广播决策（主机可测）。
//
// This is an independent clean-room implementation.
// Reference: docs/cn/DWM_NOTIFY_MODEL_NT61.md, src/drivers/video/dwm.zig `syncPolicyFromRegistry`

const std = @import("std");

/// 注册表同步路径会改写的、对壳层可见的 `DwmConfig` 子集（与 `dwm.syncPolicyFromRegistry` 一致）。
pub const RegistryVisibleDwmFields = struct {
    glass_tint_color: u32,
    glass_opacity: u8,
    glass_taskbar_tint_opacity: u8,
    peek_enabled: bool,
};

pub fn snapshotFromDwmConfig(cfg: anytype) RegistryVisibleDwmFields {
    return .{
        .glass_tint_color = cfg.glass_tint_color,
        .glass_opacity = cfg.glass_opacity,
        .glass_taskbar_tint_opacity = cfg.glass_taskbar_tint_opacity,
        .peek_enabled = cfg.peek_enabled,
    };
}

pub const RegistrySyncBroadcastHints = struct {
    /// 应投递 `WM_DWMCOLORIZATIONCOLORCHANGED`（染色 dword 变化）。
    colorization: bool,
    /// 应投递 `WM_DWMNCRENDERINGCHANGED`（不透明度 / 任务栏染色强度 / Aero Peek 等策略变化；非合成总开关）。
    nc_policy: bool,
};

/// 比较同步前后快照；**仅**在 `user32.getWindowCount() > 0` 时由 `dwm.syncPolicyFromRegistry` 消费（启动期无 HWND 豁免广播）。
pub fn broadcastHintsAfterRegistryApply(before: RegistryVisibleDwmFields, after: RegistryVisibleDwmFields) RegistrySyncBroadcastHints {
    return .{
        .colorization = before.glass_tint_color != after.glass_tint_color,
        .nc_policy = before.glass_opacity != after.glass_opacity or
            before.glass_taskbar_tint_opacity != after.glass_taskbar_tint_opacity or
            before.peek_enabled != after.peek_enabled,
    };
}

test "registry sync: no broadcast when unchanged" {
    const s: RegistryVisibleDwmFields = .{
        .glass_tint_color = 0x4068A0,
        .glass_opacity = 210,
        .glass_taskbar_tint_opacity = 88,
        .peek_enabled = true,
    };
    const h = broadcastHintsAfterRegistryApply(s, s);
    try std.testing.expect(!h.colorization);
    try std.testing.expect(!h.nc_policy);
}

test "registry sync: tint change requests colorization only" {
    const a: RegistryVisibleDwmFields = .{
        .glass_tint_color = 0x4068A0,
        .glass_opacity = 210,
        .glass_taskbar_tint_opacity = 88,
        .peek_enabled = true,
    };
    var b = a;
    b.glass_tint_color = 0x112233;
    const h = broadcastHintsAfterRegistryApply(a, b);
    try std.testing.expect(h.colorization);
    try std.testing.expect(!h.nc_policy);
}

test "registry sync: peek flip requests nc_policy only" {
    const a: RegistryVisibleDwmFields = .{
        .glass_tint_color = 0x4068A0,
        .glass_opacity = 210,
        .glass_taskbar_tint_opacity = 88,
        .peek_enabled = true,
    };
    var b = a;
    b.peek_enabled = false;
    const h = broadcastHintsAfterRegistryApply(a, b);
    try std.testing.expect(!h.colorization);
    try std.testing.expect(h.nc_policy);
}

test "registry sync: opacity bump can request both when tint also moved" {
    const a: RegistryVisibleDwmFields = .{
        .glass_tint_color = 0x111111,
        .glass_opacity = 200,
        .glass_taskbar_tint_opacity = 80,
        .peek_enabled = false,
    };
    const b: RegistryVisibleDwmFields = .{
        .glass_tint_color = 0x222222,
        .glass_opacity = 232,
        .glass_taskbar_tint_opacity = 96,
        .peek_enabled = false,
    };
    const h = broadcastHintsAfterRegistryApply(a, b);
    try std.testing.expect(h.colorization);
    try std.testing.expect(h.nc_policy);
}
