// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM API Implementation

const std = @import("std");
pub const dwmapi_types = @import("dwmapi_types.zig");
pub const dwmapi_errors = @import("dwmapi_errors.zig");
const compositor = @import("../compositor/compositor.zig");

// ============================================================================
// Composition State
// ============================================================================

pub var g_composition_enabled: bool = true;
pub var g_composition_initialized: bool = false;

// ============================================================================
// DwmEnable / DwmIsCompositionEnabled
// ============================================================================

pub fn DwmEnable() dwmapi_types.HRESULT {
    g_composition_enabled = true;
    g_composition_initialized = true;
    compositor.setDwmEnabled(true);
    return dwmapi_errors.S_OK;
}

pub fn DwmDisable() dwmapi_types.HRESULT {
    g_composition_enabled = false;
    compositor.setDwmEnabled(false);
    return dwmapi_errors.S_OK;
}

pub fn DwmIsCompositionEnabled() dwmapi_types.HRESULT {
    if (g_composition_enabled) {
        return dwmapi_errors.S_OK;
    }
    return dwmapi_errors.S_FALSE;
}

pub fn isCompositionEnabled() bool {
    return g_composition_enabled;
}

// ============================================================================
// DwmExtendFrameIntoClientArea
// ============================================================================

pub fn DwmExtendFrameIntoClientArea(
    hwnd: ?*anyopaque,
    marInset: [*]const dwmapi_types.MARGINS,
) dwmapi_types.HRESULT {
    _ = hwnd;
    _ = marInset;
    return dwmapi_errors.S_OK;
}

// ============================================================================
// DwmEnableBlurBehindWindow
// ============================================================================

pub fn DwmEnableBlurBehindWindow(
    hwnd: ?*anyopaque,
    pBlurBehind: [*]const dwmapi_types.DWM_BLURBEHIND,
) dwmapi_types.HRESULT {
    _ = hwnd;
    _ = pBlurBehind;
    return dwmapi_errors.S_OK;
}

// ============================================================================
// DwmGetColorizationColor
// ============================================================================

pub fn DwmGetColorizationColor(
    pcrColorization: *u32,
    pfOpaqueBlend: *dwmapi_types.BOOL,
) dwmapi_types.HRESULT {
    // Default ZirconOS glass tint color (blue-gray)
    pcrColorization.* = 0x996666;
    pfOpaqueBlend.* = dwmapi_types.FALSE;
    return dwmapi_errors.S_OK;
}

// ============================================================================
// DwmGetCompositionTimingInfo
// ============================================================================

pub fn DwmGetCompositionTimingInfo(
    hwnd: ?*anyopaque,
    ptiminginfo: [*]dwmapi_types.DWM_COMPOSITION_TIMING_INFO,
) dwmapi_types.HRESULT {
    _ = hwnd;
    _ = ptiminginfo;
    return dwmapi_errors.S_OK;
}

// ============================================================================
// Thumbnail Management
// ============================================================================

pub const HTHUMBNAIL = u64;
pub const INVALID_THUMBNAIL: HTHUMBNAIL = 0;

pub const MAX_THUMBNAILS: usize = 64;

pub const ThumbnailState = struct {
    id: HTHUMBNAIL,
    source_window: ?*anyopaque,
    visible: bool,
    destination_rect: dwmapi_types.RECT,
    source_rect: dwmapi_types.RECT,
    opacity: u8,
};

pub var g_thumbnail_pool: [MAX_THUMBNAILS]?ThumbnailState = [_]?ThumbnailState{null} ** MAX_THUMBNAILS;
pub var g_thumbnail_count: usize = 0;
pub var g_thumbnail_next_id: HTHUMBNAIL = 1;

