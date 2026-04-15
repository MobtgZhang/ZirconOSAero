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

//! DXGI Output Implementation

const std = @import("std");
const types = @import("dxgi_types.zig");
const errors = @import("dxgi_errors.zig");

pub const Output = struct {
    desc: types.DXGI_OUTPUT_DESC,
    ref_count: u32 = 1,

    pub fn initDefault() *Output {
        const self = std.heap.page_allocator.create(Output) catch unreachable;
        self.desc = .{
            .device_name = [_]u16{0} ** 32,
            .desktop_coordinates = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
            .attached_to_desktop = true,
            .rotation = .DXGI_MODE_ROTATION_IDENTITY,
            .monitor_handle = 0xDEADBEEF,
        };
        return self;
    }

    pub fn addRef(self: *Output) void {
        self.ref_count += 1;
    }

    pub fn release(self: *Output) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            std.heap.page_allocator.destroy(self);
        }
    }

    pub fn getDesc(self: *Output, desc: *types.DXGI_OUTPUT_DESC) u32 {
        desc.* = self.desc;
        return 0; // S_OK
    }

    pub fn getDisplayModeList(self: *Output, format: types.DXGI_FORMAT, flags: u32, count: *u32, mode_list: ?[*]types.DXGI_MODE_DESC) u32 {
        _ = self;
        _ = flags;
        _ = format;

        const modes = [_]types.DXGI_MODE_DESC{
            .{
                .width = 1920,
                .height = 1080,
                .refresh_rate = .{ .numerator = 60, .denominator = 1 },
                .format = .DXGI_FORMAT_R8G8B8A8_UNORM,
                .scanline_ordering = .DXGI_MODE_SCANLINE_ORDER_PROGRESSIVE,
                .scaling = .DXGI_MODE_SCALING_UNSPECIFIED,
            },
            .{
                .width = 1280,
                .height = 720,
                .refresh_rate = .{ .numerator = 60, .denominator = 1 },
                .format = .DXGI_FORMAT_R8G8B8A8_UNORM,
                .scanline_ordering = .DXGI_MODE_SCANLINE_ORDER_PROGRESSIVE,
                .scaling = .DXGI_MODE_SCALING_UNSPECIFIED,
            },
            .{
                .width = 1024,
                .height = 768,
                .refresh_rate = .{ .numerator = 60, .denominator = 1 },
                .format = .DXGI_FORMAT_R8G8B8A8_UNORM,
                .scanline_ordering = .DXGI_MODE_SCANLINE_ORDER_PROGRESSIVE,
                .scaling = .DXGI_MODE_SCALING_UNSPECIFIED,
            },
        };

        if (mode_list == null or count.* < modes.len) {
            count.* = modes.len;
            return @intFromEnum(errors.DXGI_ERROR.DXGI_ERROR_MORE_DATA);
        }

        for (modes, 0..) |mode, i| {
            mode_list.?[i] = mode;
        }
        count.* = modes.len;

        return 0; // S_OK
    }
};

pub const DXGI_MODE_DESC = struct {
    width: u32,
    height: u32,
    refresh_rate: DXGI_RATIONAL,
    format: types.DXGI_FORMAT,
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
