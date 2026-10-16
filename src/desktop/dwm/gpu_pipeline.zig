// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// GPU Rendering Pipeline - D3D10 渲染管线
// 提供完整的 GPU 加速渲染能力

const std = @import("std");
const texture = @import("d3d10/texture.zig");
const d3d10 = @import("d3d10/d3d10.zig");
const dxgi = @import("dxgi/dxgi.zig");
const d3d10_types = @import("d3d10/d3d10_types.zig");
const d3d10_errors = @import("d3d10/d3d10_errors.zig");

// ============================================================================
// 顶点格式
// ============================================================================

pub const Vertex2D = extern struct {
    position: [2]f32,
    texcoord: [2]f32,
    color: [4]f32,
};

pub const VertexPos = extern struct {
    position: [3]f32,
};

pub const VertexPosTex = extern struct {
    position: [3]f32,
    texcoord: [2]f32,
};

// ============================================================================
// 渲染管线状态
// ============================================================================

pub const BlendMode = enum(u8) {
    Opaque = 0,
    Alpha = 1,
    Additive = 2,
    Multiply = 3,
};

pub const SamplerMode = enum(u8) {
    Linear = 0,
    Point = 1,
    Anisotropic = 2,
};

pub const PipelineState = struct {
    blend_mode: BlendMode,
    sampler_mode: SamplerMode,
    depth_enabled: bool,
    scissor_enabled: bool,
};

pub const DEFAULT_BLEND_STATE: PipelineState = .{
    .blend_mode = .Alpha,
    .sampler_mode = .Linear,
    .depth_enabled = false,
    .scissor_enabled = false,
};

fn blendPixel(target: []u8, offset: usize, color: [4]f32) void {
    const src_a = std.math.clamp(color[3], 0.0, 1.0);
    const inv_a = 1.0 - src_a;
    const dst_a = @as(f32, @floatFromInt(target[offset + 3])) / 255.0;
    const out_a = src_a + dst_a * inv_a;

    if (out_a <= 0.0) {
        target[offset] = 0;
        target[offset + 1] = 0;
        target[offset + 2] = 0;
        target[offset + 3] = 0;
        return;
    }

    inline for (0..3) |channel| {
        const src_channel = std.math.clamp(color[channel], 0.0, 1.0);
        const dst_channel = @as(f32, @floatFromInt(target[offset + channel])) / 255.0;
        target[offset + channel] = @intFromFloat(std.math.clamp(
            (src_channel * src_a + dst_channel * dst_a * inv_a) / out_a * 255.0 + 0.5,
            0.0,
            255.0,
        ));
    }
    target[offset + 3] = @intFromFloat(out_a * 255.0 + 0.5);
}

fn blitPixel(dst: []u8, dst_offset: usize, src: []const u8, src_offset: usize) void {
    dst[dst_offset] = src[src_offset];
    dst[dst_offset + 1] = src[src_offset + 1];
    dst[dst_offset + 2] = src[src_offset + 2];
    dst[dst_offset + 3] = src[src_offset + 3];
}

// ============================================================================
// 渲染命令
// ============================================================================

pub const RenderCommand = union(enum) {
    clear: struct {
        color: [4]f32,
    },
    draw_quad: struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: [4]f32,
    },
    draw_texture: struct {
        texture_id: u32,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        alpha: f32,
    },
    draw_textured_quad: struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        u0: f32,
        v0: f32,
        u1: f32,
        v1: f32,
        color: [4]f32,
    },
    set_viewport: struct {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
    },
    set_scissor: struct {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
    },
    set_blend_mode: BlendMode,
    present: struct {
        sync_interval: u32,
    },
};

// ============================================================================
// GPU 渲染器
// ============================================================================

