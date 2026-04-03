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

/// `WM_DWMCOMPOSITIONCHANGED`：`wParam` 非零表示桌面合成启用（Learn — wm-dwmcompositionchanged）。
pub fn compositionChangedWParam(composition_enabled: bool) u64 {
    return if (composition_enabled) 1 else 0;
}

/// `WM_DWMNCRENDERINGCHANGED`：本仓库用 `wParam` 非零表示 NC 玻璃/策略启用（与 shell 监听约定一致；Learn 概述性描述）。
pub fn ncRenderingChangedWParam(policy_enabled: bool) u64 {
    return if (policy_enabled) 1 else 0;
}

/// `WM_DWMCOLORIZATIONCOLORCHANGED`：`wParam` 为 `COLORREF` 风格值；`lParam` 非零表示染色启用（Learn — wm-dwmcolorizationcolorchanged）。
pub fn colorizationChangedLParam(colorization_enabled: bool) i64 {
    return if (colorization_enabled) 1 else 0;
}

/// `WM_DWMWINDOWMAXIMIZEDCHANGE`：`wParam` 非零表示窗口已最大化（Learn — wm-dwmwindowmaximizedchange）。
pub fn windowMaximizedChangeWParam(maximized: bool) u64 {
    return if (maximized) 1 else 0;
}

/// `WM_DWMSENDICONICTHUMBNAIL` / `WM_DWMSENDICONICLIVEPREVIEWBITMAP`：`lParam` 低字最大宽、高字最大高（`MAKELPARAM` 布局；Learn）。
pub fn iconicSizeRequestLParam(max_width: u32, max_height: u32) i64 {
    const low: u32 = @min(max_width, 0xFFFF);
    const high: u32 = @min(max_height, 0xFFFF);
    const packed32: u32 = (high << 16) | low;
    return @intCast(@as(i32, @bitCast(packed32)));
}

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

// `DWM_PRESENT_PARAMETERS` / `DwmRenderAsSharedSurface` 等为 **Windows 8+** 文档项；NT 6.1 目标不包含其布局锚点。
//
// ── Thumbnail properties (DwmUpdateThumbnailProperties) ──
// Ref: Learn — DWM_TNP_* flags, DWM_THUMBNAIL_PROPERTIES

pub const DWM_TNP_RECTDESTINATION: u32 = 0x00000001;
pub const DWM_TNP_RECTSOURCE: u32 = 0x00000002;
pub const DWM_TNP_OPACITY: u32 = 0x00000004;
pub const DWM_TNP_VISIBLE: u32 = 0x00000008;
pub const DWM_TNP_SOURCECLIENTAREAONLY: u32 = 0x00000010;

// ── DWMFLIP3DWINDOWPOLICY (DWORD for DWMWA_FLIP3D_POLICY) ──
// Ref: Learn — DWMFLIP3DWINDOWPOLICY enumeration

pub const DWMFLIP3D_DEFAULT: u32 = 0;
pub const DWMFLIP3D_EXCLUDEBELOW: u32 = 1;
pub const DWMFLIP3D_EXCLUDEABOVE: u32 = 2;
pub const DWMFLIP3D_LAST: u32 = 3;

/// Win32 `RECT` in DWM public layouts (four `LONG`, 16 bytes).
pub const DWM_RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Ref: Learn — DWM_THUMBNAIL_PROPERTIES structure (MSVC default layout, LP64).
/// Padding fields match 8-byte alignment of embedded `RECT`s after `DWORD dwFlags`.
pub const DWM_THUMBNAIL_PROPERTIES = extern struct {
    dwFlags: u32,
    _pad_dwalign: u32 = 0,
    rcDestination: DWM_RECT,
    rcSource: DWM_RECT,
    opacity: u8,
    _pad_opacity: u8 = 0,
    _pad_opacity2: u8 = 0,
    _pad_opacity3: u8 = 0,
    fVisible: WinBool,
    fSourceClientAreaOnly: WinBool,
};

// ── HRESULT subset used by dwmapi (public FACILITY values) ──
// Ref: Learn return value sections; `DWM_E_*` from documented error facility.

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
/// Desktop composition disabled (`DWM_E_COMPOSITIONDISABLED`).
pub const DWM_E_COMPOSITIONDISABLED: HRESULT = @bitCast(@as(u32, 0x80263001));

