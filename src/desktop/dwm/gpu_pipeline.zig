// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// GPU Rendering Pipeline - D3D10 渲染管线
// 提供完整的 GPU 加速渲染能力

const std = @import("std");
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

    pub fn init(self: *GPUCompositor, width: u32, height: u32) !void {
        self.width = width;
        self.height = height;
        self.frame_count = 0;

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
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = color;
        // 实际实现需要顶点缓冲区和着色器
        // 这是占位符
    }

    pub fn drawTexturedQuad(self: *GPUCompositor, texture_id: u32, x: f32, y: f32, width: f32, height: f32) void {
        _ = self;
        _ = texture_id;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        // 实际实现需要纹理绑定和着色器
        // 这是占位符
    }

    pub fn setViewport(self: *GPUCompositor, x: i32, y: i32, width: u32, height: u32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        // 设置视口
    }

    pub fn setScissor(self: *GPUCompositor, x: i32, y: i32, width: u32, height: u32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        // 设置裁剪矩形
    }

    pub fn setBlendMode(self: *GPUCompositor, mode: BlendMode) void {
        _ = self;
        _ = mode;
        // 设置混合模式
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