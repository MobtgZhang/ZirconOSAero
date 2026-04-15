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

//! DXGI Adapter Implementation

const std = @import("std");
const types = @import("dxgi_types.zig");

pub const Adapter = struct {
    desc: types.DXGI_ADAPTER_DESC,
    outputs: []types.DXGI_OUTPUT_DESC,
    ref_count: u32 = 1,

    pub fn initDefault() !*Adapter {
        const self = try std.heap.page_allocator.create(Adapter);
        errdefer std.heap.page_allocator.destroy(self);

        // Default virtual adapter for VGA
        self.desc = .{
            .description = [_]u16{0} ** 128,
            .vendor_id = 0x1234,
            .device_id = 0x5678,
            .sub_sys_id = 0x9ABC,
            .revision = 0,
            .dedicated_video_memory = 256 * 1024 * 1024, // 256MB VRAM
            .dedicated_system_memory = 0,
            .shared_system_memory = 512 * 1024 * 1024, // 512MB shared
            .adapter_luid = .{ .low_part = 1, .high_part = 0 },
        };

        // Default output
        self.outputs = try std.heap.page_allocator.alloc(types.DXGI_OUTPUT_DESC, 1);
        self.outputs[0] = .{
            .device_name = [_]u16{0} ** 32,
            .desktop_coordinates = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
            .attached_to_desktop = true,
            .rotation = .DXGI_MODE_ROTATION_IDENTITY,
            .monitor_handle = 0xDEADBEEF,
        };

        return self;
    }

    pub fn addRef(self: *Adapter) void {
        self.ref_count += 1;
    }

    pub fn release(self: *Adapter) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            std.heap.page_allocator.free(self.outputs);
            std.heap.page_allocator.destroy(self);
        }
    }

    pub fn enumOutputs(self: *Adapter, index: u32, output: **types.DXGI_OUTPUT_DESC) u32 {
        if (index >= self.outputs.len) return @intFromEnum(@import("dxgi_errors.zig").DXGI_ERROR.DXGI_ERROR_NOT_FOUND);
        output.* = &self.outputs[index];
        return 0; // S_OK
    }

    pub fn getDesc(self: *Adapter, desc: *types.DXGI_ADAPTER_DESC) u32 {
        desc.* = self.desc;
        return 0; // S_OK
    }
};

var g_default_adapter: ?*Adapter = null;

pub fn init() void {
    g_default_adapter = Adapter.initDefault() catch unreachable;
}

pub fn deinit() void {
    if (g_default_adapter) |adapter| {
        adapter.release();
        g_default_adapter = null;
    }
}

pub fn getDefaultAdapter() ?*Adapter {
    return g_default_adapter;
}
