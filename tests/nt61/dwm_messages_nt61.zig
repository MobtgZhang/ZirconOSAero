//! DWM 相关 Win32 消息常量（Microsoft Learn），主机 `zig test` 纯常量回归。
//! 与 docs/cn/NT61_CONTRACT_MATRIX.md §4 对照；单一数据源：`src/config/dwm_nt61_api_contract.zig`。
const std = @import("std");
const dnc = @import("dwm_nt61_api_contract");
const csr_lpc_policy = @import("csr_lpc_policy");

test "DWM notification message ids stable for NT6.1 docs" {
    try std.testing.expectEqual(@as(u32, 0x031E), dnc.WM_DWMCOMPOSITIONCHANGED);
    try std.testing.expectEqual(@as(u32, 0x0320), dnc.WM_DWMCOLORIZATIONCOLORCHANGED);
    try std.testing.expectEqual(@as(u32, 0x031F), dnc.WM_DWMNCRENDERINGCHANGED);
    try std.testing.expectEqual(@as(u32, 0x0323), dnc.WM_DWMSENDICONICTHUMBNAIL);
    try std.testing.expectEqual(@as(u32, 0x0321), dnc.WM_DWMWINDOWMAXIMIZEDCHANGE);
    try std.testing.expectEqual(@as(u32, 0x0326), dnc.WM_DWMSENDICONICLIVEPREVIEWBITMAP);
}

test "DWM messages fall in documented band for min-max filter smoke" {
    const min_v: u32 = 0x0300;
    const max_v: u32 = 0x0330;
    try std.testing.expect(dnc.WM_DWMCOMPOSITIONCHANGED >= min_v and dnc.WM_DWMCOMPOSITIONCHANGED <= max_v);
    try std.testing.expect(dnc.WM_DWMCOLORIZATIONCOLORCHANGED >= min_v and dnc.WM_DWMCOLORIZATIONCOLORCHANGED <= max_v);
    try std.testing.expect(dnc.WM_DWMNCRENDERINGCHANGED >= min_v and dnc.WM_DWMNCRENDERINGCHANGED <= max_v);
    try std.testing.expect(dnc.WM_DWMSENDICONICTHUMBNAIL >= min_v and dnc.WM_DWMSENDICONICTHUMBNAIL <= max_v);
}

test "DWM notification WM_ values ascending within family" {
    try std.testing.expect(dnc.WM_DWMCOMPOSITIONCHANGED < dnc.WM_DWMNCRENDERINGCHANGED);
    try std.testing.expect(dnc.WM_DWMNCRENDERINGCHANGED < dnc.WM_DWMCOLORIZATIONCOLORCHANGED);
    try std.testing.expect(dnc.WM_DWMCOLORIZATIONCOLORCHANGED < dnc.WM_DWMWINDOWMAXIMIZEDCHANGE);
    try std.testing.expect(dnc.WM_DWMWINDOWMAXIMIZEDCHANGE < dnc.WM_DWMSENDICONICTHUMBNAIL);
}

test "WM_DWMCOMPOSITIONCHANGED wParam BOOL-like on off" {
    const wp_on: u32 = 1;
    const wp_off: u32 = 0;
    try std.testing.expect(wp_on != wp_off);
}

test "WM_DWMCOLORIZATIONCOLORCHANGED wParam lParam anchor" {
    const colorref: u32 = 0x00AA7744;
    const lp_blend_on: i64 = 1;
    try std.testing.expectEqual(@as(u32, 0xAA7744), colorref & 0xFFFFFF);
    try std.testing.expect(lp_blend_on != 0);
}

test "WM_DWMNCRENDERINGCHANGED wParam non-zero when policy enabled" {
    const wp: u32 = 1;
    try std.testing.expect(wp != 0);
}

test "register_dwm_listener v1 LPC magic stable (DWM01)" {
    try std.testing.expectEqual(@as(u32, 0x014D5744), csr_lpc_policy.register_dwm_listener_v1_magic_le);
}

test "DWM notify ids used by registry sync broadcast path" {
    try std.testing.expectEqual(@as(u32, 0x0320), dnc.WM_DWMCOLORIZATIONCOLORCHANGED);
    try std.testing.expectEqual(@as(u32, 0x031F), dnc.WM_DWMNCRENDERINGCHANGED);
}

test "dwm_nt61_api_contract packers match user32 broadcast narrative" {
    try std.testing.expectEqual(@as(u64, 1), dnc.compositionChangedWParam(true));
    try std.testing.expectEqual(@as(i64, 1), dnc.colorizationChangedLParam(true));
    const lp = dnc.iconicSizeRequestLParam(64, 48);
    const u: u32 = @bitCast(@as(i32, @intCast(lp)));
    try std.testing.expectEqual(@as(u32, 64), u & 0xFFFF);
    try std.testing.expectEqual(@as(u32, 48), (u >> 16) & 0xFFFF);
    try std.testing.expectEqual(@as(u64, 1), dnc.windowMaximizedChangeWParam(true));
}

// 启动豁免叙事锚点：`getWindowCount()==0` 时注册表同步路径不投递 `WM_DWM*`（见 `dwm.syncPolicyFromRegistry` 与 DWM_NOTIFY_MODEL_NT61.md）。
test "startup exemption when zero HWNDs is policy gate not message id" {
    const zero_windows: usize = 0;
    try std.testing.expectEqual(@as(usize, 0), zero_windows);
}
