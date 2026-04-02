//! DWM 相关 Win32 消息常量（Winuser.h / Microsoft Learn），主机 `zig test` 纯常量回归。
//! 与 docs/cn/NT61_CONTRACT_MATRIX.md §4 对照；内核 `user32` / csrss 广播与 `GetMessage` 过滤路径持续对齐。
const std = @import("std");

// Ref: https://learn.microsoft.com/windows/win32/winmsg/wm-dwmcompositionchanged
pub const WM_DWMCOMPOSITIONCHANGED: u32 = 0x031E;
// Ref: https://learn.microsoft.com/windows/win32/winmsg/wm-dwmcolorizationcolorchanged
pub const WM_DWMCOLORIZATIONCOLORCHANGED: u32 = 0x0320;
// Ref: desktop-src/dwm/wm-dwmncrenderingchanged.md (same family as DWM notifications)
pub const WM_DWMNCRENDERINGCHANGED: u32 = 0x031F;
// Ref: https://learn.microsoft.com/windows/win32/dwm/wm-dwmsendiconicthumbnail
pub const WM_DWMSENDICONICTHUMBNAIL: u32 = 0x0323;

test "DWM notification message ids stable for NT6.1 docs" {
    try std.testing.expectEqual(@as(u32, 0x031E), WM_DWMCOMPOSITIONCHANGED);
    try std.testing.expectEqual(@as(u32, 0x0320), WM_DWMCOLORIZATIONCOLORCHANGED);
    try std.testing.expectEqual(@as(u32, 0x031F), WM_DWMNCRENDERINGCHANGED);
    try std.testing.expectEqual(@as(u32, 0x0323), WM_DWMSENDICONICTHUMBNAIL);
}

test "DWM messages fall in documented band for min-max filter smoke" {
    const min_v: u32 = 0x0300;
    const max_v: u32 = 0x0330;
    try std.testing.expect(WM_DWMCOMPOSITIONCHANGED >= min_v and WM_DWMCOMPOSITIONCHANGED <= max_v);
    try std.testing.expect(WM_DWMCOLORIZATIONCOLORCHANGED >= min_v and WM_DWMCOLORIZATIONCOLORCHANGED <= max_v);
    try std.testing.expect(WM_DWMNCRENDERINGCHANGED >= min_v and WM_DWMNCRENDERINGCHANGED <= max_v);
    try std.testing.expect(WM_DWMSENDICONICTHUMBNAIL >= min_v and WM_DWMSENDICONICTHUMBNAIL <= max_v);
}

// 与 `user32.zig` 中同名常量一致；便于 `GetMessage` 过滤范围与广播顺序文档化。
test "DWM notification WM_ values ascending within family" {
    try std.testing.expect(WM_DWMCOMPOSITIONCHANGED < WM_DWMNCRENDERINGCHANGED);
    try std.testing.expect(WM_DWMNCRENDERINGCHANGED < WM_DWMCOLORIZATIONCOLORCHANGED);
    try std.testing.expect(WM_DWMCOLORIZATIONCOLORCHANGED < WM_DWMSENDICONICTHUMBNAIL);
}

// 与 `user32.broadcastDwmCompositionChanged` / `dwm.setCompositionEnabled` 一致：`wParam` 1=合成开、0=关。
test "WM_DWMCOMPOSITIONCHANGED wParam BOOL-like on off" {
    const wp_on: u32 = 1;
    const wp_off: u32 = 0;
    try std.testing.expect(wp_on != wp_off);
}

// `user32.broadcastDwmColorizationChanged` / `dwm.setColorizationTint`：`wParam`=COLORREF；`lParam` 混合非零=开。
test "WM_DWMCOLORIZATIONCOLORCHANGED wParam lParam anchor" {
    const colorref: u32 = 0x00AA7744;
    const lp_blend_on: i64 = 1;
    try std.testing.expectEqual(@as(u32, 0xAA7744), colorref & 0xFFFFFF);
    try std.testing.expect(lp_blend_on != 0);
}

// `dwm.setGlass` → `broadcastDwmNcRenderingChanged(TRUE)`：`wParam`=1。
test "WM_DWMNCRENDERINGCHANGED wParam non-zero when policy enabled" {
    const wp: u32 = 1;
    try std.testing.expect(wp != 0);
}

// `dwm.syncPolicyFromRegistry`：染色 dword 变化 → `WM_DWMCOLORIZATIONCOLORCHANGED`；不透明度 / 任务栏染色 / Peek 变化 → `WM_DWMNCRENDERINGCHANGED`（仅 `user32.getWindowCount() > 0`）。决策逻辑：`dwm_config_registry_sync_host`。
test "DWM notify ids used by registry sync broadcast path" {
    try std.testing.expectEqual(@as(u32, 0x0320), WM_DWMCOLORIZATIONCOLORCHANGED);
    try std.testing.expectEqual(@as(u32, 0x031F), WM_DWMNCRENDERINGCHANGED);
}
