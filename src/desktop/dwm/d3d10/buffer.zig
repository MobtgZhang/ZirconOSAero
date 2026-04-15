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

//! D3D10 Buffer Implementation for ZirconOS DWM
//! Clean-room implementation of Vertex/Index/Constant buffers.

const std = @import("std");
const d3d10_types = @import("d3d10_types.zig");
const d3d10_errors = @import("d3d10_errors.zig");

// ============================================================================
// Buffer Types
// ============================================================================

pub const BufferType = enum {
    vertex,
    index,
    constant,
    stream_output,
};

// ============================================================================
// Buffer State
// ============================================================================

pub const BufferState = struct {
    ref_count: u32,
    desc: d3d10_types.D3D10_BUFFER_DESC,
    buffer_type: BufferType,
    data: ?[]u8,
    is_mapped: bool,
};

pub const MAX_BUFFERS: usize = 512;
pub var g_buffer_pool: [MAX_BUFFERS]?BufferState = [_]?BufferState{null} ** MAX_BUFFERS;
pub var g_buffer_count: usize = 0;

// ============================================================================
// Buffer Creation
// ============================================================================

pub fn createBuffer(
    device: *anyopaque,
    desc: [*]const d3d10_types.D3D10_BUFFER_DESC,
    initial_data: ?[*]const d3d10_types.D3D10_SUBRESOURCE_DATA,
    ppBuffer: *?*anyopaque,
) d3d10_types.HRESULT {
    _ = device;

    if (g_buffer_count >= MAX_BUFFERS) {
        return d3d10_errors.E_OUTOFMEMORY;
    }

    const buf_desc = desc[0];
    const byte_width = buf_desc.ByteWidth;

    const buf_type: BufferType = if ((buf_desc.BindFlags & d3d10_types.D3D10_BIND_VERTEX_BUFFER) != 0)
        .vertex
    else if ((buf_desc.BindFlags & d3d10_types.D3D10_BIND_INDEX_BUFFER) != 0)
        .index
    else if ((buf_desc.BindFlags & d3d10_types.D3D10_BIND_CONSTANT_BUFFER) != 0)
        .constant
    else
        .stream_output;

    var data: ?[]u8 = null;
    if (byte_width > 0) {
        data = std.heap.page_allocator.alloc(u8, byte_width) catch null;
        if (data == null) {
            return d3d10_errors.E_OUTOFMEMORY;
        }
        if (initial_data) |init| {
            const copy_size = @min(byte_width, init[0].SysMemPitch);
            @memcpy(data.?[0..copy_size], @as([*]const u8, @ptrCast(init[0].pSysMem))[0..copy_size]);
        }
    }

    const idx = g_buffer_count;
    g_buffer_count += 1;

    g_buffer_pool[idx] = .{
        .ref_count = 1,
        .desc = buf_desc,
        .buffer_type = buf_type,
        .data = data,
        .is_mapped = false,
    };

    _ = ppBuffer;
    return d3d10_errors.S_OK;
}

pub fn getBufferData(id: usize) ?[]u8 {
    if (id < g_buffer_count and g_buffer_pool[id] != null) {
        return g_buffer_pool[id].?.data;
    }
    return null;
}

pub fn updateBuffer(
    device: *anyopaque,
    buffer: *anyopaque,
    data: [*]const anyopaque,
    size: usize,
) d3d10_types.HRESULT {
    _ = device;

    for (g_buffer_pool[0..g_buffer_count]) |*buf| {
        if (buf.*) |*b| {
            if (@intFromPtr(b.data.?.ptr) == @intFromPtr(buffer)) {
                const copy_size = @min(b.desc.ByteWidth, @as(u32, @intCast(size)));
                @memcpy(b.data.?[0..copy_size], @as([*]const u8, @ptrCast(data))[0..copy_size]);
                return d3d10_errors.S_OK;
            }
        }
    }
    return d3d10_errors.E_INVALIDARG;
}

pub fn releaseBuffer(id: usize) void {
    if (id < g_buffer_count and g_buffer_pool[id] != null) {
        const buf = &g_buffer_pool[id];
        if (buf.*) |*b| {
            b.ref_count -= 1;
            if (b.ref_count == 0) {
                if (b.data) |d| {
                    std.heap.page_allocator.free(d);
                }
                buf.* = null;
            }
        }
    }
}
