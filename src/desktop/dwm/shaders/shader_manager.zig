// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// Shader Manager - 着色器资源管理
// 管理 GPU 着色器的加载、编译和绑定

const std = @import("std");
const d3d10 = @import("../d3d10/d3d10.zig");
const d3d10_types = @import("../d3d10/d3d10_types.zig");

// ============================================================================
// 着色器类型
// ============================================================================

pub const ShaderType = enum(u8) {
    vertex = 0,
    pixel = 1,
    geometry = 2,
    compute = 3,
};

pub const ShaderProfile = enum(u8) {
    vs_4_0 = 0,
    ps_4_0 = 1,
    vs_4_1 = 2,
    ps_4_1 = 3,
    vs_5_0 = 4,
    ps_5_0 = 5,
};

// ============================================================================
// 着色器状态
// ============================================================================

pub const ShaderState = struct {
    shader_type: ShaderType,
    profile: ShaderProfile,
    bytecode: []const u8,
    compiled: bool,
    compilation_log: []const u8,
};

pub const MAX_SHADERS: usize = 32;

// ============================================================================
// 着色器缓存
// ============================================================================

pub const ShaderCache = struct {
    shaders: [MAX_SHADERS]?ShaderState,
    count: usize,
    initialized: bool,

    pub fn init(cache: *ShaderCache) void {
        cache.count = 0;
        cache.initialized = true;
        for (0..MAX_SHADERS) |i| {
            cache.shaders[i] = null;
        }
    }

    pub fn addShader(cache: *ShaderCache, shader: ShaderState) ?usize {
        if (cache.count >= MAX_SHADERS) return null;
        cache.shaders[cache.count] = shader;
        cache.count += 1;
        return cache.count - 1;
    }

    pub fn getShader(cache: *ShaderCache, index: usize) ?*ShaderState {
        if (index >= cache.count) return null;
        return &cache.shaders[index].?;
    }
};

pub var g_shader_cache: ShaderCache = .{};

// ============================================================================
// 着色器编译 (占位符)
// ============================================================================

pub const ShaderCompileOptions = struct {
    entry_point: []const u8,
    profile: ShaderProfile,
    flags: u32,
    effect_flags: u32,
};

pub const ShaderCompileResult = struct {
    success: bool,
    shader_bytecode: []const u8,
    error_messages: []const u8,
};

pub fn compileShader(source: []const u8, options: ShaderCompileOptions) ShaderCompileResult {
    _ = source;
    _ = options;

    // TODO: 实现实际的着色器编译
    // 目前返回空字节码
    return .{
        .success = true,
        .shader_bytecode = &.{},
        .error_messages = "",
    };
}

pub fn compileFromFile(filename: []const u8, options: ShaderCompileOptions) ShaderCompileResult {
    _ = filename;
    return compileShader("", options);
}

// ============================================================================
// 着色器管理函数
// ============================================================================

pub fn initShaderLoader() void {
    g_shader_cache.init();
}

pub fn deinitShaderLoader() void {
    g_shader_cache.initialized = false;
    g_shader_cache.count = 0;
}

pub fn loadDefaultShaders() void {
    // TODO: 加载默认着色器
    // - blur_shader: 高斯模糊
    // - glass_shader: 玻璃效果
    // - shadow_shader: 阴影效果
}

pub fn getShaderBytecode(shader_id: usize) ?[]const u8 {
    if (g_shader_cache.getShader(shader_id)) |shader| {
        if (shader.compiled) {
            return shader.bytecode;
        }
    }
    return null;
}

// ============================================================================
// 内置着色器字节码 (简化版)
// ============================================================================

// 全屏四边形顶点着色器
pub const VS_QUAD_BYTECODE = [_]u8{};

// 玻璃效果像素着色器
pub const PS_GLASS_BYTECODE = [_]u8{};

// 模糊效果像素着色器
pub const PS_BLUR_BYTECODE = [_]u8{};

