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

//! DXGI Swap Chain Implementation

const std = @import("std");
const types = @import("dxgi_types.zig");
const errors = @import("dxgi_errors.zig");
const adapter = @import("adapter.zig");

pub const SwapChainState = struct {
    width: u32,
    height: u32,
    format: types.DXGI_FORMAT,
    buffer_count: u32,
    current_buffer: u32,
    buffers: []*types.DXGI_SURFACE,
    sample_desc: types.DXGI_SAMPLE_DESC,
    windowed: bool,
    vsync_enabled: bool,

    pub fn init(width: u32, height: u32, format: types.DXGI_FORMAT) !*SwapChainState {
        const self = try std.heap.page_allocator.create(SwapChainState);
        errdefer std.heap.page_allocator.destroy(self);

        const bpp = getBytesPerPixel(format);
        const stride = width * bpp;
        const buffer_size = stride * height;

        self.width = width;
        self.height = height;
        self.format = format;
        self.buffer_count = 2; // Double buffering by default
        self.current_buffer = 0;
        self.sample_desc = .{ .count = 1, .quality = 0 };
        self.windowed = true;
        self.vsync_enabled = true;

        // Allocate back buffers
        self.buffers = try std.heap.page_allocator.alloc(*types.DXGI_SURFACE, self.buffer_count);
        errdefer std.heap.page_allocator.free(self.buffers);

        for (0..self.buffer_count) |i| {
            const surface = try std.heap.page_allocator.create(types.DXGI_SURFACE);
            errdefer std.heap.page_allocator.destroy(surface);

            surface.desc = .{
                .width = width,
                .height = height,
                .format = format,
                .sample_desc = self.sample_desc,
            };
            surface.buffer = try std.heap.page_allocator.alloc(u8, buffer_size);
            surface.stride = stride;

            @memset(surface.buffer, 0);

            self.buffers[i] = surface;
        }

        return self;
    }

    pub fn destroy(self: *SwapChainState) void {
        for (self.buffers) |buffer| {
            buffer.release();
        }
        std.heap.page_allocator.free(self.buffers);
        std.heap.page_allocator.destroy(self);
    }

    pub fn present(self: *SwapChainState, sync_interval: u32) !void {
        // Swap buffers
        self.current_buffer = (self.current_buffer + 1) % self.buffer_count;

        // Simulate vsync wait if needed
        if (sync_interval > 0) {
            // TODO: Implement actual vsync synchronization
            std.time.sleep(16 * std.time.ns_per_ms); // ~60fps
        }
    }

    pub fn getBuffer(self: *SwapChainState, index: u32) !*types.DXGI_SURFACE {
        if (index >= self.buffer_count) return error.DXGI_ERROR_INVALID_INDEX;
        return self.buffers[index];
    }

    pub fn resizeBuffers(self: *SwapChainState, width: u32, height: u32) !void {
        // Destroy old buffers
        for (self.buffers) |buffer| {
            buffer.release();
        }
        std.heap.page_allocator.free(self.buffers);

        // Create new buffers
        const bpp = getBytesPerPixel(self.format);
        const stride = width * bpp;
        const buffer_size = stride * height;

        self.width = width;
        self.height = height;
        self.buffers = try std.heap.page_allocator.alloc(*types.DXGI_SURFACE, self.buffer_count);
        errdefer std.heap.page_allocator.free(self.buffers);

        for (0..self.buffer_count) |i| {
            const surface = try std.heap.page_allocator.create(types.DXGI_SURFACE);
            errdefer std.heap.page_allocator.destroy(surface);

            surface.desc = .{
                .width = width,
                .height = height,
                .format = self.format,
                .sample_desc = self.sample_desc,
            };
            surface.buffer = try std.heap.page_allocator.alloc(u8, buffer_size);
            surface.stride = stride;

            @memset(surface.buffer, 0);

            self.buffers[i] = surface;
        }

        self.current_buffer = 0;
    }
};

fn getBytesPerPixel(format: types.DXGI_FORMAT) u32 {
    return switch (format) {
        .DXGI_FORMAT_R8G8B8A8_UNORM, .DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, .DXGI_FORMAT_B8G8R8A8_UNORM, .DXGI_FORMAT_R32_UINT, .DXGI_FORMAT_R32_FLOAT => 4,
        .DXGI_FORMAT_R16G16_UNORM, .DXGI_FORMAT_R16G16_FLOAT => 4,
        .DXGI_FORMAT_R8G8_UNORM => 2,
        .DXGI_FORMAT_R16_UNORM, .DXGI_FORMAT_R16_FLOAT => 2,
        .DXGI_FORMAT_R8_UNORM => 1,
        else => 4, // Default to 4 bytes per pixel for unknown formats
    };
}

pub fn createSwapChain(width: u32, height: u32, format: types.DXGI_FORMAT) !*SwapChainState {
    return SwapChainState.init(width, height, format);
}