pub const GPUCompositor = struct {
    device: *d3d10.CompositorDevice,
    swap_chain: *dxgi.DwmSwapChain,
    width: u32,
    height: u32,
    initialized: bool,
    frame_count: u64,
    active_blend_mode: BlendMode,

    pub fn init(self: *GPUCompositor, width: u32, height: u32) !void {
        self.width = width;
        self.height = height;
        self.frame_count = 0;
        self.active_blend_mode = .Alpha;

        // 创建设备
        self.device = try d3d10.CompositorDevice.createCompositorDevice(width, height);

        // 创建交换链
        self.swap_chain = try dxgi.DwmSwapChain.create(width, height, .DXGI_FORMAT_R8G8B8A8_UNORM);

        self.initialized = true;
    }

    pub fn deinit(self: *GPUCompositor) void {
        if (!self.initialized) return;

        self.swap_chain.destroy();
        self.device.destroy();

        self.initialized = false;
    }

    pub fn resize(self: *GPUCompositor, width: u32, height: u32) !void {
        self.width = width;
        self.height = height;

        try self.swap_chain.resizeBuffers(width, height);
    }

    pub fn beginFrame(self: *GPUCompositor) void {
        self.device.clear([_]f32{ 0.0, 0.0, 0.0, 1.0 });
        self.frame_count += 1;
    }

    pub fn endFrame(self: *GPUCompositor, sync_interval: u32) !void {
        try self.swap_chain.present(sync_interval);
    }

    pub fn clear(self: *GPUCompositor, color: [4]f32) void {
        self.device.clear(color);
    }

    pub fn drawQuad(self: *GPUCompositor, x: f32, y: f32, width: f32, height: f32, color: [4]f32) void {
        if (!self.initialized or width <= 0.0 or height <= 0.0) return;

        const surface = self.swap_chain.getBuffer(self.swap_chain.swap_chain.current_buffer) catch return;
        const left = @max(@as(i32, @intFromFloat(@round(x))), 0);
        const top = @max(@as(i32, @intFromFloat(@round(y))), 0);
        const right = @min(@as(i32, @intFromFloat(@round(x + width))), @as(i32, @intCast(self.width)));
        const bottom = @min(@as(i32, @intFromFloat(@round(y + height))), @as(i32, @intCast(self.height)));
        if (left >= right or top >= bottom) return;

        var py = top;
        while (py < bottom) : (py += 1) {
            var px = left;
            while (px < right) : (px += 1) {
                const offset: usize = @intCast(py * @as(i32, @intCast(surface.stride)) + px * 4);
                blendPixel(surface.buffer, offset, color);
            }
        }
        self.device.drawQuad();
    }

    pub fn drawTexturedQuad(self: *GPUCompositor, texture_id: u32, x: f32, y: f32, width: f32, height: f32) void {
        if (!self.initialized or texture_id == 0 or width <= 0.0 or height <= 0.0) return;
        const tex_desc = texture.getTextureDesc(texture_id) orelse return;
        const tex_data = texture.getTextureData(texture_id) orelse return;
        if (tex_desc.width == 0 or tex_desc.height == 0) return;
        if (tex_data.len < tex_desc.width * tex_desc.height * 4) return;

        const surface = self.swap_chain.getBuffer(self.swap_chain.swap_chain.current_buffer) catch return;
        const left = @max(@as(i32, @intFromFloat(@round(x))), 0);
        const top = @max(@as(i32, @intFromFloat(@round(y))), 0);
        const right = @min(@as(i32, @intFromFloat(@round(x + width))), @as(i32, @intCast(self.width)));
        const bottom = @min(@as(i32, @intFromFloat(@round(y + height))), @as(i32, @intCast(self.height)));
        if (left >= right or top >= bottom) return;

        var py = top;
        while (py < bottom) : (py += 1) {
            var px = left;
            while (px < right) : (px += 1) {
                const src_x = @min(
                    (px - left) * @as(i32, @intCast(tex_desc.width)) /
                        @as(i32, @intFromFloat(@round(width))),
                    @as(i32, @intCast(tex_desc.width - 1)),
                );
                const src_y = @min(
                    (py - top) * @as(i32, @intCast(tex_desc.height)) /
                        @as(i32, @intFromFloat(@round(height))),
                    @as(i32, @intCast(tex_desc.height - 1)),
                );
                const src_offset: usize = @intCast((src_y * @as(i32, @intCast(tex_desc.width)) + src_x) * 4);
                const dst_offset: usize = @intCast(py * @as(i32, @intCast(surface.stride)) + px * 4);
                const alpha = @as(f32, @floatFromInt(tex_data[src_offset + 3])) / 255.0;

                if (alpha >= 1.0) {
                    blitPixel(surface.buffer, dst_offset, tex_data, src_offset);
                } else if (alpha > 0.0) {
                    blendPixel(surface.buffer, dst_offset, .{
                        @as(f32, @floatFromInt(tex_data[src_offset])) / 255.0,
                        @as(f32, @floatFromInt(tex_data[src_offset + 1])) / 255.0,
                        @as(f32, @floatFromInt(tex_data[src_offset + 2])) / 255.0,
                        alpha,
                    });
                }
            }
        }
        self.device.drawQuad();
    }

    pub fn setViewport(self: *GPUCompositor, x: i32, y: i32, width: u32, height: u32) void {
        self.device.setViewport(x, y, width, height);
    }

    pub fn setScissor(self: *GPUCompositor, x: i32, y: i32, width: u32, height: u32) void {
        self.device.setScissorRect(x, y, width, height);
    }

    pub fn setBlendMode(self: *GPUCompositor, mode: BlendMode) void {
        self.active_blend_mode = mode;
    }
};