// 阴影效果像素着色器
pub const PS_SHADOW_BYTECODE = [_]u8{};

// ============================================================================
// 着色器程序
// ============================================================================

pub const ShaderProgram = struct {
    vertex_shader: ?usize,
    pixel_shader: ?usize,
    geometry_shader: ?usize,
    input_layout: ?usize,
};

pub fn createShaderProgram(
    vs_source: []const u8,
    ps_source: []const u8,
    vs_profile: ShaderProfile,
    ps_profile: ShaderProfile,
) ?ShaderProgram {
    const vs_options = ShaderCompileOptions{
        .entry_point = "main",
        .profile = vs_profile,
        .flags = 0,
        .effect_flags = 0,
    };

    const ps_options = ShaderCompileOptions{
        .entry_point = "main",
        .profile = ps_profile,
        .flags = 0,
        .effect_flags = 0,
    };

    const vs_result = compileShader(vs_source, vs_options);
    const ps_result = compileShader(ps_source, ps_options);

    if (!vs_result.success or !ps_result.success) {
        return null;
    }

    var program: ShaderProgram = .{
        .vertex_shader = null,
        .pixel_shader = null,
        .geometry_shader = null,
        .input_layout = null,
    };

    // 添加顶点着色器
    const vs_shader = ShaderState{
        .shader_type = .vertex,
        .profile = vs_profile,
        .bytecode = vs_result.shader_bytecode,
        .compiled = true,
        .compilation_log = "",
    };
    program.vertex_shader = g_shader_cache.addShader(vs_shader);

    // 添加像素着色器
    const ps_shader = ShaderState{
        .shader_type = .pixel,
        .profile = ps_profile,
        .bytecode = ps_result.shader_bytecode,
        .compiled = true,
        .compilation_log = "",
    };
    program.pixel_shader = g_shader_cache.addShader(ps_shader);

    return program;
}

pub fn destroyShaderProgram(program: *ShaderProgram) void {
    program.vertex_shader = null;
    program.pixel_shader = null;
    program.geometry_shader = null;
    program.input_layout = null;
}

// ============================================================================
// 着色器参数
// ============================================================================

pub const ShaderParam = struct {
    name: []const u8,
    value: ShaderParamValue,
};

pub const ShaderParamValue = union {
    float: f32,
    vec2: [2]f32,
    vec3: [3]f32,
    vec4: [4]f32,
    matrix: [16]f32,
    texture: usize,
};

pub const ShaderConstantBuffer = struct {
    params: [16]?ShaderParam,
    param_count: usize,
};

pub fn setShaderParam(buffer: *ShaderConstantBuffer, name: []const u8, value: ShaderParamValue) void {
    if (buffer.param_count >= 16) return;

    buffer.params[buffer.param_count] = .{
        .name = name,
        .value = value,
    };
    buffer.param_count += 1;
}

pub fn clearShaderParams(buffer: *ShaderConstantBuffer) void {
    buffer.param_count = 0;
    for (0..16) |i| {
        buffer.params[i] = null;
    }
}

// ============================================================================
// 工具函数
// ============================================================================

pub fn getShaderTypeName(shader_type: ShaderType) []const u8 {
    return switch (shader_type) {
        .vertex => "Vertex Shader",
        .pixel => "Pixel Shader",
        .geometry => "Geometry Shader",
        .compute => "Compute Shader",
    };
}

pub fn getProfileName(profile: ShaderProfile) []const u8 {
    return switch (profile) {
        .vs_4_0 => "vs_4_0",
        .ps_4_0 => "ps_4_0",
        .vs_4_1 => "vs_4_1",
        .ps_4_1 => "ps_4_1",
        .vs_5_0 => "vs_5_0",
        .ps_5_0 => "ps_5_0",
    };
}

pub fn getLoadedShaderCount() usize {
    return g_shader_cache.count;
}

pub fn isShaderLoaded(shader_id: usize) bool {
    return g_shader_cache.getShader(shader_id) != null;
}
