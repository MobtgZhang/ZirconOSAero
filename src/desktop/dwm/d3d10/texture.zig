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

//! D3D10 Texture2D Implementation for ZirconOS DWM
//! Clean-room implementation of ID3D10Texture2D interface.

const std = @import("std");
const d3d10_types = @import("d3d10_types.zig");
const d3d10_errors = @import("d3d10_errors.zig");

// ============================================================================
// ID3D10Resource Interface
// ============================================================================

pub const ID3D10Resource = extern struct {
    QueryInterface: fn (*const ID3D10Resource, *const [16]u8, *?*anyopaque) callconv(.C) d3d10_types.HRESULT,
    AddRef: fn (*const ID3D10Resource) callconv(.C) u32,
    Release: fn (*const ID3D10Resource) callconv(.C) u32,
    GetDevice: fn (*const ID3D10Resource) callconv(.C) *anyopaque,
    GetPrivateData: fn (*const ID3D10Resource, *const [16]u8, *u32, *anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateData: fn (*const ID3D10Resource, *const [16]u8, u32, *const anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateDataInterface: fn (*const ID3D10Resource, *const [16]u8, ?*const anyopaque) callconv(.C) d3d10_types.HRESULT,
    GetType: fn (*const ID3D10Resource) callconv(.C) d3d10_types.D3D10_RESOURCE_DIMENSION,
    SetEvictionPriority: fn (*const ID3D10Resource, u32) callconv(.C) void,
    GetEvictionPriority: fn (*const ID3D10Resource) callconv(.C) u32,
};

// ============================================================================
// ID3D10Texture2D Interface
// ============================================================================

pub const ID3D10Texture2D = extern struct {
    resource: ID3D10Resource,
    GetDesc: fn (*const ID3D10Texture2D, [*]d3d10_types.D3D10_TEXTURE2D_DESC) callconv(.C) void,
    Map: fn (*const ID3D10Texture2D, u32, d3d10_types.D3D10_MAP, u32, *?*anyopaque) callconv(.C) d3d10_types.HRESULT,
    Unmap: fn (*const ID3D10Texture2D, u32) callconv(.C) void,
};

// ============================================================================
// D3D10_MAP
// ============================================================================

pub const D3D10_MAP = enum(u32) {
    read = 1,
    write = 2,
    read_write = 3,
    write_discard = 4,
    write_no_overwrite = 5,
};

// ============================================================================
// Internal Texture State
// ============================================================================

pub const Texture2DState = struct {
    ref_count: u32,
    desc: d3d10_types.D3D10_TEXTURE2D_DESC,
    data: ?[]u8,
    mapped_data: ?[]u8,
    is_mapped: bool,
};

pub const MAX_TEXTURES: usize = 256;
pub var g_texture_pool: [MAX_TEXTURES]?Texture2DState = [_]?Texture2DState{null} ** MAX_TEXTURES;
pub var g_texture_count: usize = 0;
pub var g_texture_next_id: u32 = 1;

// ============================================================================
// Texture Creation Functions
// ============================================================================

pub fn createTexture2D(
    device: *anyopaque,
    desc: [*]const d3d10_types.D3D10_TEXTURE2D_DESC,
    initial_data: ?[*]const d3d10_types.D3D10_SUBRESOURCE_DATA,
    ppTexture2D: *?*ID3D10Texture2D,
) d3d10_types.HRESULT {
    _ = device;

    if (g_texture_count >= MAX_TEXTURES) {
        return d3d10_errors.E_OUTOFMEMORY;
    }

    const idx = g_texture_count;
    g_texture_count += 1;

    const tex_desc = desc[0];
    const pixel_size: usize = switch (tex_desc.Format) {
        .b8g8r8a8_unorm, .r8g8b8a8_unorm => 4,
        .b8g8r8x8_unorm => 3,
        .r16g16b16a16_float => 8,
        .r32g32b32a32_float => 16,
        else => 4,
    };

    const row_pitch = tex_desc.Width * @as(u32, @intCast(pixel_size));
    const slice_pitch = row_pitch * tex_desc.Height;

    g_texture_pool[idx] = .{
        .ref_count = 1,
        .desc = tex_desc,
        .data = std.heap.page_allocator.alloc(u8, slice_pitch) catch null,
        .mapped_data = null,
        .is_mapped = false,
    };

    if (g_texture_pool[idx]) |*state| {
        if (initial_data) |data| {
            const copy_size = @min(slice_pitch, data[0].SysMemPitch * tex_desc.Height);
            @memcpy(state.data.?[0..copy_size], @as([*]const u8, @ptrCast(data[0].pSysMem))[0..copy_size]);
        }
    }

    _ = ppTexture2D;
    return d3d10_errors.S_OK;
}

pub fn getTextureDesc(id: u32) ?d3d10_types.D3D10_TEXTURE2D_DESC {
    for (g_texture_pool[0..g_texture_count]) |tex| {
        if (tex) |t| {
            if (t.ref_count > 0 and t.desc.Width == id) {
                return t.desc;
            }
        }
    }
    return null;
}

pub fn getTextureData(id: u32) ?[]u8 {
    for (g_texture_pool[0..g_texture_count]) |tex| {
        if (tex) |t| {
            if (t.ref_count > 0 and t.desc.Width == id) {
                return t.data;
            }
        }
    }
    return null;
}

pub fn mapTexture(id: u32, subresource: u32, _: D3D10_MAP, map_flags: u32, locked_rect: *?[*]u8) d3d10_types.HRESULT {
    _ = subresource;
    _ = map_flags;

    for (g_texture_pool[0..g_texture_count]) |*tex| {
        if (tex.*) |*t| {
            if (t.ref_count > 0 and t.desc.Width == id) {
                if (t.is_mapped) {
                    return d3d10_errors.D3D_ERR_INVALIDCALL;
                }
                t.is_mapped = true;
                t.mapped_data = t.data;
                locked_rect.* = if (t.mapped_data) |d| @as([*]u8, @ptrCast(d.ptr)) else null;
                return d3d10_errors.S_OK;
            }
        }
    }
    return d3d10_errors.E_INVALIDARG;
}

pub fn unmapTexture(id: u32, subresource: u32) d3d10_types.HRESULT {
    _ = subresource;

    for (g_texture_pool[0..g_texture_count]) |*tex| {
        if (tex.*) |*t| {
            if (t.ref_count > 0 and t.desc.Width == id) {
                t.is_mapped = false;
                t.mapped_data = null;
                return d3d10_errors.S_OK;
            }
        }
    }
    return d3d10_errors.E_INVALIDARG;
}

pub fn releaseTexture(id: u32) void {
    for (g_texture_pool[0..g_texture_count]) |*tex| {
        if (tex.*) |*t| {
            if (t.ref_count > 0 and t.desc.Width == id) {
                t.ref_count -= 1;
                if (t.ref_count == 0) {
                    if (t.data) |d| {
                        std.heap.page_allocator.free(d);
                    }
                    tex.* = null;
                }
                return;
            }
        }
    }
}
