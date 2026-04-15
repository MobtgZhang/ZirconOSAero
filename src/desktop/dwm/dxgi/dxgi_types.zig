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

//! DXGI Types Definitions
//! Clean-room implementation of DXGI types for DWM compositor.

const std = @import("std");

// ============================================================================
// DXGI Formats
// ============================================================================

pub const DXGI_FORMAT = enum(u32) {
    DXGI_FORMAT_UNKNOWN = 0,
    DXGI_FORMAT_R32G32B32A32_TYPELESS = 1,
    DXGI_FORMAT_R32G32B32A32_FLOAT = 2,
    DXGI_FORMAT_R32G32B32A32_UINT = 3,
    DXGI_FORMAT_R32G32B32A32_SINT = 4,
    DXGI_FORMAT_R32G32B32_TYPELESS = 5,
    DXGI_FORMAT_R32G32B32_FLOAT = 6,
    DXGI_FORMAT_R32G32B32_UINT = 7,
    DXGI_FORMAT_R32G32B32_SINT = 8,
    DXGI_FORMAT_R16G16B16A16_TYPELESS = 9,
    DXGI_FORMAT_R16G16B16A16_FLOAT = 10,
    DXGI_FORMAT_R16G16B16A16_UNORM = 11,
    DXGI_FORMAT_R16G16B16A16_UINT = 12,
    DXGI_FORMAT_R16G16B16A16_SNORM = 13,
    DXGI_FORMAT_R16G16B16A16_SINT = 14,
    DXGI_FORMAT_R32G32_TYPELESS = 15,
    DXGI_FORMAT_R32G32_FLOAT = 16,
    DXGI_FORMAT_R32G32_UINT = 17,
    DXGI_FORMAT_R32G32_SINT = 18,
    DXGI_FORMAT_R32G8X24_TYPELESS = 19,
    DXGI_FORMAT_D32_FLOAT_S8X24_UINT = 20,
    DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS = 21,
    DXGI_FORMAT_X32_TYPELESS_G8X24_UINT = 22,
    DXGI_FORMAT_R10G10B10A2_TYPELESS = 23,
    DXGI_FORMAT_R10G10B10A2_UNORM = 24,
    DXGI_FORMAT_R10G10B10A2_UINT = 25,
    DXGI_FORMAT_R11G11B10_FLOAT = 26,
    DXGI_FORMAT_R8G8B8A8_TYPELESS = 27,
    DXGI_FORMAT_R8G8B8A8_UNORM = 28,
    DXGI_FORMAT_R8G8B8A8_UNORM_SRGB = 29,
    DXGI_FORMAT_R8G8B8A8_UINT = 30,
    DXGI_FORMAT_R8G8B8A8_SNORM = 31,
    DXGI_FORMAT_R8G8B8A8_SINT = 32,
    DXGI_FORMAT_R16G16_TYPELESS = 33,
    DXGI_FORMAT_R16G16_FLOAT = 34,
    DXGI_FORMAT_R16G16_UNORM = 35,
    DXGI_FORMAT_R16G16_UINT = 36,
    DXGI_FORMAT_R16G16_SNORM = 37,
    DXGI_FORMAT_R16G16_SINT = 38,
    DXGI_FORMAT_R8G8_TYPELESS = 39,
    DXGI_FORMAT_R8G8_UNORM = 40,
    DXGI_FORMAT_R8G8_UINT = 41,
    DXGI_FORMAT_R8G8_SNORM = 42,
    DXGI_FORMAT_R8G8_SINT = 43,
    DXGI_FORMAT_R16_TYPELESS = 44,
    DXGI_FORMAT_R16_FLOAT = 45,
    DXGI_FORMAT_R16_UNORM = 46,
    DXGI_FORMAT_R16_UINT = 47,
    DXGI_FORMAT_R16_SNORM = 48,
    DXGI_FORMAT_R16_SINT = 49,
    DXGI_FORMAT_R32_TYPELESS = 55,
    DXGI_FORMAT_R32_FLOAT = 56,
    DXGI_FORMAT_R32_UINT = 57,
    DXGI_FORMAT_R32_SINT = 58,
    DXGI_FORMAT_R8_TYPELESS = 50,
    DXGI_FORMAT_R8_UNORM = 51,
    DXGI_FORMAT_R8_UINT = 52,
    DXGI_FORMAT_R8_SNORM = 53,
    DXGI_FORMAT_R8_SINT = 54,
    DXGI_FORMAT_D16_UNORM = 75,
    // Common compressed formats omitted for brevity
    DXGI_FORMAT_B8G8R8A8_UNORM = 87,
    DXGI_FORMAT_B8G8R8X8_UNORM = 88,
};

