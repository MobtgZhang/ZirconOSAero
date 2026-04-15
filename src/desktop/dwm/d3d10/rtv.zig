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

//! D3D10 RenderTargetView and ShaderResourceView Implementation

const d3d10_types = @import("d3d10_types.zig");
const d3d10_errors = @import("d3d10_errors.zig");

// ============================================================================
// RenderTargetView (RTV)
// ============================================================================

pub const ID3D10RenderTargetView = extern struct {
    QueryInterface: fn (*const ID3D10RenderTargetView, *const [16]u8, *?*anyopaque) callconv(.C) d3d10_types.HRESULT,
    AddRef: fn (*const ID3D10RenderTargetView) callconv(.C) u32,
    Release: fn (*const ID3D10RenderTargetView) callconv(.C) u32,
    GetDevice: fn (*const ID3D10RenderTargetView) callconv(.C) *anyopaque,
    GetPrivateData: fn (*const ID3D10RenderTargetView, *const [16]u8, *u32, *anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateData: fn (*const ID3D10RenderTargetView, *const [16]u8, u32, *const anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateDataInterface: fn (*const ID3D10RenderTargetView, *const [16]u8, ?*const anyopaque) callconv(.C) d3d10_types.HRESULT,
    GetResource: fn (*const ID3D10RenderTargetView, [*]?*anyopaque) callconv(.C) void,
    GetDesc: fn (*const ID3D10RenderTargetView, [*]D3D10_RENDER_TARGET_VIEW_DESC) callconv(.C) void,
};

pub const D3D10_RENDER_TARGET_VIEW_DESC = extern struct {
    Format: d3d10_types.DXGI_FORMAT,
    ViewDimension: D3D10_RTV_DIMENSION,
};

// ============================================================================
// RTV Dimension
// ============================================================================

pub const D3D10_RTV_DIMENSION = enum(u32) {
    unknown = 0,
    buffer = 1,
    texture1d = 2,
    texture1darray = 3,
    texture2d = 4,
    texture2darray = 5,
    texture2dms = 6,
    texture2dmsarray = 7,
    texture3d = 8,
};

// ============================================================================
// ShaderResourceView (SRV)
// ============================================================================

pub const ID3D10ShaderResourceView = extern struct {
    QueryInterface: fn (*const ID3D10ShaderResourceView, *const [16]u8, *?*anyopaque) callconv(.C) d3d10_types.HRESULT,
    AddRef: fn (*const ID3D10ShaderResourceView) callconv(.C) u32,
    Release: fn (*const ID3D10ShaderResourceView) callconv(.C) u32,
    GetDevice: fn (*const ID3D10ShaderResourceView) callconv(.C) *anyopaque,
    GetPrivateData: fn (*const ID3D10ShaderResourceView, *const [16]u8, *u32, *anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateData: fn (*const ID3D10ShaderResourceView, *const [16]u8, u32, *const anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateDataInterface: fn (*const ID3D10ShaderResourceView, *const [16]u8, ?*const anyopaque) callconv(.C) d3d10_types.HRESULT,
    GetResource: fn (*const ID3D10ShaderResourceView, [*]?*anyopaque) callconv(.C) void,
    GetDesc: fn (*const ID3D10ShaderResourceView, [*]D3D10_SHADER_RESOURCE_VIEW_DESC) callconv(.C) void,
};

pub const D3D10_SHADER_RESOURCE_VIEW_DESC = extern struct {
    Format: d3d10_types.DXGI_FORMAT,
    ViewDimension: D3D10_SRV_DIMENSION,
    u: D3D10_SRV_UNION,
};

pub const D3D10_SRV_DIMENSION = enum(u32) {
    unknown = 0,
    buffer = 1,
    texture1d = 2,
    texture1darray = 3,
    texture2d = 4,
    texture2darray = 5,
    texture2dms = 6,
    texture2dmsarray = 7,
    texture3d = 8,
    texturecube = 9,
    texturecubearray = 10,
};

pub const D3D10_SRV_UNION = extern union {
    Buffer: D3D10_BUFFER_SRV,
    Texture1D: D3D10_TEX1D_SRV,
    Texture1DArray: D3D10_TEX1D_ARRAY_SRV,
    Texture2D: D3D10_TEX2D_SRV,
    Texture2DArray: D3D10_TEX2D_ARRAY_SRV,
    Texture2DMS: D3D10_TEX2DMS_SRV,
    Texture2DMSArray: D3D10_TEX2DMS_ARRAY_SRV,
    Texture3D: D3D10_TEX3D_SRV,
    TextureCube: D3D10_TEXCUBE_SRV,
    TextureCubeArray: D3D10_TEXCUBE_ARRAY_SRV,
};

pub const D3D10_BUFFER_SRV = extern struct {
    FirstElement: u32,
    NumElements: u32,
};

pub const D3D10_TEX1D_SRV = extern struct {
    MostDetailedMip: u32,
    MipLevels: u32,
};

pub const D3D10_TEX1D_ARRAY_SRV = extern struct {
    MostDetailedMip: u32,
    MipLevels: u32,
    FirstArraySlice: u32,
    ArraySize: u32,
};

pub const D3D10_TEX2D_SRV = extern struct {
    MostDetailedMip: u32,
    MipLevels: u32,
};

pub const D3D10_TEX2D_ARRAY_SRV = extern struct {
    MostDetailedMip: u32,
    MipLevels: u32,
    FirstArraySlice: u32,
    ArraySize: u32,
};

pub const D3D10_TEX2DMS_SRV = extern struct {
    unused_field_0: u32,
};

pub const D3D10_TEX2DMS_ARRAY_SRV = extern struct {
    FirstArraySlice: u32,
    ArraySize: u32,
};

pub const D3D10_TEX3D_SRV = extern struct {
    MostDetailedMip: u32,
    MipLevels: u32,
};

pub const D3D10_TEXCUBE_SRV = extern struct {
    MostDetailedMip: u32,
    MipLevels: u32,
};

pub const D3D10_TEXCUBE_ARRAY_SRV = extern struct {
    MostDetailedMip: u32,
    MipLevels: u32,
    First2DArrayFace: u32,
    NumCubes: u32,
};

// ============================================================================
// RTV/SRV State Management
// ============================================================================

pub const MAX_RTVS: usize = 16;
pub const MAX_SRVS: usize = 128;

pub var g_rtv_pool: [MAX_RTVS]?*anyopaque = [_]?*anyopaque{null} ** MAX_RTVS;
pub var g_rtv_count: usize = 0;

pub var g_srv_pool: [MAX_SRVS]?*anyopaque = [_]?*anyopaque{null} ** MAX_SRVS;
pub var g_srv_count: usize = 0;

pub fn createRenderTargetView(
    device: *anyopaque,
    resource: *const anyopaque,
    desc: [*]const D3D10_RENDER_TARGET_VIEW_DESC,
    ppRTView: *?*ID3D10RenderTargetView,
) d3d10_types.HRESULT {
    _ = device;
    _ = resource;
    _ = desc;
    _ = ppRTView;

    if (g_rtv_count >= MAX_RTVS) {
        return d3d10_errors.E_OUTOFMEMORY;
    }

    g_rtv_count += 1;
    return d3d10_errors.S_OK;
}

pub fn createShaderResourceView(
    device: *anyopaque,
    resource: *const anyopaque,
    desc: [*]const D3D10_SHADER_RESOURCE_VIEW_DESC,
    ppSRView: *?*ID3D10ShaderResourceView,
) d3d10_types.HRESULT {
    _ = device;
    _ = resource;
    _ = desc;
    _ = ppSRView;

    if (g_srv_count >= MAX_SRVS) {
        return d3d10_errors.E_OUTOFMEMORY;
    }

    g_srv_count += 1;
    return d3d10_errors.S_OK;
}

pub fn releaseRTV(view: *anyopaque) void {
    for (g_rtv_pool[0..g_rtv_count]) |*rtv| {
        if (rtv.*) |v| {
            if (@intFromPtr(v) == @intFromPtr(view)) {
                rtv.* = null;
                return;
            }
        }
    }
}

pub fn releaseSRV(view: *anyopaque) void {
    for (g_srv_pool[0..g_srv_count]) |*srv| {
        if (srv.*) |v| {
            if (@intFromPtr(v) == @intFromPtr(view)) {
                srv.* = null;
                return;
            }
        }
    }
}
