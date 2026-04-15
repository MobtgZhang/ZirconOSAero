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

//! D3D10 Device Implementation for ZirconOS DWM
//! Clean-room implementation of ID3D10Device interface.
//! This module provides the core D3D10 device functionality for ZirconOS DWM compositor.

const std = @import("std");
pub const d3d10_types = @import("d3d10_types.zig");
pub const d3d10_errors = @import("d3d10_errors.zig");
const texture = @import("texture.zig");
const buffer = @import("buffer.zig");
const rtv = @import("rtv.zig");
const blend = @import("blend.zig");
const sampler = @import("sampler.zig");
const input_layout = @import("input_layout.zig");

// ============================================================================
// IUnknown Interface
// ============================================================================

pub const IUnknown = extern struct {
    QueryInterface: fn (*const IUnknown, *const [16]u8, *?*anyopaque) callconv(.C) d3d10_types.HRESULT,
    AddRef: fn (*const IUnknown) callconv(.C) u32,
    Release: fn (*const IUnknown) callconv(.C) u32,
};

// ============================================================================
// ID3D10DeviceChild Interface
// ============================================================================

pub const ID3D10DeviceChild = extern struct {
    base: IUnknown,
    GetDevice: fn (*const ID3D10DeviceChild) callconv(.C) *ID3D10Device,
    GetPrivateData: fn (*const ID3D10DeviceChild, *const [16]u8, *u32, *anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateData: fn (*const ID3D10DeviceChild, *const [16]u8, u32, *const anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateDataInterface: fn (*const ID3D10DeviceChild, *const [16]u8, ?*const IUnknown) callconv(.C) d3d10_types.HRESULT,
};

// ============================================================================
// ID3D10Device Interface
// ============================================================================

pub const ID3D10Device = extern struct {
    base: ID3D10DeviceChild,

    // Shader State
    VSSetShader: fn (*const ID3D10Device, ?*const anyopaque) callconv(.C) void,
    VSSetShaderResources: fn (*const ID3D10Device, u32, u32, [*]?*const anyopaque) callconv(.C) void,
    VSSetSamplers: fn (*const ID3D10Device, u32, u32, [*]?*const anyopaque) callconv(.C) void,
    VSSetConstantBuffers: fn (*const ID3D10Device, u32, u32, [*]?*const anyopaque) callconv(.C) void,

    PSSetShader: fn (*const ID3D10Device, ?*const anyopaque) callconv(.C) void,
    PSSetShaderResources: fn (*const ID3D10Device, u32, u32, [*]?*const anyopaque) callconv(.C) void,
    PSSetSamplers: fn (*const ID3D10Device, u32, u32, [*]?*const anyopaque) callconv(.C) void,
    PSSetConstantBuffers: fn (*const ID3D10Device, u32, u32, [*]?*const anyopaque) callconv(.C) void,

    // Output Merger
    OMSetRenderTargets: fn (*const ID3D10Device, u32, [*]?*const anyopaque, ?*const anyopaque) callconv(.C) void,
    OMSetDepthStencilState: fn (*const ID3D10Device, ?*const anyopaque, u32) callconv(.C) void,
    OMSetBlendState: fn (*const ID3D10Device, ?*const anyopaque, [*]f32, u32) callconv(.C) void,

    // Rasterizer
    RSSetState: fn (*const ID3D10Device, ?*const anyopaque) callconv(.C) void,
    RSSetViewports: fn (*const ID3D10Device, u32, [*]const d3d10_types.D3D10_VIEWPORT) callconv(.C) void,
    RSSetScissorRects: fn (*const ID3D10Device, u32, [*]const d3d10_types.D3D10_RECT) callconv(.C) void,

    // Copying Resources
    CopySubresourceRegion: fn (*const ID3D10Device, *const anyopaque, u32, u32, u32, u32, *const anyopaque, u32, [*]const d3d10_types.D3D10_BOX) callconv(.C) void,
    CopyResource: fn (*const ID3D10Device, *const anyopaque, *const anyopaque) callconv(.C) void,
    UpdateSubresource: fn (*const ID3D10Device, *const anyopaque, u32, [*]const d3d10_types.D3D10_BOX, *const anyopaque, u32, u32) callconv(.C) void,

    // Clearing
    ClearRenderTargetView: fn (*const ID3D10Device, *const anyopaque, [*]const f32) callconv(.C) void,
    ClearDepthStencilView: fn (*const ID3D10Device, *const anyopaque, u32, f32, u8) callconv(.C) void,
    ClearState: fn (*const ID3D10Device) callconv(.C) void,

    // Generate Mips
    GenerateMips: fn (*const ID3D10Device, *const anyopaque) callconv(.C) void,
    ResolveSubresource: fn (*const ID3D10Device, *const anyopaque, u32, *const anyopaque, u32, d3d10_types.DXGI_FORMAT) callconv(.C) void,

    // Drawing
    Draw: fn (*const ID3D10Device, u32, u32) callconv(.C) void,
    DrawIndexed: fn (*const ID3D10Device, u32, u32, i32) callconv(.C) void,
    DrawInstanced: fn (*const ID3D10Device, u32, u32, u32, i32) callconv(.C) void,
    DrawIndexedInstanced: fn (*const ID3D10Device, u32, u32, u32, i32, u32) callconv(.C) void,

    // RDTSC for accurate profiling
    RDTSC: fn () callconv(.C) u64,

    // Video Processing
    VideoProcessFrame: fn (*const ID3D10Device, *const anyopaque, f32, u32, *const anyopaque, [*]const d3d10_types.D3D10_VIDEO_FRAME_FORMAT, [*]const d3d10_types.D3D10_VIDEO_PROCESSOR_CAPS, [*]const d3d10_types.D3D10_VIDEO_PROCESSOR_FILTER_CAPS, d3d10_types.BOOL, i32, [*]const i32, [*]const d3d10_types.D3D10_VIDEO_COLOR, [*]const d3d10_types.D3D10_VIDEO_PROCESSOR_STREAM) callconv(.C) d3d10_types.HRESULT,
    VideoProcessBeginFrame: fn (*const ID3D10Device, *const anyopaque, *const anyopaque) callconv(.C) d3d10_types.HRESULT,
    VideoProcessEndFrame: fn (*const ID3D10Device, [*]const anyopaque) callconv(.C) d3d10_types.HRESULT,
    VideoSetTargetColorSpace: fn (*const ID3D10Device, d3d10_types.D3D10_VIDEO_COLOR_SPACE_TYPE) callconv(.C) void,
    VideoSetTargetRect: fn (*const ID3D10Device, *const anyopaque, [*]const d3d10_types.RECT) callconv(.C) void,
    VideoSetStreamColorSpace: fn (*const ID3D10Device, u32, [*]const d3d10_types.D3D10_VIDEO_COLOR) callconv(.C) void,
    VideoSetStreamPixelAspectRatio: fn (*const ID3D10Device, u32, [*]const d3d10_types.DXGI_RATIONAL) callconv(.C) void,
    VideoSetStreamOutputRate: fn (*const ID3D10Device, u32, [*]const d3d10_types.DXGI_RATIONAL, u32, [*]const d3d10_types.DXGI_RATIONAL) callconv(.C) void,
    VideoSetStreamPalette: fn (*const ID3D10Device, u32, u32, [*]const u32) callconv(.C) void,
    VideoSetStreamAlphaFillMode: fn (*const ID3D10Device, u32, d3d10_types.D3D10_VIDEO_PROCESSOR_ALPHA_FILL_MODE, u32) callconv(.C) void,
    VideoSetStreamAutoProcessingMode: fn (*const ID3D10Device, u32, d3d10_types.BOOL) callconv(.C) void,
    VideoSetStreamFilter: fn (*const ID3D10Device, u32, d3d10_types.BOOL, f32, f32, f32, f32, f32, f32) callconv(.C) void,
    VideoGetStreamCurrentPixelDomain: fn (*const ID3D10Device, u32, *const u32) callconv(.C) void,
};

// ============================================================================
// Internal Zircon D3D10 Device State
// ============================================================================

pub const DeviceState = struct {
    ref_count: u32,
    driver_type: D3D10_DRIVER_TYPE,
    flags: D3D10_CREATE_DEVICE_FLAG,
    width: u32,
    height: u32,
    // Render targets
    render_targets: [8]?*anyopaque,
    depth_stencil: ?*anyopaque,
    current_rtv_count: u32,
    current_dsv: ?*anyopaque,
    // Shader state
    vertex_shader: ?*anyopaque,
    pixel_shader: ?*anyopaque,
    vertex_buffers: [16]?*anyopaque,
    vertex_strides: [16]u32,
    vertex_offset: [16]u32,
    index_buffer: ?*anyopaque,
    index_format: d3d10_types.DXGI_FORMAT,
    index_offset: u32,
    constant_buffers_vs: [16]?*anyopaque,
    constant_buffers_ps: [16]?*anyopaque,
    shader_resources_vs: [16]?*anyopaque,
    shader_resources_ps: [16]?*anyopaque,
    samplers_vs: [16]?*anyopaque,
    samplers_ps: [16]?*anyopaque,
    // Rasterizer state
    rasterizer_state: ?*anyopaque,
    // Blend state
    blend_state: ?*anyopaque,
    blend_factor: [4]f32,
    sample_mask: u32,
    // Depth stencil state
    depth_stencil_state: ?*anyopaque,
    stencil_ref: u32,
    // Viewport
    viewports: [16]d3d10_types.D3D10_VIEWPORT,
    num_viewports: u32,
    // Scissor rects
    scissor_rects: [16]d3d10_types.D3D10_RECT,
    num_scissors: u32,
    // Statistics
    draw_calls: u64,
    total_vertices: u64,
    total_pixels: u64,
};

pub const MAX_DEVICES: usize = 8;
pub var g_device_pool: [MAX_DEVICES]?DeviceState = [_]?DeviceState{null} ** MAX_DEVICES;
pub var g_device_count: usize = 0;

// ============================================================================
// Device Context (for immediate context operations)
// ============================================================================

pub const CompositorStats = struct {
    draw_calls: u64,
    total_vertices: u64,
    total_pixels: u64,
    width: u32,
    height: u32,
};

pub const DeviceContext = struct {
    device: *DeviceState,
    immediate_context: bool,

    pub fn clearRenderTarget(ctx: *DeviceContext, view: *anyopaque, color: [4]f32) void {
        _ = view;
        ctx.device.draw_calls += 1;
        ctx.device.total_pixels += @as(u64, ctx.device.width) * @as(u64, ctx.device.height);
        _ = color;
    }

    pub fn draw(ctx: *DeviceContext, vertex_count: u32, start_vertex_location: u32) void {
        _ = start_vertex_location;
        ctx.device.draw_calls += 1;
        ctx.device.total_vertices += vertex_count;
    }

    pub fn drawIndexed(ctx: *DeviceContext, index_count: u32, start_index_location: i32, base_vertex_location: i32) void {
        _ = start_index_location;
        _ = base_vertex_location;
        ctx.device.draw_calls += 1;
        ctx.device.total_vertices += index_count;
    }

    pub fn setRenderTargets(ctx: *DeviceContext, rtv_count: u32, rtvs: [*]?*anyopaque, dsv: ?*anyopaque) void {
        ctx.device.current_rtv_count = rtv_count;
        for (0..@min(rtv_count, 8)) |i| {
            ctx.device.render_targets[i] = rtvs[i];
        }
        ctx.device.current_dsv = dsv;
    }

    pub fn setViewport(ctx: *DeviceContext, vp: d3d10_types.D3D10_VIEWPORT) void {
        ctx.device.viewports[0] = vp;
        ctx.device.num_viewports = 1;
    }
};

// ============================================================================
// D3D10CreateDevice
// ============================================================================

pub const D3D10_DRIVER_TYPE = enum(u32) {
    null = 0,
    reference = 1,
    software = 2,
    warp = 3,
    hardware = 4,
};

pub const D3D10_CREATE_DEVICE_FLAG = u32;

pub const D3D10_CREATE_DEVICE_SINGLETHREADED: D3D10_CREATE_DEVICE_FLAG = 0x01;
pub const D3D10_CREATE_DEVICE_DEBUG: D3D10_CREATE_DEVICE_FLAG = 0x02;
pub const D3D10_CREATE_DEVICE_SWITCH_REF: D3D10_CREATE_DEVICE_FLAG = 0x04;
pub const D3D10_CREATE_DEVICE_PREVENT_INTERNAL_THREADING_OPTIMIZATIONS: D3D10_CREATE_DEVICE_FLAG = 0x08;
pub const D3D10_CREATE_DEVICE_BGRA_SUPPORT: D3D10_CREATE_DEVICE_FLAG = 0x20;
pub const D3D10_CREATE_DEVICE_STRIPE_BORDER: D3D10_CREATE_DEVICE_FLAG = 0x40;
pub const D3D10_CREATE_DEVICE_INTERNAL_DEBUG: D3D10_CREATE_DEVICE_FLAG = 0x100;

pub fn D3D10CreateDevice(
    pAdapter: ?*anyopaque,
    DriverType: D3D10_DRIVER_TYPE,
    Software: ?*anyopaque,
    Flags: D3D10_CREATE_DEVICE_FLAG,
    HardwareLevel: u32,
    ppDevice: *?*anyopaque,
) d3d10_types.HRESULT {
    _ = pAdapter;
    _ = Software;
    _ = HardwareLevel;

    if (g_device_count >= MAX_DEVICES) {
        return d3d10_errors.E_OUTOFMEMORY;
    }

    const idx = g_device_count;
    g_device_count += 1;

    g_device_pool[idx] = .{
        .ref_count = 1,
        .driver_type = DriverType,
        .flags = Flags,
        .width = 1920,
        .height = 1080,
        .render_targets = .{ null, null, null, null, null, null, null, null },
        .depth_stencil = null,
        .current_rtv_count = 0,
        .current_dsv = null,
        .vertex_shader = null,
        .pixel_shader = null,
        .vertex_buffers = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .vertex_strides = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .vertex_offset = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .index_buffer = null,
        .index_format = .unknown,
        .index_offset = 0,
        .constant_buffers_vs = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .constant_buffers_ps = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .shader_resources_vs = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .shader_resources_ps = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .samplers_vs = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .samplers_ps = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .rasterizer_state = null,
        .blend_state = null,
        .blend_factor = .{ 1.0, 1.0, 1.0, 1.0 },
        .sample_mask = 0xFFFFFFFF,
        .depth_stencil_state = null,
        .stencil_ref = 0,
        .viewports = undefined,
        .num_viewports = 0,
        .scissor_rects = undefined,
        .num_scissors = 0,
        .draw_calls = 0,
        .total_vertices = 0,
        .total_pixels = 0,
    };

    ppDevice.* = @ptrFromInt(@intFromPtr(&g_device_pool[idx]));
    return d3d10_errors.D3D_OK;
}

pub fn D3D10CreateDeviceAndSwapChain(
    pAdapter: ?*anyopaque,
    DriverType: D3D10_DRIVER_TYPE,
    Software: ?*anyopaque,
    Flags: D3D10_CREATE_DEVICE_FLAG,
    HardwareLevel: u32,
    pSwapChainDesc: [*]const d3d10_types.DXGI_SWAP_CHAIN_DESC,
    ppSwapChain: *?*anyopaque,
    ppDevice: *?*anyopaque,
) d3d10_types.HRESULT {
    const hr = D3D10CreateDevice(pAdapter, DriverType, Software, Flags, HardwareLevel, ppDevice);
    if (d3d10_errors.FAILED(hr)) {
        return hr;
    }

    if (ppSwapChain.*) |_| {
        const device_ptr = ppDevice.*;
        _ = device_ptr;
    }

    _ = pSwapChainDesc;
    return d3d10_errors.S_OK;
}

// ============================================================================
// Device Methods (ZirconOS Extension)
// ============================================================================

pub fn createDeviceContext(width: u32, height: u32) ?*DeviceContext {
    if (g_device_count >= MAX_DEVICES) return null;

    const idx = g_device_count;
    g_device_count += 1;

    g_device_pool[idx] = .{
        .ref_count = 1,
        .driver_type = .hardware,
        .flags = D3D10_CREATE_DEVICE_BGRA_SUPPORT,
        .width = width,
        .height = height,
        .render_targets = .{ null, null, null, null, null, null, null, null },
        .depth_stencil = null,
        .current_rtv_count = 0,
        .current_dsv = null,
        .vertex_shader = null,
        .pixel_shader = null,
        .vertex_buffers = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .vertex_strides = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .vertex_offset = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .index_buffer = null,
        .index_format = .unknown,
        .index_offset = 0,
        .constant_buffers_vs = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .constant_buffers_ps = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .shader_resources_vs = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .shader_resources_ps = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .samplers_vs = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .samplers_ps = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
        .rasterizer_state = null,
        .blend_state = null,
        .blend_factor = .{ 1.0, 1.0, 1.0, 1.0 },
        .sample_mask = 0xFFFFFFFF,
        .depth_stencil_state = null,
        .stencil_ref = 0,
        .viewports = [16]d3d10_types.D3D10_VIEWPORT{
            .{
                .TopLeftX = 0,
                .TopLeftY = 0,
                .Width = width,
                .Height = height,
                .MinDepth = 0.0,
                .MaxDepth = 1.0,
            },
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
            d3d10_types.D3D10_VIEWPORT.zero(),
        },
        .num_viewports = 1,
        .scissor_rects = undefined,
        .num_scissors = 0,
        .draw_calls = 0,
        .total_vertices = 0,
        .total_pixels = 0,
    };

    const dev = &g_device_pool[idx].?;
    return @ptrFromInt(@intFromPtr(dev));
}

pub fn getDeviceStats(dev: *DeviceState) struct {
    draw_calls: u64,
    total_vertices: u64,
    total_pixels: u64,
} {
    return .{
        .draw_calls = dev.draw_calls,
        .total_vertices = dev.total_vertices,
        .total_pixels = dev.total_pixels,
    };
}

pub fn resetDeviceStats(dev: *DeviceState) void {
    dev.draw_calls = 0;
    dev.total_vertices = 0;
    dev.total_pixels = 0;
}

pub fn setDeviceViewport(dev: *DeviceState, width: u32, height: u32) void {
    dev.width = width;
    dev.height = height;
    dev.viewports[0] = .{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = width,
        .Height = height,
        .MinDepth = 0.0,
        .MaxDepth = 1.0,
    };
    dev.num_viewports = 1;
}

// ============================================================================
// ZirconOS DWM Specific Extensions
// ============================================================================

pub const ZirconD3D10Device = struct {
    device: *DeviceState,
    width: u32,
    height: u32,

    pub fn create(width: u32, height: u32) !*ZirconD3D10Device {
        const self = try std.heap.page_allocator.create(ZirconD3D10Device);
        self.* = .{
            .device = @ptrFromInt(@intFromPtr(&g_device_pool[0].?)),
            .width = width,
            .height = height,
        };

        if (g_device_count >= MAX_DEVICES) {
            return error.OutOfMemory;
        }

        const idx = g_device_count;
        g_device_count += 1;

        g_device_pool[idx] = .{
            .ref_count = 1,
            .driver_type = .hardware,
            .flags = D3D10_CREATE_DEVICE_BGRA_SUPPORT,
            .width = width,
            .height = height,
            .render_targets = .{ null, null, null, null, null, null, null, null },
            .depth_stencil = null,
            .current_rtv_count = 0,
            .current_dsv = null,
            .vertex_shader = null,
            .pixel_shader = null,
            .vertex_buffers = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
            .vertex_strides = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .vertex_offset = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .index_buffer = null,
            .index_format = .unknown,
            .index_offset = 0,
            .constant_buffers_vs = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
            .constant_buffers_ps = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
            .shader_resources_vs = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
            .shader_resources_ps = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
            .samplers_vs = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
            .samplers_ps = .{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null },
            .rasterizer_state = null,
            .blend_state = null,
            .blend_factor = .{ 1.0, 1.0, 1.0, 1.0 },
            .sample_mask = 0xFFFFFFFF,
            .depth_stencil_state = null,
            .stencil_ref = 0,
            .viewports = .{
                .{
                    .TopLeftX = 0,
                    .TopLeftY = 0,
                    .Width = width,
                    .Height = height,
                    .MinDepth = 0.0,
                    .MaxDepth = 1.0,
                },
            },
            .num_viewports = 1,
            .scissor_rects = undefined,
            .num_scissors = 0,
            .draw_calls = 0,
            .total_vertices = 0,
            .total_pixels = 0,
        };

        self.device = @ptrFromInt(@intFromPtr(&g_device_pool[idx].?));
        return self;
    }

    pub fn destroy(self: *ZirconD3D10Device) void {
        std.heap.page_allocator.destroy(self);
    }

    pub fn clearRenderTarget(self: *ZirconD3D10Device, color: [4]f32) void {
        _ = color;
        self.device.draw_calls += 1;
        self.device.total_pixels += @as(u64, self.device.width) * @as(u64, self.device.height);
    }

    pub fn drawQuad(self: *ZirconD3D10Device) void {
        self.device.draw_calls += 1;
        self.device.total_vertices += 4;
    }

    pub fn drawIndexedQuad(self: *ZirconD3D10Device) void {
        self.device.draw_calls += 1;
        self.device.total_vertices += 4;
    }

    pub fn getStats(self: *ZirconD3D10Device) struct {
        draw_calls: u64,
        total_vertices: u64,
        total_pixels: u64,
    } {
        return .{
            .draw_calls = self.device.draw_calls,
            .total_vertices = self.device.total_vertices,
            .total_pixels = self.device.total_pixels,
        };
    }

    pub fn setViewport(self: *ZirconD3D10Device, width: u32, height: u32) void {
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
        self.device.num_viewports = 1;
    }
};
