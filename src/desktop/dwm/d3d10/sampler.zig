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

//! D3D10 SamplerState Implementation

const d3d10_types = @import("d3d10_types.zig");
const d3d10_errors = @import("d3d10_errors.zig");

// ============================================================================
// Sampler State Interface
// ============================================================================

pub const ID3D10SamplerState = extern struct {
    QueryInterface: fn (*const ID3D10SamplerState, *const [16]u8, *?*anyopaque) callconv(.C) d3d10_types.HRESULT,
    AddRef: fn (*const ID3D10SamplerState) callconv(.C) u32,
    Release: fn (*const ID3D10SamplerState) callconv(.C) u32,
    GetDevice: fn (*const ID3D10SamplerState) callconv(.C) *anyopaque,
    GetPrivateData: fn (*const ID3D10SamplerState, *const [16]u8, *u32, *anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateData: fn (*const ID3D10SamplerState, *const [16]u8, u32, *const anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateDataInterface: fn (*const ID3D10SamplerState, *const [16]u8, ?*const anyopaque) callconv(.C) d3d10_types.HRESULT,
    GetDesc: fn (*const ID3D10SamplerState, [*]d3d10_types.D3D10_SAMPLER_DESC) callconv(.C) void,
};

// ============================================================================
// Sampler State Storage
// ============================================================================

pub const MAX_SAMPLERS: usize = 32;
pub var g_sampler_pool: [MAX_SAMPLERS]?d3d10_types.D3D10_SAMPLER_DESC = [_]?d3d10_types.D3D10_SAMPLER_DESC{null} ** MAX_SAMPLERS;
pub var g_sampler_count: usize = 0;

// ============================================================================
// Sampler Creation
// ============================================================================

pub fn createSamplerState(
    device: *anyopaque,
    desc: [*]const d3d10_types.D3D10_SAMPLER_DESC,
    ppSamplerState: *?*ID3D10SamplerState,
) d3d10_types.HRESULT {
    _ = device;

    if (g_sampler_count >= MAX_SAMPLERS) {
        return d3d10_errors.E_OUTOFMEMORY;
    }

    g_sampler_pool[g_sampler_count] = desc[0];
    g_sampler_count += 1;

    _ = ppSamplerState;
    return d3d10_errors.S_OK;
}

pub fn getSamplerDesc(slot: usize) ?d3d10_types.D3D10_SAMPLER_DESC {
    if (slot < g_sampler_count and g_sampler_pool[slot] != null) {
        return g_sampler_pool[slot].?;
    }
    return null;
}
