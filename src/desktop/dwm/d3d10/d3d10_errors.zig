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

//! D3D10/DXGI Error Codes for ZirconOS DWM
//! Clean-room implementation based on public DirectX documentation.

pub const HRESULT = i32;

// ============================================================================
// D3D10 HRESULT Codes
// ============================================================================

pub const D3D_OK: HRESULT = 0;
pub const D3D_ERR_INVALIDCALL: HRESULT = 0x876;
pub const D3D_ERR_WASSTILLDRAWING: HRESULT = 0x877;

// ============================================================================
// DXGI HRESULT Codes
// ============================================================================

pub const DXGI_ERROR_INVALID_CALL: HRESULT = 0x887A0001;
pub const DXGI_ERROR_NOT_FOUND: HRESULT = 0x887A0005;
pub const DXGI_ERROR_MORE_DATA: HRESULT = 0x887A0003;
pub const DXGI_ERROR_UNSUPPORTED: HRESULT = 0x887A0002;
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = 0x887A0006;
pub const DXGI_ERROR_DEVICE_HUNG: HRESULT = 0x887A0007;
pub const DXGI_ERROR_INVALID_PARAM: HRESULT = 0x0C700000;
pub const DXGI_ERROR_ACCESS_LOST: HRESULT = 0x887A0020;
pub const DXGI_ERROR_ACCESS_DENIED: HRESULT = 0x887A0021;
pub const DXGI_ERROR_WAIT_TIMEOUT: HRESULT = 0x887A0022;
pub const DXGI_ERROR_NO_OUTPUT: HRESULT = 0x887A0023;
pub const DXGI_ERROR_GRAPHICS_STOPPED: HRESULT = 0x887A0024;
pub const DXGI_ERROR_NONEXCLUSIVE: HRESULT = 0x887A0025;

pub const DXGI_STATUS_OCCLUDED: HRESULT = 0x08700001;
pub const DXGI_STATUS_CLIPPED: HRESULT = 0x08700002;
pub const DXGI_STATUS_NO_REDIRECTION: HRESULT = 0x08700004;
pub const DXGI_STATUS_NO_DESKTOP_ACCESS: HRESULT = 0x08700005;
pub const DXGI_STATUS_GRAPHICS_VENDOR_NONE: HRESULT = 0x08700008;
pub const DXGI_STATUS_MODE_CHANGED: HRESULT = 0x08700009;
pub const DXGI_STATUS_MODE_CHANGE_IN_PROGRESS: HRESULT = 0x0870000A;
pub const DXGI_STATUS_INVALID_GRAPHICS_STATE: HRESULT = 0x0870000B;

// ============================================================================
// DWM HRESULT Codes
// ============================================================================

pub const DWM_E_COMPOSITIONDISABLED: HRESULT = 0x80070057;
pub const DWM_E_NOTALLOWED: HRESULT = 0x80070005;
pub const DWM_E_INVALIDTHUMBNAIL: HRESULT = 0x80070578;
pub const DWM_S_REDRAW_ALL: HRESULT = 0x00263063;
pub const DWM_S_WINDOWSPRESCENTED: HRESULT = 0x00263065;

// ============================================================================
// Standard HRESULT Codes
// ============================================================================

pub const E_FAIL: HRESULT = -2147467259;
pub const E_INVALIDARG: HRESULT = -2147024809;
pub const E_OUTOFMEMORY: HRESULT = -2147024882;
pub const E_HANDLE: HRESULT = -2147024890;
pub const E_NOTIMPL: HRESULT = -2147467263;
pub const E_ACCESSDENIED: HRESULT = -2147024891;
pub const E_POINTER: HRESULT = -2147024891;

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;

// ============================================================================
// Helper functions
// ============================================================================

pub fn SUCCEEDED(hr: HRESULT) bool {
    return hr >= 0;
}

pub fn FAILED(hr: HRESULT) bool {
    return hr < 0;
}

pub fn getErrorName(hr: HRESULT) [:0]const u8 {
    return switch (hr) {
        D3D_OK => "D3D_OK",
        D3D_ERR_INVALIDCALL => "D3D_ERR_INVALIDCALL",
        D3D_ERR_WASSTILLDRAWING => "D3D_ERR_WASSTILLDRAWING",
        DXGI_ERROR_INVALID_CALL => "DXGI_ERROR_INVALID_CALL",
        DXGI_ERROR_NOT_FOUND => "DXGI_ERROR_NOT_FOUND",
        DXGI_ERROR_UNSUPPORTED => "DXGI_ERROR_UNSUPPORTED",
        DXGI_ERROR_DEVICE_REMOVED => "DXGI_ERROR_DEVICE_REMOVED",
        DXGI_STATUS_OCCLUDED => "DXGI_STATUS_OCCLUDED",
        DWM_E_COMPOSITIONDISABLED => "DWM_E_COMPOSITIONDISABLED",
        E_FAIL => "E_FAIL",
        E_INVALIDARG => "E_INVALIDARG",
        E_OUTOFMEMORY => "E_OUTOFMEMORY",
        S_OK => "S_OK",
        S_FALSE => "S_FALSE",
        else => "UNKNOWN_HRESULT",
    };
}