pub const DXGI_SURFACE_DESC = struct {
    width: u32,
    height: u32,
    format: DXGI_FORMAT,
    sample_desc: DXGI_SAMPLE_DESC,
};

pub const DXGI_SURFACE = struct {
    desc: DXGI_SURFACE_DESC,
    buffer: []u8,
    stride: u32,
    ref_count: u32 = 1,

    pub fn addRef(self: *DXGI_SURFACE) void {
        self.ref_count += 1;
    }

    pub fn release(self: *DXGI_SURFACE) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            std.heap.page_allocator.free(self.buffer);
            std.heap.page_allocator.destroy(self);
        }
    }
};

// ============================================================================
// DXGI Sample Description
// ============================================================================

pub const DXGI_SAMPLE_DESC = struct {
    count: u32,
    quality: u32,
};

// ============================================================================
// DXGI Rect
// ============================================================================

pub const RECT = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const MARGINS = struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};

// ============================================================================
// DXGI Present Parameters
// ============================================================================

pub const DXGI_PRESENT_PARAMETERS = struct {
    dirty_rects_count: u32,
    p_dirty_rects: [*]RECT,
    p_scroll_rect: ?*RECT,
    p_scroll_offset: ?*POINT,
};

pub const POINT = struct {
    x: i32,
    y: i32,
};

// ============================================================================
// DXGI Adapter Description
// ============================================================================

pub const DXGI_ADAPTER_DESC = struct {
    description: [128]u16,
    vendor_id: u32,
    device_id: u32,
    sub_sys_id: u32,
    revision: u32,
    dedicated_video_memory: usize,
    dedicated_system_memory: usize,
    shared_system_memory: usize,
    adapter_luid: LUID,
};

pub const LUID = struct {
    low_part: u32,
    high_part: i32,
};

// ============================================================================
// DXGI Output Description
// ============================================================================

pub const DXGI_OUTPUT_DESC = struct {
    device_name: [32]u16,
    desktop_coordinates: RECT,
    attached_to_desktop: bool,
    rotation: DXGI_MODE_ROTATION,
    monitor_handle: usize,
};

pub const DXGI_MODE_ROTATION = enum(u32) {
    DXGI_MODE_ROTATION_UNSPECIFIED = 0,
    DXGI_MODE_ROTATION_IDENTITY = 1,
    DXGI_MODE_ROTATION_ROTATE90 = 2,
    DXGI_MODE_ROTATION_ROTATE180 = 3,
    DXGI_MODE_ROTATION_ROTATE270 = 4,
};

// Swap Chain Description
pub const DXGI_SWAP_CHAIN_DESC = struct {
    buffer_desc: DXGI_MODE_DESC,
    sample_desc: DXGI_SAMPLE_DESC,
    buffer_usage: u32,
    buffer_count: u32,
    output_window: usize,
    windowed: bool,
    swap_effect: DXGI_SWAP_EFFECT,
    flags: u32,
};

pub const DXGI_MODE_DESC = struct {
    width: u32,
    height: u32,
    refresh_rate: DXGI_RATIONAL,
    format: DXGI_FORMAT,
    scanline_ordering: DXGI_MODE_SCANLINE_ORDER,
    scaling: DXGI_MODE_SCALING,
};

pub const DXGI_RATIONAL = struct {
    numerator: u32,
    denominator: u32,
};

pub const DXGI_MODE_SCANLINE_ORDER = enum(u32) {
    DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED = 0,
    DXGI_MODE_SCANLINE_ORDER_PROGRESSIVE = 1,
    DXGI_MODE_SCANLINE_ORDER_UPPER_FIELD_FIRST = 2,
    DXGI_MODE_SCANLINE_ORDER_LOWER_FIELD_FIRST = 3,
};

pub const DXGI_MODE_SCALING = enum(u32) {
    DXGI_MODE_SCALING_UNSPECIFIED = 0,
    DXGI_MODE_SCALING_CENTERED = 1,
    DXGI_MODE_SCALING_STRETCHED = 2,
};

pub const DXGI_SWAP_EFFECT = enum(u32) {
    DXGI_SWAP_EFFECT_DISCARD = 0,
    DXGI_SWAP_EFFECT_SEQUENTIAL = 1,
    DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL = 3,
    DXGI_SWAP_EFFECT_FLIP_DISCARD = 4,
};
