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

//! DXGI Surface and Resource Implementation

const std = @import("std");
const d3d10_types = @import("../d3d10/d3d10_types.zig");
const dxgi_errors = @import("dxgi_errors.zig");
const dxgi_types = @import("dxgi_types.zig");
const factory = @import("factory.zig");

// ============================================================================
// IDXGISurface Interface
// ============================================================================

pub const IDXGISurface = extern struct {
    base: dxgi_types.IDXGIDeviceSubObject,
    GetDesc: fn (*const IDXGISurface, [*]DXGI_SURFACE_DESC) callconv(.C) void,
    Map: fn (*const IDXGISurface, [*]DXGI_MAPPED_RECT, u32) callconv(.C) d3d10_types.HRESULT,
    Unmap: fn (*const IDXGISurface) callconv(.C) d3d10_types.HRESULT,
};

// ============================================================================
// IDXGISurface1 Interface
// ============================================================================

pub const IDXGISurface1 = extern struct {
    base: IDXGISurface,
    GetDC: fn (*const IDXGISurface1, dxgi_types.BOOL, [*]DXGI_MAPPED_RECT) callconv(.C) d3d10_types.HRESULT,
    ReleaseDC: fn (*const IDXGISurface1, [*]const dxgi_errors.DXGI_MAPPED_RECT) callconv(.C) d3d10_types.HRESULT,
};

pub const DXGI_SURFACE_DESC = extern struct {
    Width: u32,
    Height: u32,
    Format: d3d10_types.DXGI_FORMAT,
    SampleDesc: d3d10_types.DXGI_SAMPLE_DESC,
};

pub const DXGI_MAPPED_RECT = extern struct {
    Pitch: i32,
    pBits: [*]u8,
};

// ============================================================================
// Surface State
// ============================================================================

pub const SurfaceState = struct {
    ref_count: u32,
    desc: DXGI_SURFACE_DESC,
    data: ?[]u8,
    is_mapped: bool,
    mapped_pitch: i32,
};

pub const MAX_SURFACES: usize = 128;
pub var g_surface_pool: [MAX_SURFACES]?SurfaceState = [_]?SurfaceState{null} ** MAX_SURFACES;
pub var g_surface_count: usize = 0;

// ============================================================================
// Surface Functions
// ============================================================================

pub fn createSurface(
    desc: [*]const DXGI_SURFACE_DESC,
    data: ?[]u8,
) !usize {
    if (g_surface_count >= MAX_SURFACES) {
        return error.OutOfMemory;
    }

    const surf_desc = desc[0];
    const pixel_size: usize = switch (surf_desc.Format) {
        .b8g8r8a8_unorm, .r8g8b8a8_unorm => 4,
        .b8g8r8x8_unorm => 3,
        .r32g32b32a32_float => 16,
        else => 4,
    };

    const row_pitch = surf_desc.Width * @as(u32, @intCast(pixel_size));
    const size = row_pitch * surf_desc.Height;

    var surface_data: ?[]u8 = null;
    if (data) |d| {
        surface_data = d;
    } else {
        surface_data = std.heap.page_allocator.alloc(u8, size) catch return error.OutOfMemory;
    }

    g_surface_pool[g_surface_count] = .{
        .ref_count = 1,
        .desc = surf_desc,
        .data = surface_data,
        .is_mapped = false,
        .mapped_pitch = 0,
    };

    const idx = g_surface_count;
    g_surface_count += 1;
    return idx;
}

pub fn getSurfaceData(idx: usize) ?[]u8 {
    if (idx < g_surface_count and g_surface_pool[idx] != null) {
        return g_surface_pool[idx].?.data;
    }
    return null;
}

pub fn mapSurface(idx: usize) d3d10_types.HRESULT {
    if (idx >= g_surface_count or g_surface_pool[idx] == null) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    const surf = &g_surface_pool[idx].?;
    if (surf.is_mapped) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    surf.is_mapped = true;
    surf.mapped_pitch = @as(i32, @intCast(surf.desc.Width * 4));

    return dxgi_errors.S_OK;
}

pub fn unmapSurface(idx: usize) d3d10_types.HRESULT {
    if (idx >= g_surface_count or g_surface_pool[idx] == null) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    g_surface_pool[idx].?.is_mapped = false;
    return dxgi_errors.S_OK;
}

pub fn getSurfaceDesc(idx: usize) ?DXGI_SURFACE_DESC {
    if (idx < g_surface_count and g_surface_pool[idx] != null) {
        return g_surface_pool[idx].?.desc;
    }
    return null;
}

pub fn releaseSurface(idx: usize) void {
    if (idx < g_surface_count and g_surface_pool[idx] != null) {
        const surf = &g_surface_pool[idx].?;
        surf.ref_count -= 1;
        if (surf.ref_count == 0) {
            if (surf.data) |d| {
                std.heap.page_allocator.free(d);
            }
            g_surface_pool[idx] = null;
        }
    }
}

// ============================================================================
// IDXGIResource Interface
// ============================================================================

pub const IDXGIResource = extern struct {
    base: dxgi_types.IDXGIDeviceSubObject,
    GetSharedHandle: fn (*const IDXGIResource, [*]?*anyopaque) callconv(.C) d3d10_types.HRESULT,
    GetUsage: fn (*const IDXGIResource, [*]u32) callconv(.C) d3d10_types.HRESULT,
    SetEvictionPriority: fn (*const IDXGIResource, u32) callconv(.C) d3d10_types.HRESULT,
    GetEvictionPriority: fn (*const IDXGIResource) callconv(.C) u32,
};

// ============================================================================
// Resource State
// ============================================================================

pub const MAX_RESOURCES: usize = 256;
pub var g_resource_pool: [MAX_RESOURCES]?struct {
    shared_handle: ?*anyopaque,
    usage: u32,
    eviction_priority: u32,
} = [_]?struct { shared_handle: ?*anyopaque, usage: u32, eviction_priority: u32 }{null} ** MAX_RESOURCES;
pub var g_resource_count: usize = 0;

pub fn createResource(shared_handle: ?*anyopaque, usage: u32) !usize {
    if (g_resource_count >= MAX_RESOURCES) {
        return error.OutOfMemory;
    }

    g_resource_pool[g_resource_count] = .{
        .shared_handle = shared_handle,
        .usage = usage,
        .eviction_priority = 0,
    };

    const idx = g_resource_count;
    g_resource_count += 1;
    return idx;
}

pub fn getResourceSharedHandle(idx: usize) ?*anyopaque {
    if (idx < g_resource_count and g_resource_pool[idx] != null) {
        return g_resource_pool[idx].?.shared_handle;
    }
    return null;
}

pub fn setResourceEvictionPriority(idx: usize, priority: u32) void {
    if (idx < g_resource_count and g_resource_pool[idx] != null) {
        g_resource_pool[idx].?.eviction_priority = priority;
    }
}
