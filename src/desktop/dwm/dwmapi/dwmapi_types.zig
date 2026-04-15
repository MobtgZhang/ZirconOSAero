// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! ZirconOS DWM API Types
//! Clean-room implementation based on public Windows DWM API documentation.

const std = @import("std");

// ============================================================================
// DWM Types
// ============================================================================

pub const HRESULT = i32;

// DWM Constants
pub const DWM_CLR_INVALIDATE: u32 = 0xFFFFFFFF;
pub const DWM_FRAME_REG_COUNT: usize = 6;
pub const DWM_TIMEOUT_AERO_BLURBEHIND: u32 = 5000;
pub const DWM_TIMEOUT_FLIP3D: u32 = 3000;

// ============================================================================
// MARGINS
// ============================================================================

pub const MARGINS = extern struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};

// ============================================================================
// DWM_BLURBEHIND
// ============================================================================

pub const DWM_BLURBEHIND = extern struct {
    dwFlags: u32,
    fEnable: BOOL,
    hRgnBlur: ?*anyopaque,
    fTransitionOnMaximized: BOOL,
};

// DWM_BLURBEHIND flags
pub const DWM_BB_ENABLE: u32 = 0x00000001;
pub const DWM_BB_BLURREGION: u32 = 0x00000002;
pub const DWM_BB_TRANSITIONONMAXIMIZED: u32 = 0x00000004;
pub const DWM_BB_ALL: u32 = 0x00000007;

// ============================================================================
// DWM_THUMBNAIL_PROPERTIES
// ============================================================================

pub const DWM_THUMBNAIL_PROPERTIES = extern struct {
    dwFlags: u32,
    rcDestination: RECT,
    rcSource: RECT,
    opacity: u8,
    fVisible: BOOL,
    fSourceClientAreaOnly: BOOL,
};

// Thumbnail flags
pub const DWM_TNP_RECTDESTINATION: u32 = 0x00000001;
pub const DWM_TNP_RECTSOURCE: u32 = 0x00000002;
pub const DWM_TNP_OPACITY: u32 = 0x00000004;
pub const DWM_TNP_VISIBLE: u32 = 0x00000008;
pub const DWM_TNP_SOURCECLIENTAREAONLY: u32 = 0x00000010;

// ============================================================================
// DWM_COMPOSITION_TIMING_INFO
// ============================================================================

pub const DWM_COMPOSITION_TIMING_INFO = extern struct {
    cbSize: u32,
    rateRefresh: u64,
    cRefreshes: u64,
    qpcVBlank: i64,
    qpcCompose: i64,
    cFrame: u32,
    cRefreshFrame: u32,
    cRefreshesPerFrame: u64,
    cDXChairs: u32,
    uFrame: u32,
    uPixelRefresh: u32,
    uMSAckTick: u32,
    cAsyncFrames: u32,
    cReadyFrame: u32,
    cStandingFrame: u32,
    qpcComposeLast: i64,
    qpcFrame: i64,
    qpcCompondPosition: i64,
    qpcSeek: i64,
    qpcAsyncPresent: i64,
    qpcLastPresent: i64,
    qpcOldestFirstEventSeq: u64,
    qpcNewestFirstEventSeq: u64,
    cWait: u32,
    cBuffers: u32,
    cRulesChecked: u32,
    cFLips: u32,
    cAltTab: u32,
    cAlttabChanged: u32,
    cExitSizeChanged: u32,
    cDisplayChanges: u32,
    cDraggedFile: u32,
    cAcrylicOverlayOn: u32,
    cAcrylicOverlayDecay: u32,
    cAcrylicOverlayStarved: u32,
    cCallbacks: u32,
    cRetFrameContent: u32,
    cRetFrameSurface: u32,
    cRetThumnailShadow: u32,
    cRetThumnailCache: u32,
    cRetPalettizedThumnail: u32,
    cRetPalettizedThumnailCache: u32,
    cCacheSizeChanged: u32,
    cMaxLatency: u32,
    cFramesInFlight: u32,
    cFramesAvailable: u32,
    cFramesCorrupted: u32,
    cFramesDropped: u32,
    cFramesMissed: u32,
    cFramesOutOfOrder: u32,
    cFramesInOrderOK: u32,
    cFramesPended: u32,
    cInFlightFrames: u32,
    cPendingQPCIn: u32,
    cPendingQPCOut: u32,
    cPendingQPCBs: u32,
    cDXChairsInFlight: u32,
    cFramePendingOut: u32,
    cB2DFPSTickPeriod: u32,
    cVisibleContentDirtyMin: u64,
    cVisibleContentDirtyMax: u64,
};

// ============================================================================
// DWM_TRANSPORT_ICON
// ============================================================================

pub const DWM_TRANSPORT_ICON = struct {
    width: u32,
    height: u32,
    data: ?[]u8,
};

pub const DWM_TRANSPORT_LIMITS = extern struct {
    cbSize: u32,
    dwMaxIflatModes: u32,
    dwMaxOflatModes: u32,
    dwMaxNonShadowedFits: u32,
    dwMaxTriangles: u32,
    dwMaxPreferredUV: u32,
};

// ============================================================================
// RECT
// ============================================================================

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: *const RECT) i32 {
        return self.right - self.left;
    }

    pub fn height(self: *const RECT) i32 {
        return self.bottom - self.top;
    }
};

// ============================================================================
// BOOL (Windows-compatible)
// ============================================================================

pub const BOOL = i32;
pub const FALSE: BOOL = 0;
pub const TRUE: BOOL = 1;

// ============================================================================
// Colorization
// ============================================================================

pub const ColorizationParam = struct {
    color: u32,
    opacity: u32,
    color_filter: u32,
    is_opaque: bool,
};

// ============================================================================
// Flip3D
// ============================================================================

pub const DWMFLIP3D = enum(u32) {
    default = 0,
    skip_away = 1,
    skip_non_window = 2,
    excluded_below = 3,
    excluded_above = 4,
};

// ============================================================================
// Window Attribute
// ============================================================================

pub const DWMWINDOWATTRIBUTE = enum(u32) {
    dwmwa_nc_rendering_enabled = 1,
    dwmwa_transitions_forcedisabled = 2,
    dwmwa_nonclient_rendering_enabled = 3,
    dwmwa_force_iconic_representation = 4,
    dwmwa_flips3d_policy = 5,
    dwmwa_extended_frame_bounds = 6,
    dwmwa_has_iconic_bitmap = 7,
    dwmwa_disallow_peek = 8,
    dwmwa_excluded_from_peek = 9,
    dwmwa_cloak = 10,
    dwmwa_cloaked = 11,
    dwmwa_freeze_representation = 12,
    dwmwa_last = 13,
};
