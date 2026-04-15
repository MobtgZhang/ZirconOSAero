// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// DWM API Error Codes

const std = @import("std");

pub const HRESULT = i32;

// ============================================================================
// DWM Error Codes
// ============================================================================

pub const DWM_E_COMPOSITIONDISABLED: HRESULT = 0x80070057;
pub const DWM_E_NOTALLOWED: HRESULT = 0x80070005;
pub const DWM_E_INVALIDTHUMBNAIL: HRESULT = -2147021960;
pub const DWM_S_REDRAW_ALL: HRESULT = 0x00263063;
pub const DWM_S_WINDOWSPRESCENTED: HRESULT = 0x00263065;
pub const DWM_E_REDIRECTING_DCOMP: HRESULT = 0x80070583;
pub const DWM_E_HWNWS_TO_BE_REDIRECTED: HRESULT = 0x80070584;
pub const DWM_E_CANT_RESIZE_ICONIC: HRESULT = 0x80070585;

// ============================================================================
// Standard HRESULT
// ============================================================================

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_FAIL: HRESULT = -2147467259;
pub const E_INVALIDARG: HRESULT = -2147024809;
pub const E_OUTOFMEMORY: HRESULT = -2147024882;
pub const E_NOTIMPL: HRESULT = -2147467263;
pub const E_ACCESSDENIED: HRESULT = -2147024891;
pub const E_POINTER: HRESULT = -2147024891;
pub const E_HANDLE: HRESULT = -2147024890;

// ============================================================================
// Helper Functions
// ============================================================================

pub fn SUCCEEDED(hr: HRESULT) bool {
    return hr >= 0;
}

pub fn FAILED(hr: HRESULT) bool {
    return hr < 0;
}

pub fn getErrorName(hr: HRESULT) [:0]const u8 {
    return switch (hr) {
        S_OK => "S_OK",
        S_FALSE => "S_FALSE",
        E_FAIL => "E_FAIL",
        E_INVALIDARG => "E_INVALIDARG",
        E_OUTOFMEMORY => "E_OUTOFMEMORY",
        E_NOTIMPL => "E_NOTIMPL",
        E_ACCESSDENIED => "E_ACCESSDENIED",
        E_POINTER => "E_POINTER",
        E_HANDLE => "E_HANDLE",
        DWM_E_COMPOSITIONDISABLED => "DWM_E_COMPOSITIONDISABLED",
        DWM_E_NOTALLOWED => "DWM_E_NOTALLOWED",
        DWM_E_INVALIDTHUMBNAIL => "DWM_E_INVALIDTHUMBNAIL",
        DWM_S_REDRAW_ALL => "DWM_S_REDRAW_ALL",
        DWM_S_WINDOWSPRESCENTED => "DWM_S_WINDOWSPRESCENTED",
        DWM_E_REDIRECTING_DCOMP => "DWM_E_REDIRECTING_DCOMP",
        DWM_E_CANT_RESIZE_ICONIC => "DWM_E_CANT_RESIZE_ICONIC",
        else => "UNKNOWN_HRESULT",
    };
}
