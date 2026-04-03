// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/dwmapi_wow64.zig
// Purpose: PE32 (ILP32) layouts and HWND sign-extension helpers for WOW64 → native dwmapi forwarding (documentation parity).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/winprog/windows-data-types (HWND, HANDLE, LONG)

const std = @import("std");
const dnc = @import("dwm_nt61_api_contract");

/// 32-bit `BOOL` in public layouts.
pub const WinBool32 = i32;

/// `DWM_BLURBEHIND` on PE32: `HRGN` is 32-bit.
pub const DWM_BLURBEHIND32 = extern struct {
    dwFlags: u32,
    fEnable: WinBool32,
    hRgnBlur: u32,
    fTransitionOnMaximized: WinBool32,
};

pub const MARGINS32 = extern struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};

/// Same field order as LP64 [`dwm_nt61_api_contract.DWM_THUMBNAIL_PROPERTIES`](../../config/dwm_nt61_api_contract.zig); sizes differ only by packing rules (here identical).
pub const DWM_THUMBNAIL_PROPERTIES32 = extern struct {
    dwFlags: u32,
    _pad_dwalign: u32 = 0,
    rcDestination: RECT32,
    rcSource: RECT32,
    opacity: u8,
    _pad_opacity: u8 = 0,
    _pad_opacity2: u8 = 0,
    _pad_opacity3: u8 = 0,
    fVisible: WinBool32,
    fSourceClientAreaOnly: WinBool32,
};

pub const RECT32 = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

comptime {
    std.debug.assert(@sizeOf(MARGINS32) == 16);
    std.debug.assert(@sizeOf(RECT32) == 16);
    std.debug.assert(@sizeOf(DWM_BLURBEHIND32) == 16);
    std.debug.assert(@offsetOf(DWM_THUMBNAIL_PROPERTIES32, "rcDestination") == 8);
    std.debug.assert(@sizeOf(DWM_THUMBNAIL_PROPERTIES32) == 52);
}

/// Sign-extend 32-bit HWND to 64-bit canonical user handle (WOW64 interop convention).
pub fn hwnd32ToNative(hwnd32: u32) u64 {
    return @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(hwnd32)))));
}

pub fn blurBehind32ToNative(b: DWM_BLURBEHIND32) dnc.DWM_BLURBEHIND {
    return .{
        .dwFlags = b.dwFlags,
        .fEnable = b.fEnable,
        .hRgnBlur = b.hRgnBlur,
        .fTransitionOnMaximized = b.fTransitionOnMaximized,
    };
}

pub fn margins32ToNative(m: MARGINS32) dnc.MARGINS {
    return .{
        .cxLeftWidth = m.cxLeftWidth,
        .cxRightWidth = m.cxRightWidth,
        .cyTopHeight = m.cyTopHeight,
        .cyBottomHeight = m.cyBottomHeight,
    };
}

test "WOW64 HWND sign extension negative sentinel" {
    const h = hwnd32ToNative(0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), h);
}

test "WOW64 HWND zero" {
    try std.testing.expectEqual(@as(u64, 0), hwnd32ToNative(0));
}

test "DWM_BLURBEHIND32 ILP32 size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DWM_BLURBEHIND32));
}