pub fn DwmRegisterThumbnail(
    hwndDestination: ?*anyopaque,
    hwndSource: ?*anyopaque,
    phThumbnailId: *HTHUMBNAIL,
) dwmapi_types.HRESULT {
    _ = hwndDestination;
    phThumbnailId.* = INVALID_THUMBNAIL;

    if (g_thumbnail_count >= MAX_THUMBNAILS) {
        return dwmapi_errors.E_OUTOFMEMORY;
    }

    g_thumbnail_pool[g_thumbnail_count] = .{
        .id = g_thumbnail_next_id,
        .source_window = hwndSource,
        .visible = false,
        .destination_rect = .{
            .left = 0,
            .top = 0,
            .right = 0,
            .bottom = 0,
        },
        .source_rect = .{
            .left = 0,
            .top = 0,
            .right = 0,
            .bottom = 0,
        },
        .opacity = 255,
    };

    phThumbnailId.* = g_thumbnail_next_id;
    g_thumbnail_next_id += 1;
    g_thumbnail_count += 1;

    return dwmapi_errors.S_OK;
}

pub fn DwmUnregisterThumbnail(hThumbnailId: HTHUMBNAIL) dwmapi_types.HRESULT {
    for (g_thumbnail_pool[0..g_thumbnail_count]) |*thumb| {
        if (thumb.*) |t| {
            if (t.id == hThumbnailId) {
                thumb.* = null;
                return dwmapi_errors.S_OK;
            }
        }
    }
    return dwmapi_errors.DWM_E_INVALIDTHUMBNAIL;
}

pub fn DwmUpdateThumbnailProperties(
    hThumbnailId: HTHUMBNAIL,
    ptnp: [*]const dwmapi_types.DWM_THUMBNAIL_PROPERTIES,
) dwmapi_types.HRESULT {
    _ = hThumbnailId;
    _ = ptnp;
    return dwmapi_errors.S_OK;
}

pub fn DwmQueryThumbnailSourceSize(
    hThumbnailId: HTHUMBNAIL,
    pSize: *dwmapi_types.RECT,
) dwmapi_types.HRESULT {
    _ = hThumbnailId;
    pSize.* = .{
        .left = 0,
        .top = 0,
        .right = 64,
        .bottom = 64,
    };
    return dwmapi_errors.S_OK;
}

// ============================================================================
// DwmAttachMilContent
// ============================================================================

pub fn DwmAttachMilContent(hwnd: ?*anyopaque) dwmapi_types.HRESULT {
    _ = hwnd;
    return dwmapi_errors.S_OK;
}

pub fn DwmDetachMilContent(hwnd: ?*anyopaque) dwmapi_types.HRESULT {
    _ = hwnd;
    return dwmapi_errors.S_OK;
}

// ============================================================================
// DwmGetTransportLimits
// ============================================================================

pub fn DwmGetTransportLimits(
    hwnd: ?*anyopaque,
    pTransportLimits: [*]dwmapi_types.DWM_TRANSPORT_LIMITS,
) dwmapi_types.HRESULT {
    _ = hwnd;
    _ = pTransportLimits;
    return dwmapi_errors.S_OK;
}

// ============================================================================
// DwmFlush
// ============================================================================

pub fn DwmFlush() dwmapi_types.HRESULT {
    compositor.markAllDirty();
    return dwmapi_errors.S_OK;
}

// ============================================================================
// Window Attributes
// ============================================================================

pub fn DwmSetWindowAttribute(
    hwnd: ?*anyopaque,
    dwAttribute: dwmapi_types.DWMWINDOWATTRIBUTE,
    pvAttribute: *const anyopaque,
    cbAttribute: u32,
) dwmapi_types.HRESULT {
    _ = hwnd;
    _ = dwAttribute;
    _ = pvAttribute;
    _ = cbAttribute;
    return dwmapi_errors.S_OK;
}

pub fn DwmGetWindowAttribute(
    hwnd: ?*anyopaque,
    dwAttribute: dwmapi_types.DWMWINDOWATTRIBUTE,
    pvAttribute: *anyopaque,
    cbAttribute: u32,
) dwmapi_types.HRESULT {
    _ = hwnd;
    _ = dwAttribute;
    _ = pvAttribute;
    _ = cbAttribute;
    return dwmapi_errors.S_OK;
}
