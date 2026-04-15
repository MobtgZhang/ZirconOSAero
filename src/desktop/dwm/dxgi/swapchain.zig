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

//! DXGI SwapChain Implementation for ZirconOS DWM
//! Clean-room implementation of IDXGISwapChain interface.
//! Core interface for presenting rendered frames to the display.

const std = @import("std");
const dxgi_errors = @import("dxgi_errors.zig");
const dxgi_types = @import("dxgi_types.zig");
const d3d10_types = @import("../d3d10/d3d10_types.zig");

// ============================================================================
// IDXGISwapChain Interface
// ============================================================================

pub const IDXGISwapChain = extern struct {
    base: dxgi_types.IDXGIDeviceSubObject,

    // Present the rendered frame
    Present: fn (*const IDXGISwapChain, u32, u32) callconv(.C) d3d10_types.HRESULT,

    // Get the buffer surface
    GetBuffer: fn (*const IDXGISwapChain, u32, *const dxgi_types.GUID, *?*anyopaque) callconv(.C) d3d10_types.HRESULT,

    // Set fullscreen state
    SetFullscreenState: fn (*const IDXGISwapChain, dxgi_types.BOOL, ?*dxgi_types.IDXGIOutput) callconv(.C) d3d10_types.HRESULT,
    GetFullscreenState: fn (*const IDXGISwapChain, [*]dxgi_types.BOOL, [*]?*dxgi_types.IDXGIOutput) callconv(.C) d3d10_types.HRESULT,

    // Get the description
    GetDesc: fn (*const IDXGISwapChain, [*]dxgi_types.DXGI_SWAP_CHAIN_DESC) callconv(.C) void,

    // Resize buffers
    ResizeBuffers: fn (*const IDXGISwapChain, u32, u32, u32, d3d10_types.DXGI_FORMAT, u32) callconv(.C) d3d10_types.HRESULT,
    ResizeTarget: fn (*const IDXGISwapChain, [*]const dxgi_types.DXGI_MODE_DESC) callconv(.C) d3d10_types.HRESULT,

    // Get containing output
    GetContainingOutput: fn (*const IDXGISwapChain, [*]?*dxgi_types.IDXGIOutput) callconv(.C) d3d10_types.HRESULT,

    // Frame statistics
    GetFrameStatistics: fn (*const IDXGISwapChain, [*]dxgi_types.DXGI_FRAME_STATISTICS) callconv(.C) d3d10_types.HRESULT,
    GetLastPresentCount: fn (*const IDXGISwapChain, [*]u32) callconv(.C) d3d10_types.HRESULT,
};

// ============================================================================
// SwapChain State
// ============================================================================

pub const SwapChainState = struct {
    ref_count: u32,
    desc: d3d10_types.DXGI_SWAP_CHAIN_DESC,
    buffers: [3]?*anyopaque,
    current_buffer: u32,
    is_fullscreen: bool,
    frame_count: u64,
    last_present_time: u64,
    vsync_enabled: bool,
};

pub const MAX_SWAPCHAINS: usize = 16;
pub var g_swapchain_pool: [MAX_SWAPCHAINS]?SwapChainState = [_]?SwapChainState{null} ** MAX_SWAPCHAINS;
pub var g_swapchain_count: usize = 0;

// ============================================================================
// SwapChain Creation
// ============================================================================

pub fn createSwapChain(
    device: *anyopaque,
    desc: [*]const d3d10_types.DXGI_SWAP_CHAIN_DESC,
    ppSwapChain: *?*IDXGISwapChain,
) d3d10_types.HRESULT {
    _ = device;

    if (g_swapchain_count >= MAX_SWAPCHAINS) {
        return dxgi_errors.E_OUTOFMEMORY;
    }

    const swap_desc = desc[0];

    g_swapchain_pool[g_swapchain_count] = .{
        .ref_count = 1,
        .desc = swap_desc,
        .buffers = .{ null, null, null },
        .current_buffer = 0,
        .is_fullscreen = swap_desc.Windowed == 0,
        .frame_count = 0,
        .last_present_time = 0,
        .vsync_enabled = swap_desc.SwapEffect == .sequential or swap_desc.SwapEffect == .flip_sequential,
    };

    g_swapchain_count += 1;
    _ = ppSwapChain;
    return dxgi_errors.S_OK;
}

pub fn getSwapChainDesc(idx: usize) ?d3d10_types.DXGI_SWAP_CHAIN_DESC {
    if (idx < g_swapchain_count and g_swapchain_pool[idx] != null) {
        return g_swapchain_pool[idx].?.desc;
    }
    return null;
}

pub fn getCurrentBuffer(idx: usize) ?*anyopaque {
    if (idx < g_swapchain_count and g_swapchain_pool[idx] != null) {
        const sc = g_swapchain_pool[idx].?;
        const buffer_idx = sc.current_buffer % 3;
        return sc.buffers[buffer_idx];
    }
    return null;
}