// ============================================================================
// 全局渲染器实例
// ============================================================================

pub var g_gpu_compositor: GPUCompositor = undefined;
pub var g_initialized: bool = false;

pub fn initGPUCompositor(width: u32, height: u32) !void {
    if (g_initialized) return;
    try g_gpu_compositor.init(width, height);
    g_initialized = true;
}

pub fn deinitGPUCompositor() void {
    if (!g_initialized) return;
    g_gpu_compositor.deinit();
    g_initialized = false;
}

pub fn isInitialized() bool {
    return g_initialized;
}

pub fn getCompositor() *GPUCompositor {
    return &g_gpu_compositor;
}

pub fn beginFrame() void {
    g_gpu_compositor.beginFrame();
}

pub fn endFrame(sync_interval: u32) !void {
    try g_gpu_compositor.endFrame(sync_interval);
}

pub fn clearFrame(color: [4]f32) void {
    g_gpu_compositor.clear(color);
}

pub fn resizeCompositor(width: u32, height: u32) !void {
    try g_gpu_compositor.resize(width, height);
}

// ============================================================================
// 批处理渲染
// ============================================================================

pub const BatchRenderItem = struct {
    texture_id: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    color: [4]f32,
    layer: i32,
};

pub const RenderBatch = struct {
    items: [1024]BatchRenderItem,
    count: usize,
    blend_mode: BlendMode,

    pub fn init(batch: *RenderBatch) void {
        batch.count = 0;
        batch.blend_mode = .alpha;
    }

    pub fn add(batch: *RenderBatch, item: BatchRenderItem) void {
        if (batch.count >= 1024) return;
        batch.items[batch.count] = item;
        batch.count += 1;
    }

    pub fn sortByLayer(batch: *RenderBatch) void {
        // 按层级排序
        var i: usize = 1;
        while (i < batch.count) : (i += 1) {
            const key = batch.items[i];
            var j: usize = i;
            while (j > 0 and batch.items[j - 1].layer > key.layer) {
                batch.items[j] = batch.items[j - 1];
                j -= 1;
            }
            batch.items[j] = key;
        }
    }

    pub fn flush(batch: *RenderBatch, compositor: *GPUCompositor) void {
        compositor.setBlendMode(batch.blend_mode);
        batch.sortByLayer();

        for (batch.items[0..batch.count]) |item| {
            compositor.drawTexturedQuad(item.texture_id, item.x, item.y, item.width, item.height);
        }

        batch.count = 0;
    }
};

// ============================================================================
// 特效
// ============================================================================

pub const GaussianBlurParams = struct {
    radius: u32,
    passes: u32,
    direction: enum { horizontal, vertical },
};

pub fn applyGaussianBlur(compositor: *GPUCompositor, texture_id: u32, params: GaussianBlurParams) void {
    _ = compositor;
    _ = texture_id;
    _ = params;
    // 实现高斯模糊
    // 多遍模糊，每次水平或垂直方向
}

pub const BloomParams = struct {
    threshold: f32,
    intensity: f32,
    radius: u32,
};

pub fn applyBloom(compositor: *GPUCompositor, texture_id: u32, params: BloomParams) void {
    _ = compositor;
    _ = texture_id;
    _ = params;
    // 实现泛光效果
}

// ============================================================================
// 统计信息
// ============================================================================

pub const RenderStats = struct {
    frame_count: u64,
    draw_calls: u64,
    triangles_drawn: u64,
    pixels_drawn: u64,
    avg_frame_time_us: u64,
    last_frame_time_us: u64,
};

pub fn getRenderStats() RenderStats {
    return .{
        .frame_count = g_gpu_compositor.frame_count,
        .draw_calls = 0, // 需要从设备获取
        .triangles_drawn = 0,
        .pixels_drawn = 0,
        .avg_frame_time_us = 0,
        .last_frame_time_us = 0,
    };
}
