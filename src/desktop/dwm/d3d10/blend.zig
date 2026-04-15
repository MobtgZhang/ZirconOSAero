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

//! D3D10 BlendState Implementation

const d3d10_types = @import("d3d10_types.zig");
const d3d10_errors = @import("d3d10_errors.zig");

// ============================================================================
// Blend State Interface
// ============================================================================

pub const ID3D10BlendState = extern struct {
    QueryInterface: fn (*const ID3D10BlendState, *const [16]u8, *?*anyopaque) callconv(.C) d3d10_types.HRESULT,
    AddRef: fn (*const ID3D10BlendState) callconv(.C) u32,
    Release: fn (*const ID3D10BlendState) callconv(.C) u32,
    GetDevice: fn (*const ID3D10BlendState) callconv(.C) *anyopaque,
    GetPrivateData: fn (*const ID3D10BlendState, *const [16]u8, *u32, *anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateData: fn (*const ID3D10BlendState, *const [16]u8, u32, *const anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateDataInterface: fn (*const ID3D10BlendState, *const [16]u8, ?*const anyopaque) callconv(.C) d3d10_types.HRESULT,
    GetDesc: fn (*const ID3D10BlendState, [*]d3d10_types.D3D10_BLEND_DESC) callconv(.C) void,
};

// ============================================================================
// Blend State Storage
// ============================================================================

pub const MAX_BLEND_STATES: usize = 32;
pub var g_blend_pool: [MAX_BLEND_STATES]?d3d10_types.D3D10_BLEND_DESC = [_]?d3d10_types.D3D10_BLEND_DESC{null} ** MAX_BLEND_STATES;
pub var g_blend_count: usize = 0;

// ============================================================================
// Blend State Creation
// ============================================================================

pub fn createBlendState(
    device: *anyopaque,
    desc: [*]const d3d10_types.D3D10_BLEND_DESC,
    ppBlendState: *?*ID3D10BlendState,
) d3d10_types.HRESULT {
    _ = device;

    if (g_blend_count >= MAX_BLEND_STATES) {
        return d3d10_errors.E_OUTOFMEMORY;
    }

    g_blend_pool[g_blend_count] = desc[0];
    g_blend_count += 1;

    _ = ppBlendState;
    return d3d10_errors.S_OK;
}

pub fn getBlendDesc(slot: usize) ?d3d10_types.D3D10_BLEND_DESC {
    if (slot < g_blend_count and g_blend_pool[slot] != null) {
        return g_blend_pool[slot].?;
    }
    return null;
}

// ============================================================================
// Default Blend States
// ============================================================================

pub const DEFAULT_BLEND_DESC: d3d10_types.D3D10_BLEND_DESC = .{
    .AlphaToCoverageEnable = d3d10_types.FALSE,
    .SrcBlend = .one,
    .DestBlend = .zero,
    .BlendOp = .add,
    .SrcBlendAlpha = .one,
    .DestBlendAlpha = .zero,
    .BlendOpAlpha = .add,
    .RenderTargetWriteMask = 0xF,
};

pub const ALPHA_BLEND_DESC: d3d10_types.D3D10_BLEND_DESC = .{
    .AlphaToCoverageEnable = d3d10_types.FALSE,
    .SrcBlend = .src_alpha,
    .DestBlend = .inv_src_alpha,
    .BlendOp = .add,
    .SrcBlendAlpha = .one,
    .DestBlendAlpha = .inv_src_alpha,
    .BlendOpAlpha = .add,
    .RenderTargetWriteMask = 0xF,
};

pub const ADDITIVE_BLEND_DESC: d3d10_types.D3D10_BLEND_DESC = .{
    .AlphaToCoverageEnable = d3d10_types.FALSE,
    .SrcBlend = .one,
    .DestBlend = .one,
    .BlendOp = .add,
    .SrcBlendAlpha = .one,
    .DestBlendAlpha = .one,
    .BlendOpAlpha = .add,
    .RenderTargetWriteMask = 0xF,
};
