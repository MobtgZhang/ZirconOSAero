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

//! DXGI Factory Implementation

const std = @import("std");
const types = @import("dxgi_types.zig");
const errors = @import("dxgi_errors.zig");
const adapter_mod = @import("adapter.zig");
const output_mod = @import("output.zig");

pub const Factory = struct {
    adapters: []*adapter_mod.Adapter,
    ref_count: u32 = 1,

    pub fn init() !*Factory {
        const self = try std.heap.page_allocator.create(Factory);
        errdefer std.heap.page_allocator.destroy(self);

        // Create default adapter
        self.adapters = try std.heap.page_allocator.alloc(*adapter_mod.Adapter, 1);
        self.adapters[0] = try adapter_mod.Adapter.initDefault();

        return self;
    }

    pub fn deinit(self: *Factory) void {
        for (self.adapters) |adapter| {
            adapter.release();
        }
        std.heap.page_allocator.free(self.adapters);
        std.heap.page_allocator.destroy(self);
    }

    pub fn addRef(self: *Factory) void {
        self.ref_count += 1;
    }

    pub fn release(self: *Factory) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.deinit();
        }
    }

    pub fn enumAdapters(self: *Factory, index: u32, adapter: **adapter_mod.Adapter) u32 {
        if (index >= self.adapters.len) return @intFromEnum(errors.DXGI_ERROR.DXGI_ERROR_NOT_FOUND);
        adapter.* = self.adapters[index];
        adapter.*.addRef();
        return 0; // S_OK
    }

    pub fn makeWindowAssociation(self: *Factory, window_handle: usize, flags: u32) u32 {
        _ = self;
        _ = window_handle;
        _ = flags;
        return 0; // S_OK
    }

    pub fn getWindowAssociation(self: *Factory, window_handle: *usize) u32 {
        _ = self;
        window_handle.* = 0;
        return 0; // S_OK
    }

    pub fn createSwapChainForHwnd(
        self: *Factory,
        device: *anyopaque,
        hwnd: usize,
        desc: *const types.DXGI_SWAP_CHAIN_DESC,
        restrict_to_output: ?*output_mod.Output,
        swap_chain: **anyopaque,
    ) u32 {
        _ = self;
        _ = device;
        _ = hwnd;
        _ = desc;
        _ = restrict_to_output;
        _ = swap_chain;
        return 0; // S_OK
    }
};

var g_factory: ?*Factory = null;

pub fn init() void {
    g_factory = Factory.init() catch unreachable;
    adapter_mod.init();
}

pub fn deinit() void {
    if (g_factory) |factory| {
        factory.release();
        g_factory = null;
    }
    adapter_mod.deinit();
}

pub fn getFactory() ?*Factory {
    return g_factory;
}
