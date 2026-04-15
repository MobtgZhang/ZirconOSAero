// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// DwmExtendFrameIntoClientArea API Implementation

const std = @import("std");
pub const dwmapi_types = @import("dwmapi_types.zig");
pub const dwmapi_errors = @import("dwmapi_errors.zig");
const dxgi_types = @import("../dxgi/dxgi_types.zig");
const MARGINS = dxgi_types.MARGINS;
const RECT = dxgi_types.RECT;

// ============================================================================
// Frame Extension State
// ============================================================================

pub const MAX_FRAME_EXTENSIONS: usize = 64;

pub const FrameExtension = struct {
    hwnd: ?*anyopaque,
    margins: MARGINS,
    enabled: bool,
};

pub var g_frame_extensions: [MAX_FRAME_EXTENSIONS]?FrameExtension = [_]?FrameExtension{null} ** MAX_FRAME_EXTENSIONS;
pub var g_frame_extension_count: usize = 0;

// ============================================================================
// DwmExtendFrameIntoClientArea
// ============================================================================

pub fn DwmExtendFrameIntoClientArea(
    hwnd: ?*anyopaque,
    marInset: [*]const MARGINS,
) dwmapi_types.HRESULT {
    if (hwnd == null) {
        return dwmapi_errors.E_INVALIDARG;
    }

    if (marInset == null) {
        // Reset to default margins
        return resetFrameExtension(hwnd);
    }

    const margins = marInset[0];

    // Check for existing extension
    for (g_frame_extensions[0..g_frame_extension_count]) |*ext| {
        if (ext.*) |*e| {
            if (e.hwnd == hwnd) {
                e.margins = margins;
                e.enabled = true;
                return dwmapi_errors.S_OK;
            }
        }
    }

    // Create new extension
    if (g_frame_extension_count >= MAX_FRAME_EXTENSIONS) {
        return dwmapi_errors.E_OUTOFMEMORY;
    }

    g_frame_extensions[g_frame_extension_count] = .{
        .hwnd = hwnd,
        .margins = margins,
        .enabled = true,
    };

    g_frame_extension_count += 1;
    return dwmapi_errors.S_OK;
}

fn resetFrameExtension(hwnd: ?*anyopaque) dwmapi_types.HRESULT {
    for (g_frame_extensions[0..g_frame_extension_count]) |*ext| {
        if (ext.*) |*e| {
            if (e.hwnd == hwnd) {
                e.margins = .{
                    .cxLeftWidth = 0,
                    .cxRightWidth = 0,
                    .cyTopHeight = 0,
                    .cyBottomHeight = 0,
                };
                e.enabled = false;
                return dwmapi_errors.S_OK;
            }
        }
    }
    return dwmapi_errors.S_OK;
}

// ============================================================================
// Get Frame Margins
// ============================================================================

pub fn getFrameMargins(hwnd: ?*anyopaque) ?MARGINS {
    for (g_frame_extensions[0..g_frame_extension_count]) |ext| {
        if (ext) |e| {
            if (e.hwnd == hwnd and e.enabled) {
                return e.margins;
            }
        }
    }
    return null;
}

// ============================================================================
// Special Margins Constants
// ============================================================================

// Margins for full shadow coverage (classic Aero look)
pub const MARGINS_FULL_SHADOW: MARGINS = .{
    .cxLeftWidth = -1,
    .cxRightWidth = -1,
    .cyTopHeight = -1,
    .cyBottomHeight = -1,
};

// Margins for transparent frame (no frame)
pub const MARGINS_TRANSPARENT: MARGINS = .{
    .cxLeftWidth = 0,
    .cxRightWidth = 0,
    .cyTopHeight = 0,
    .cyBottomHeight = 0,
};

// Margins for thin frame
pub const MARGINS_THIN_FRAME: MARGINS = .{
    .cxLeftWidth = 1,
    .cxRightWidth = 1,
    .cyTopHeight = 1,
    .cyBottomHeight = 1,
};