test "LP64 MARGINS and DWM_RECT sizes for dwmapi" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(MARGINS));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DWM_RECT));
}

comptime {
    std.debug.assert(@sizeOf(MARGINS) == 16);
    std.debug.assert(@alignOf(MARGINS) == 4);
    // `DWM_BLURBEHIND` 大小随 `usize`（HRGN）宽度变化；仅 LP64 下与 MSVC x64 文档布局 24 字节一致。
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(DWM_BLURBEHIND) == 24);
        std.debug.assert(@alignOf(DWM_BLURBEHIND) == 8);
    }
    std.debug.assert(@sizeOf(DWM_RECT) == 16);
    std.debug.assert(@alignOf(DWM_RECT) == 4);
    std.debug.assert(@offsetOf(DWM_THUMBNAIL_PROPERTIES, "dwFlags") == 0);
    std.debug.assert(@offsetOf(DWM_THUMBNAIL_PROPERTIES, "rcDestination") == 8);
    std.debug.assert(@offsetOf(DWM_THUMBNAIL_PROPERTIES, "rcSource") == 24);
    std.debug.assert(@offsetOf(DWM_THUMBNAIL_PROPERTIES, "opacity") == 40);
    std.debug.assert(@offsetOf(DWM_THUMBNAIL_PROPERTIES, "fVisible") == 44);
    std.debug.assert(@offsetOf(DWM_THUMBNAIL_PROPERTIES, "fSourceClientAreaOnly") == 48);
    std.debug.assert(@sizeOf(DWM_THUMBNAIL_PROPERTIES) == 52);
    std.debug.assert(@alignOf(DWM_THUMBNAIL_PROPERTIES) == 4);
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

test "compositionChangedWParam and ncRenderingChangedWParam BOOL-like" {
    try std.testing.expectEqual(@as(u64, 1), compositionChangedWParam(true));
    try std.testing.expectEqual(@as(u64, 0), compositionChangedWParam(false));
    try std.testing.expectEqual(@as(u64, 1), ncRenderingChangedWParam(true));
}

test "colorizationChangedLParam non-zero when enabled" {
    try std.testing.expect(colorizationChangedLParam(true) != 0);
    try std.testing.expectEqual(@as(i64, 0), colorizationChangedLParam(false));
}

test "iconicSizeRequestLParam MAKELPARAM width height" {
    const lp = iconicSizeRequestLParam(320, 240);
    const u: u32 = @bitCast(@as(i32, @intCast(lp)));
    try std.testing.expectEqual(@as(u32, 320), u & 0xFFFF);
    try std.testing.expectEqual(@as(u32, 240), (u >> 16) & 0xFFFF);
}

test "iconicSizeRequestLParam clamps to 16-bit fields" {
    const lp = iconicSizeRequestLParam(0x1_0000, 50);
    const u: u32 = @bitCast(@as(i32, @intCast(lp)));
    try std.testing.expectEqual(@as(u32, 0xFFFF), u & 0xFFFF);
    try std.testing.expectEqual(@as(u32, 50), (u >> 16) & 0xFFFF);
}

test "DWM HRESULT anchors documented bits" {
    try std.testing.expectEqual(@as(i32, 0), S_OK);
    try std.testing.expectEqual(@as(u32, @bitCast(E_INVALIDARG)), 0x80070057);
    try std.testing.expectEqual(@as(u32, @bitCast(DWM_E_COMPOSITIONDISABLED)), 0x80263001);
}

test "DWM_THUMBNAIL_PROPERTIES round-trip flags" {
    var p: DWM_THUMBNAIL_PROPERTIES = undefined;
    p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE;
    p.rcDestination = .{ .left = 1, .top = 2, .right = 10, .bottom = 20 };
    p.rcSource = .{ .left = 0, .top = 0, .right = 5, .bottom = 5 };
    p.opacity = 200;
    p.fVisible = 1;
    p.fSourceClientAreaOnly = 0;
    try std.testing.expectEqual(@as(i32, 1), p.rcDestination.left);
    try std.testing.expectEqual(@as(u8, 200), p.opacity);
}
