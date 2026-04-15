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

//! DXGI Error Codes
//! Clean-room implementation of DXGI error codes.

// DXGI error codes (HRESULT values)
pub const DXGI_ERROR = enum(u32) {
    DXGI_ERROR_DEVICE_HUNG = 0x887A0006,
    DXGI_ERROR_DEVICE_REMOVED = 0x887A0005,
    DXGI_ERROR_DEVICE_RESET = 0x887A0007,
    DXGI_ERROR_DRIVER_INTERNAL_ERROR = 0x887A0020,
    DXGI_ERROR_FRAME_STATISTICS_DISJOINT = 0x887A000B,
    DXGI_ERROR_GRAPHICS_VIDPN_SOURCE_IN_USE = 0x887A000C,
    DXGI_ERROR_INVALID_CALL = 0x887A0001,
    DXGI_ERROR_MORE_DATA = 0x887A0003,
    DXGI_ERROR_NONE = 0x00000000,
    DXGI_ERROR_NOT_CURRENTLY_AVAILABLE = 0x887A0022,
    DXGI_ERROR_NOT_FOUND = 0x887A0002,
    DXGI_ERROR_REMOTE_CLIENT_DISCONNECTED = 0x887A0023,
    DXGI_ERROR_REMOTE_OUTOFMEMORY = 0x887A0024,
    DXGI_ERROR_UNSUPPORTED = 0x887A0004,
    DXGI_ERROR_WAS_STILL_DRAWING = 0x887A000A,
    DXGI_STATUS_OCCLUDED = 0x087A0001,
    DXGI_STATUS_MODE_CHANGE_IN_PROGRESS = 0x087A0004,
};

pub const HRESULT = u32;

pub fn SUCCEEDED(hr: HRESULT) bool {
    return hr < 0x80000000;
}

pub fn FAILED(hr: HRESULT) bool {
    return hr >= 0x80000000;
}
