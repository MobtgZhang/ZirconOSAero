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

//! DXGI Module Entry Point for ZirconOS DWM
//! Clean-room DXGI subset implementation for DWM compositor.
//! Reference: https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/dxgi-graphics-programming-guide

const std = @import("std");

// Re-export all DXGI types and functions
pub const dxgi_types = @import("dxgi_types.zig");
pub const dxgi_errors = @import("dxgi_errors.zig");
pub const adapter = @import("adapter.zig");
pub const swap_chain = @import("swap_chain.zig");
pub const output = @import("output.zig");
pub const factory = @import("factory.zig");

// Aliases for convenience
pub const types = dxgi_types;
pub const errors = dxgi_errors;
pub const adapter_mod = adapter;
pub const swap_chain_mod = swap_chain;
pub const output_mod = output;
pub const factory_mod = factory;

// ============================================================================
// Module Constants
// ============================================================================

pub const DXGI_SDK_VERSION: u32 = 32;
pub const DXGI_MAX_SWAP_CHAIN_BUFFERS: usize = 4;
pub const DXGI_MAX_ADAPTERS: usize = 8;
pub const DXGI_MAX_OUTPUTS: usize = 16;

// ============================================================================
// Module State
// ============================================================================

pub var module_initialized: bool = false;
pub var dxgi_version: u32 = DXGI_SDK_VERSION;

pub fn init() void {
    module_initialized = true;
    factory.init();
}

pub fn deinit() void {
    factory.deinit();
    module_initialized = false;
}

pub fn isInitialized() bool {
    return module_initialized;
}

// ============================================================================
// DWM Integration
// ============================================================================

pub const DwmSwapChain = struct {
    swap_chain: *swap_chain.SwapChainState,
    width: u32,
    height: u32,
    format: dxgi_types.DXGI_FORMAT,

    pub fn create(width: u32, height: u32, format: dxgi_types.DXGI_FORMAT) !*DwmSwapChain {
        const self = try std.heap.page_allocator.create(DwmSwapChain);
        errdefer std.heap.page_allocator.destroy(self);

        const sc = try swap_chain.createSwapChain(width, height, format);
        errdefer sc.destroy();

        self.* = .{
            .swap_chain = sc,
            .width = width,
            .height = height,
            .format = format,
        };

        return self;
    }

    pub fn destroy(self: *DwmSwapChain) void {
        self.swap_chain.destroy();
        std.heap.page_allocator.destroy(self);
    }

    pub fn present(self: *DwmSwapChain, sync_interval: u32) !void {
        try self.swap_chain.present(sync_interval);
    }

    pub fn getBuffer(self: *DwmSwapChain, index: u32) !*dxgi_types.DXGI_SURFACE {
        return self.swap_chain.getBuffer(index);
    }

    pub fn resize(self: *DwmSwapChain, width: u32, height: u32) !void {
        try self.swap_chain.resizeBuffers(width, height);
        self.width = width;
        self.height = height;
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
            .sdk_version = DXGI_SDK_VERSION,
            .module_name = "ZirconDXGI",
        };
    }
};