pub fn setBuffer(idx: usize, buffer_idx: u32, buffer: *anyopaque) void {
    if (idx < g_swapchain_count and g_swapchain_pool[idx] != null) {
        if (buffer_idx < 3) {
            g_swapchain_pool[idx].?.buffers[buffer_idx] = buffer;
        }
    }
}

// ============================================================================
// Present Implementation
// ============================================================================

pub fn present(
    idx: usize,
    sync_interval: u32,
    flags: u32,
) d3d10_types.HRESULT {
    if (idx >= g_swapchain_count or g_swapchain_pool[idx] == null) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    const sc = &g_swapchain_pool[idx].?;

    // Increment frame count
    sc.frame_count += 1;
    sc.last_present_time = std.time.milliTimestamp();

    // Handle sync interval (VSync)
    if (sync_interval > 0 and sc.vsync_enabled) {
        // Wait for VSync (simplified - real implementation would sleep)
        // The actual vsync would be handled by the display driver
    }

    // Handle flags
    if ((flags & 0x2) != 0) {
        // DXGI_PRESENT_RESTRICT_TO_OUTPUT - not implemented
    }
    if ((flags & 0x4) != 0) {
        // DXGI_PRESENT_RESTART - not implemented
    }
    if ((flags & 0x8) != 0) {
        // DXGI_PRESENT_DO_NOT_SEQUENCE - not implemented
    }

    return dxgi_errors.S_OK;
}

pub fn resizeBuffers(
    idx: usize,
    buffer_count: u32,
    width: u32,
    height: u32,
    new_format: d3d10_types.DXGI_FORMAT,
    swap_chain_flags: u32,
) d3d10_types.HRESULT {
    if (idx >= g_swapchain_count or g_swapchain_pool[idx] == null) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    if (buffer_count == 0 or buffer_count > 3) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    const sc = &g_swapchain_pool[idx].?;

    sc.desc.BufferDesc.Width = width;
    sc.desc.BufferDesc.Height = height;
    sc.desc.BufferDesc.Format = new_format;
    sc.desc.BufferCount = buffer_count;
    sc.desc.Flags = swap_chain_flags;

    // Reset all buffers to null (they'll be recreated)
    sc.buffers[0] = null;
    sc.buffers[1] = null;
    sc.buffers[2] = null;
    sc.current_buffer = 0;

    return dxgi_errors.S_OK;
}

pub fn resizeTarget(
    idx: usize,
    new_mode: [*]const dxgi_types.DXGI_MODE_DESC,
) d3d10_types.HRESULT {
    if (idx >= g_swapchain_count or g_swapchain_pool[idx] == null) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    const mode = new_mode[0];
    const sc = &g_swapchain_pool[idx].?;

    sc.desc.BufferDesc.Width = mode.Width;
    sc.desc.BufferDesc.Height = mode.Height;
    sc.desc.BufferDesc.RefreshRate = mode.RefreshRate;
    sc.desc.BufferDesc.Format = mode.Format;
    sc.desc.BufferDesc.ScanlineOrdering = mode.ScanlineOrdering;
    sc.desc.BufferDesc.Scaling = mode.Scaling;

    return dxgi_errors.S_OK;
}

pub fn setFullscreenState(
    idx: usize,
    fullscreen: dxgi_types.BOOL,
    target: ?*dxgi_types.IDXGIOutput,
) d3d10_types.HRESULT {
    if (idx >= g_swapchain_count or g_swapchain_pool[idx] == null) {
        return dxgi_errors.DXGI_ERROR_INVALID_CALL;
    }

    const sc = &g_swapchain_pool[idx].?;
    sc.is_fullscreen = (fullscreen != 0);
    _ = target;

    return dxgi_errors.S_OK;
}

pub fn getFullscreenState(idx: usize) struct { fullscreen: bool, target: ?*dxgi_types.IDXGIOutput } {
    if (idx < g_swapchain_count and g_swapchain_pool[idx] != null) {
        const sc = g_swapchain_pool[idx].?;
        return .{ .fullscreen = sc.is_fullscreen, .target = null };
    }
    return .{ .fullscreen = false, .target = null };
}

pub fn getFrameCount(idx: usize) u64 {
    if (idx < g_swapchain_count and g_swapchain_pool[idx] != null) {
        return g_swapchain_pool[idx].?.frame_count;
    }
    return 0;
}

pub fn releaseSwapChain(idx: usize) void {
    if (idx < g_swapchain_count and g_swapchain_pool[idx] != null) {
        const sc = &g_swapchain_pool[idx].?;
        sc.ref_count -= 1;
        if (sc.ref_count == 0) {
            g_swapchain_pool[idx] = null;
        }
    }
}
