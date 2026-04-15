// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// Thumbnail Management API Implementation

const std = @import("std");
pub const dwmapi_types = @import("dwmapi_types.zig");
pub const dwmapi_errors = @import("dwmapi_errors.zig");
const dxgi_types = @import("../dxgi/dxgi_types.zig");
const RECT = dxgi_types.RECT;

// ============================================================================
// Thumbnail Constants
// ============================================================================

pub const HTHUMBNAIL = u64;
pub const INVALID_THUMBNAIL: HTHUMBNAIL = 0;
pub const MAX_THUMBNAILS: usize = 64;

// ============================================================================
// Thumbnail State
// ============================================================================

pub const ThumbnailState = struct {
    id: HTHUMBNAIL,
    destination_window: ?*anyopaque,
    source_window: ?*anyopaque,
    visible: bool,
    destination_rect: RECT,
    source_rect: RECT,
    opacity: u8,
    source_client_area_only: bool,
    last_update: u64,
};

pub var g_thumbnail_pool: [MAX_THUMBNAILS]?ThumbnailState = [_]?ThumbnailState{null} ** MAX_THUMBNAILS;
pub var g_thumbnail_count: usize = 0;
pub var g_thumbnail_next_id: HTHUMBNAIL = 1;

// ============================================================================
// DwmRegisterThumbnail
// ============================================================================

pub fn DwmRegisterThumbnail(
    hwndDestination: ?*anyopaque,
    hwndSource: ?*anyopaque,
    phThumbnailId: *HTHUMBNAIL,
) dwmapi_types.HRESULT {
    phThumbnailId.* = INVALID_THUMBNAIL;

    if (hwndDestination == null or hwndSource == null) {
        return dwmapi_errors.E_INVALIDARG;
    }

    if (g_thumbnail_count >= MAX_THUMBNAILS) {
        return dwmapi_errors.E_OUTOFMEMORY;
    }

    g_thumbnail_pool[g_thumbnail_count] = .{
        .id = g_thumbnail_next_id,
        .destination_window = hwndDestination,
        .source_window = hwndSource,
        .visible = false,
        .destination_rect = .{ .left = 0, .top = 0, .right = 200, .bottom = 150 },
        .source_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .opacity = 255,
        .source_client_area_only = false,
        .last_update = 0,
    };

    phThumbnailId.* = g_thumbnail_next_id;
    g_thumbnail_next_id += 1;
    g_thumbnail_count += 1;

    return dwmapi_errors.S_OK;
}

// ============================================================================
// DwmUnregisterThumbnail
// ============================================================================

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

// ============================================================================
// DwmUpdateThumbnailProperties
// ============================================================================

pub fn DwmUpdateThumbnailProperties(
    hThumbnailId: HTHUMBNAIL,
    ptnp: [*]const dwmapi_types.DWM_THUMBNAIL_PROPERTIES,
) dwmapi_types.HRESULT {
    if (ptnp == null) {
        return dwmapi_errors.E_INVALIDARG;
    }

    for (g_thumbnail_pool[0..g_thumbnail_count]) |*thumb| {
        if (thumb.*) |*t| {
            if (t.id == hThumbnailId) {
                const props = ptnp[0];

                if ((props.dwFlags & dwmapi_types.DWM_TNP_RECTDESTINATION) != 0) {
                    t.destination_rect = props.rcDestination;
                }
                if ((props.dwFlags & dwmapi_types.DWM_TNP_RECTSOURCE) != 0) {
                    t.source_rect = props.rcSource;
                }
                if ((props.dwFlags & dwmapi_types.DWM_TNP_OPACITY) != 0) {
                    t.opacity = props.opacity;
                }
                if ((props.dwFlags & dwmapi_types.DWM_TNP_VISIBLE) != 0) {
                    t.visible = (props.fVisible != dwmapi_types.FALSE);
                }
                if ((props.dwFlags & dwmapi_types.DWM_TNP_SOURCECLIENTAREAONLY) != 0) {
                    t.source_client_area_only = (props.fSourceClientAreaOnly != dwmapi_types.FALSE);
                }

                t.last_update = std.time.milliTimestamp();
                return dwmapi_errors.S_OK;
            }
        }
    }

    return dwmapi_errors.DWM_E_INVALIDTHUMBNAIL;
}

// ============================================================================
// DwmQueryThumbnailSourceSize
// ============================================================================

pub fn DwmQueryThumbnailSourceSize(
    hThumbnailId: HTHUMBNAIL,
    pSize: *RECT,
) dwmapi_types.HRESULT {
    for (g_thumbnail_pool[0..g_thumbnail_count]) |thumb| {
        if (thumb) |t| {
            if (t.id == hThumbnailId) {
                // Return the source window's client area size
                // In a real implementation, this would query the window
                pSize.* = .{
                    .left = 0,
                    .top = 0,
                    .right = 800,
                    .bottom = 600,
                };
                return dwmapi_errors.S_OK;
            }
        }
    }

    return dwmapi_errors.DWM_E_INVALIDTHUMBNAIL;
}

// ============================================================================
// Thumbnail Helper Functions
// ============================================================================

pub fn getThumbnail(id: HTHUMBNAIL) ?*const ThumbnailState {
    for (g_thumbnail_pool[0..g_thumbnail_count]) |thumb| {
        if (thumb) |t| {
            if (t.id == id) {
                return t;
            }
        }
    }
    return null;
}

pub fn getVisibleThumbnails() []const *const ThumbnailState {
    var result: [MAX_THUMBNAILS]*const ThumbnailState = undefined;
    var count: usize = 0;

    for (g_thumbnail_pool[0..g_thumbnail_count]) |thumb| {
        if (thumb) |t| {
            if (t.visible) {
                result[count] = t;
                count += 1;
            }
        }
    }

    return result[0..count];
}
