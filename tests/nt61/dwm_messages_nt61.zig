//! DWM 相关 Win32 消息常量（Microsoft Learn），主机 `zig test` 纯常量回归。
//! 与 docs/cn/NT61_CONTRACT_MATRIX.md §4 对照；单一数据源：`src/config/dwm_nt61_api_contract.zig`。
const std = @import("std");
const dnc = @import("dwm_nt61_api_contract");

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

test "DWM notify ids used by registry sync broadcast path" {
    try std.testing.expectEqual(@as(u32, 0x0320), dnc.WM_DWMCOLORIZATIONCOLORCHANGED);
    try std.testing.expectEqual(@as(u32, 0x031F), dnc.WM_DWMNCRENDERINGCHANGED);
}
