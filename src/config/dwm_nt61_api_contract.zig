// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/config/dwm_nt61_api_contract.zig
// Purpose: Clean-room constants and public-layout structs for Vista/7 DWM / desktop notification APIs (documentation parity only).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/dwm/ ,
//            https://learn.microsoft.com/windows/win32/winmsg/wm-dwmcompositionchanged ,
//            https://learn.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute ,
//            https://learn.microsoft.com/windows/win32/api/dwmapi/ns-dwmapi-dwm_blurbehind .

const std = @import("std");

/// Win32 `BOOL` in public struct layouts (4-byte signed int).
pub const WinBool = i32;

// ── Broadcast window messages (Winuser / DWM notification family) ──
// Ref: Learn — wm-dwmcompositionchanged, wm-dwmcolorizationcolorchanged, wm-dwmsendiconicthumbnail

pub const WM_DWMCOMPOSITIONCHANGED: u32 = 0x031E;
pub const WM_DWMNCRENDERINGCHANGED: u32 = 0x031F;
pub const WM_DWMCOLORIZATIONCOLORCHANGED: u32 = 0x0320;
pub const WM_DWMWINDOWMAXIMIZEDCHANGE: u32 = 0x0321;
pub const WM_DWMSENDICONICTHUMBNAIL: u32 = 0x0323;
pub const WM_DWMSENDICONICLIVEPREVIEWBITMAP: u32 = 0x0326;

/// Flip3D 底栏：`collectShellWindowSurfaceIds` 缓冲上限；`display.renderFlip3dOverlay` 最多绘制的 shell 缩略张数（截断策略见契约矩阵 §4.1）。
pub const flip3d_shell_sid_buffer_cap: usize = 6;
pub const flip3d_shell_thumb_paint_max: usize = 4;

// ── DwmGetWindowAttribute / DwmSetWindowAttribute (subset used on NT 6.1) ──
// Ref: Learn — DWMWINDOWATTRIBUTE enumeration

pub const DWMWA_NCRENDERING_ENABLED: u32 = 1;
pub const DWMWA_NCRENDERING_POLICY: u32 = 2;
pub const DWMWA_TRANSITIONS_FORCEDISABLED: u32 = 3;
pub const DWMWA_ALLOW_NCPAINT: u32 = 4;
pub const DWMWA_CAPTION_BUTTON_BOUNDS: u32 = 5;
pub const DWMWA_NONCLIENT_RTL_LAYOUT: u32 = 6;
pub const DWMWA_FORCE_ICONIC_REPRESENTATION: u32 = 7;
pub const DWMWA_FLIP3D_POLICY: u32 = 8;
pub const DWMWA_EXTENDED_FRAME_BOUNDS: u32 = 9;
pub const DWMWA_HAS_ICONIC_BITMAP: u32 = 10;
pub const DWMWA_DISALLOW_PEEK: u32 = 11;
pub const DWMWA_EXCLUDED_FROM_PEEK: u32 = 12;
pub const DWMWA_CLOAK: u32 = 13;
pub const DWMWA_CLOAKED: u32 = 14;
pub const DWMWA_FREEZE_REPRESENTATION: u32 = 15;

// ── DWMNCRENDERINGPOLICY (DWORD-sized) ──

pub const DWMNCRP_USEWINDOWSTYLE: u32 = 0;
pub const DWMNCRP_DISABLED: u32 = 1;
pub const DWMNCRP_ENABLED: u32 = 2;

// ── DWM_BLURBEHIND.dwFlags ──
// Ref: Learn — DWM_BLURBEHIND structure

pub const DWM_BB_ENABLE: u32 = 0x00000001;
pub const DWM_BB_BLURREGION: u32 = 0x00000002;
pub const DWM_BB_TRANSITIONONMAXIMIZED: u32 = 0x00000004;

/// NT user/kernel ABI uses pointer-sized HRGN in layouts (documented as opaque handle).
pub const DWM_BLURBEHIND = extern struct {
    dwFlags: u32,
    fEnable: WinBool,
    hRgnBlur: usize,
    fTransitionOnMaximized: WinBool,
};

/// DwmExtendFrameIntoClientArea margins (public layout).
pub const MARGINS = extern struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};

// ── Thumbnail properties (DwmUpdateThumbnailProperties) ──
// Ref: Learn — DWM_TNP_* flags, DWM_THUMBNAIL_PROPERTIES

pub const DWM_TNP_RECTDESTINATION: u32 = 0x00000001;
pub const DWM_TNP_RECTSOURCE: u32 = 0x00000002;
pub const DWM_TNP_OPACITY: u32 = 0x00000004;
pub const DWM_TNP_VISIBLE: u32 = 0x00000008;
pub const DWM_TNP_SOURCECLIENTAREAONLY: u32 = 0x00000010;

comptime {
    std.debug.assert(@sizeOf(MARGINS) == 16);
    std.debug.assert(@alignOf(MARGINS) == 4);
    // `DWM_BLURBEHIND` 大小随 `usize`（HRGN）宽度变化；仅 LP64 下与 MSVC x64 文档布局 24 字节一致。
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(DWM_BLURBEHIND) == 24);
        std.debug.assert(@alignOf(DWM_BLURBEHIND) == 8);
    }
}

test "DWM notification WM_ ids match Learn anchors" {
    try std.testing.expectEqual(@as(u32, 0x031E), WM_DWMCOMPOSITIONCHANGED);
    try std.testing.expectEqual(@as(u32, 0x031F), WM_DWMNCRENDERINGCHANGED);
    try std.testing.expectEqual(@as(u32, 0x0320), WM_DWMCOLORIZATIONCOLORCHANGED);
    try std.testing.expectEqual(@as(u32, 0x0321), WM_DWMWINDOWMAXIMIZEDCHANGE);
    try std.testing.expectEqual(@as(u32, 0x0323), WM_DWMSENDICONICTHUMBNAIL);
    try std.testing.expectEqual(@as(u32, 0x0326), WM_DWMSENDICONICLIVEPREVIEWBITMAP);
}

test "Flip3D shell strip caps match dwm_compositor / display" {
    try std.testing.expect(flip3d_shell_sid_buffer_cap >= flip3d_shell_thumb_paint_max);
    try std.testing.expectEqual(@as(usize, 6), flip3d_shell_sid_buffer_cap);
    try std.testing.expectEqual(@as(usize, 4), flip3d_shell_thumb_paint_max);
}

test "DWM_BLURBEHIND flag bits non-zero where documented" {
    try std.testing.expect((DWM_BB_ENABLE | DWM_BB_BLURREGION | DWM_BB_TRANSITIONONMAXIMIZED) != 0);
}
