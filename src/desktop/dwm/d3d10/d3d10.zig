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

//! D3D10 Module Entry Point for ZirconOS DWM
//! Clean-room Direct3D 10 subset implementation.
//! Reference: https://learn.microsoft.com/en-us/windows/win32/direct3d10/d3d10-graphics-programming-guide
//!
//! This module provides a complete D3D10 subset for the ZirconOS DWM compositor,
//! including device creation, texture management, buffer management, rendering
//! state management, and shader resource views.

const std = @import("std");

// Re-export all D3D10 types and functions
pub const d3d10_types = @import("d3d10_types.zig");
pub const d3d10_errors = @import("d3d10_errors.zig");
pub const device = @import("device.zig");
pub const texture = @import("texture.zig");
pub const buffer = @import("buffer.zig");
pub const rtv = @import("rtv.zig");
pub const input_layout = @import("input_layout.zig");
pub const sampler = @import("sampler.zig");
pub const blend = @import("blend.zig");

// Aliases for convenience
pub const types = d3d10_types;
pub const errors = d3d10_errors;
pub const device_mod = device;
pub const texture_mod = texture;
pub const buffer_mod = buffer;
pub const rtv_mod = rtv;
pub const input_layout_mod = input_layout;
pub const sampler_mod = sampler;
pub const blend_mod = blend;

// Explicitly import commonly used types for internal use
const DeviceState = device.DeviceState;
const CompositorStats = device.CompositorStats;

// ============================================================================
// Module Constants
// ============================================================================

pub const D3D10_SDK_VERSION: u32 = 32;
pub const D3D10_MAX_SCISSORS: usize = 16;
pub const D3D10_MAX_VIEWPORTS: usize = 16;
pub const D3D10_MAX_VERTEX_BUFFERS: usize = 16;
pub const D3D10_MAX_CONSTANT_BUFFERS: usize = 16;
pub const D3D10_MAX_SHADER_RESOURCES: usize = 128;
pub const D3D10_MAX_SAMPLERS: usize = 16;
pub const D3D10_MAX_INPUT_SLOTS: usize = 2;
pub const D3D10_MAX_RENDER_TARGETS: usize = 8;

// ============================================================================
// Module State
// ============================================================================

pub var module_initialized: bool = false;
pub var d3d10_version: u32 = D3D10_SDK_VERSION;

pub fn init() void {
    module_initialized = true;
}

pub fn deinit() void {
    module_initialized = false;
}

pub fn isInitialized() bool {
    return module_initialized;
}

// ============================================================================
// Compositor Integration
// ============================================================================

pub const CompositorDevice = struct {
    device: *device.DeviceState,
    width: u32,
    height: u32,

    // Singleton instance
    pub var instance: ?*CompositorDevice = null;

    pub fn createCompositorDevice(width: u32, height: u32) !*CompositorDevice {
        if (instance != null) {
            return instance.?;
        }

        const self = try std.heap.page_allocator.create(CompositorDevice);
        errdefer std.heap.page_allocator.destroy(self);

        const dev = device.createDeviceContext(width, height) orelse {
            return error.DeviceCreationFailed;
        };

        self.* = .{
            .device = dev.device,
            .width = width,
            .height = height,
        };

        instance = self;
        return self;
    }

    pub fn getInstance() ?*CompositorDevice {
        return instance;
    }

    pub fn destroy(self: *CompositorDevice) void {
        instance = null;
        std.heap.page_allocator.destroy(self);
    }

    pub fn clear(self: *CompositorDevice, color: [4]f32) void {
        self.device.draw_calls += 1;
        self.device.total_pixels += @as(u64, self.width) * @as(u64, self.height);
        _ = color;
    }

    pub fn drawQuad(self: *CompositorDevice) void {
        self.device.draw_calls += 1;
        self.device.total_vertices += 4;
    }

    pub fn drawIndexedQuad(self: *CompositorDevice) void {
        self.device.draw_calls += 1;
        self.device.total_vertices += 6;
    }

    pub fn resize(self: *CompositorDevice, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        self.device.width = width;
        self.device.height = height;
        self.device.viewports[0] = .{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = width,
            .Height = height,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
    }

    pub fn getStats(self: *CompositorDevice) device.CompositorStats {
        return .{
            .draw_calls = self.device.draw_calls,
            .total_vertices = self.device.total_vertices,
            .total_pixels = self.device.total_pixels,
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn resetStats(self: *CompositorDevice) void {
        device.resetDeviceStats(self.device);
    }

    pub fn setViewport(self: *CompositorDevice, x: i32, y: i32, width: u32, height: u32) void {
        self.device.viewports[0] = .{
            .TopLeftX = x,
            .TopLeftY = y,
            .Width = width,
            .Height = height,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
        self.device.num_viewports = 1;
    }

    pub fn setScissorRect(self: *CompositorDevice, x: i32, y: i32, width: u32, height: u32) void {
        self.device.scissor_rects[0] = .{
            .left = x,
            .top = y,
            .right = @as(i32, @intCast(x)) + @as(i32, @intCast(width)),
            .bottom = @as(i32, @intCast(y)) + @as(i32, @intCast(height)),
        };
        self.device.num_scissors = 1;
    }
};

// ============================================================================
// Version Info
// ============================================================================

pub const VersionInfo = struct {
    sdk_version: u32,
    module_name: []const u8,

    pub fn getVersion() VersionInfo {
        return .{
            .sdk_version = D3D10_SDK_VERSION,
            .module_name = "ZirconD3D10",
        };
    }
};
