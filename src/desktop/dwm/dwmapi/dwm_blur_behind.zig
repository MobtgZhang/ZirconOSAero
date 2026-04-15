// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// DwmEnableBlurBehindWindow API Implementation

const std = @import("std");
pub const dwmapi_types = @import("dwmapi_types.zig");
pub const dwmapi_errors = @import("dwmapi_errors.zig");

// Explicit imports for commonly used types
const HRESULT = dwmapi_types.HRESULT;
const DWM_BLURBEHIND = dwmapi_types.DWM_BLURBEHIND;
const DWM_BB_ENABLE = dwmapi_types.DWM_BB_ENABLE;
const FALSE = dwmapi_types.FALSE;

// ============================================================================
// Blur Behind State
// ============================================================================

pub const MAX_BLUR_WINDOWS: usize = 128;

pub const BlurBehindState = struct {
    hwnd: ?*anyopaque,
    enabled: bool,
    hRgnBlur: ?*anyopaque,
    transition_on_maximized: bool,
};

pub var g_blur_windows: [MAX_BLUR_WINDOWS]?BlurBehindState = [_]?BlurBehindState{null} ** MAX_BLUR_WINDOWS;
pub var g_blur_window_count: usize = 0;

// ============================================================================
// DwmEnableBlurBehindWindow
// ============================================================================

pub fn DwmEnableBlurBehindWindow(
    hwnd: ?*anyopaque,
    pBlurBehind: [*]const DWM_BLURBEHIND,
) dwmapi_types.HRESULT {
    if (hwnd == null) {
        return dwmapi_errors.E_INVALIDARG;
    }

    if (pBlurBehind == null) {
        return DwmEnableBlurBehindWindow(hwnd, &.{
            .dwFlags = 0,
            .fEnable = FALSE,
            .hRgnBlur = null,
            .fTransitionOnMaximized = FALSE,
        });
    }

    const bb = pBlurBehind[0];

    // Check flags
    if ((bb.dwFlags & DWM_BB_ENABLE) != 0) {
        // Find or create entry
        var found = false;
        for (g_blur_windows[0..g_blur_window_count]) |*blur| {
            if (blur.*) |*b| {
                if (b.hwnd == hwnd) {
                    b.enabled = (bb.fEnable != FALSE);
                    b.hRgnBlur = bb.hRgnBlur;
                    b.transition_on_maximized = (bb.fTransitionOnMaximized != FALSE);
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            if (g_blur_window_count >= MAX_BLUR_WINDOWS) {
                return dwmapi_errors.E_OUTOFMEMORY;
            }

            g_blur_windows[g_blur_window_count] = .{
                .hwnd = hwnd,
                .enabled = (bb.fEnable != FALSE),
                .hRgnBlur = bb.hRgnBlur,
                .transition_on_maximized = (bb.fTransitionOnMaximized != FALSE),
            };

            g_blur_window_count += 1;
        }

        return dwmapi_errors.S_OK;
    }

    // If no DWM_BB_ENABLE flag, just return success
    return dwmapi_errors.S_OK;
}

// ============================================================================
// Blur State Query
// ============================================================================

pub fn isBlurEnabled(hwnd: ?*anyopaque) bool {
    for (g_blur_windows[0..g_blur_window_count]) |blur| {
        if (blur) |b| {
            if (b.hwnd == hwnd and b.enabled) {
                return true;
            }
        }
    }
    return false;
}

pub fn getBlurRegion(hwnd: ?*anyopaque) ?*anyopaque {
    for (g_blur_windows[0..g_blur_window_count]) |blur| {
        if (blur) |b| {
            if (b.hwnd == hwnd and b.enabled) {
                return b.hRgnBlur;
            }
        }
    }
    return null;
}

// ============================================================================
// Blur Configuration
// ============================================================================

pub const BlurConfig = struct {
    default_radius: i32 = 8,
    default_passes: i32 = 3,
    lite_blur_radius: i32 = 4,
    lite_blur_passes: i32 = 1,
    budget_pixel_passes: u32 = 500000,
    max_rect_calls_per_frame: u32 = 16,
};

pub var g_blur_config: BlurConfig = .{};

pub fn setBlurConfig(config: BlurConfig) void {
    g_blur_config = config;
}

pub fn getBlurConfig() *const BlurConfig {
    return &g_blur_config;
}
