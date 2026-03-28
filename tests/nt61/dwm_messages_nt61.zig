//! DWM 相关 Win32 消息常量（Winuser.h / Microsoft Learn），主机 `zig test` 纯常量回归。
//! 与 docs/cn/NT61_CONTRACT_MATRIX.md §4 对照；实现侧尚未全线分发这些消息。
const std = @import("std");

// Ref: https://learn.microsoft.com/windows/win32/winmsg/wm-dwmcompositionchanged
pub const WM_DWMCOMPOSITIONCHANGED: u32 = 0x031E;
// Ref: https://learn.microsoft.com/windows/win32/winmsg/wm-dwmcolorizationcolorchanged
pub const WM_DWMCOLORIZATIONCOLORCHANGED: u32 = 0x0320;
// Ref: desktop-src/dwm/wm-dwmncrenderingchanged.md (same family as DWM notifications)
pub const WM_DWMNCRENDERINGCHANGED: u32 = 0x031F;

test "DWM notification message ids stable for NT6.1 docs" {
    try std.testing.expectEqual(@as(u32, 0x031E), WM_DWMCOMPOSITIONCHANGED);
    try std.testing.expectEqual(@as(u32, 0x0320), WM_DWMCOLORIZATIONCOLORCHANGED);
    try std.testing.expectEqual(@as(u32, 0x031F), WM_DWMNCRENDERINGCHANGED);
}
