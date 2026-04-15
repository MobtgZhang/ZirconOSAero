// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Shaders - Shader Loader
//! Manages loading and initialization of compiled shader bytecode.

const std = @import("std");

// ============================================================================
// Shader Types
// ============================================================================

pub const ShaderType = enum {
    vertex,
    pixel,
    geometry,
    compute,
};

// ============================================================================
// Shader Bytecode Storage
// ============================================================================

pub const MAX_SHADER_TYPES: usize = 4;

pub const ShaderBytecode = struct {
    shader_type: ShaderType,
    bytecode: []const u8,
    size: usize,
};

pub const ShaderCache = struct {
    shaders: [MAX_SHADER_TYPES]?ShaderBytecode = .{null} ** MAX_SHADER_TYPES,
    initialized: bool,

    pub fn init(self: *ShaderCache) void {
        self.initialized = true;
    }

    pub fn loadShader(self: *ShaderCache, shader_type: ShaderType, bytecode: []const u8) void {
        const idx = @intFromEnum(shader_type);
        if (idx < MAX_SHADER_TYPES) {
            self.shaders[idx] = .{
                .shader_type = shader_type,
                .bytecode = bytecode,
                .size = bytecode.len,
            };
        }
    }

    pub fn getShader(self: *const ShaderCache, shader_type: ShaderType) ?*const ShaderBytecode {
        const idx = @intFromEnum(shader_type);
        if (idx < MAX_SHADER_TYPES) {
            return self.shaders[idx];
        }
        return null;
    }

    pub fn deinit(self: *ShaderCache) void {
        for (self.shaders[0..MAX_SHADER_TYPES]) |*shader| {
            shader.* = null;
        }
        self.initialized = false;
    }
};

// ============================================================================
// Global Shader Cache
// ============================================================================

pub var g_shader_cache: ShaderCache = .{};

// ============================================================================
// Shader Loader API
// ============================================================================

pub fn initShaderLoader() void {
    g_shader_cache.init();
}

pub fn deinitShaderLoader() void {
    g_shader_cache.deinit();
}

pub fn loadVertexShader(bytecode: []const u8) void {
    g_shader_cache.loadShader(.vertex, bytecode);
}

pub fn loadPixelShader(bytecode: []const u8) void {
    g_shader_cache.loadShader(.pixel, bytecode);
}

pub fn getVertexShader() ?*const ShaderBytecode {
    return g_shader_cache.getShader(.vertex);
}

pub fn getPixelShader() ?*const ShaderBytecode {
    return g_shader_cache.getShader(.pixel);
}

// ============================================================================
// Placeholder Shader Bytecode
// These would be replaced with actual compiled HLSL bytecode in production
// ============================================================================

pub const VERTEX_SHADER_QUAD_BYTECODE: []const u8 = &.{
    // Minimal passthrough vertex shader bytecode placeholder
    // In production, this would be compiled HLSL bytecode
    0x00, 0x00, 0x00, 0x00, // Dummy bytecode
};

pub const PIXEL_SHADER_QUAD_BYTECODE: []const u8 = &.{
    // Minimal passthrough pixel shader bytecode placeholder
    // In production, this would be compiled HLSL bytecode
    0x00, 0x00, 0x00, 0x00, // Dummy bytecode
};

pub const GLASS_EFFECT_SHADER_BYTECODE: []const u8 = &.{
    // Glass effect pixel shader bytecode placeholder
    // Implements: Gaussian blur + tint blend + specular highlight
    0x00, 0x00, 0x00, 0x00, // Dummy bytecode
};

pub const SHADOW_SHADER_BYTECODE: []const u8 = &.{
    // Shadow rendering pixel shader bytecode placeholder
    // Implements: Multi-layer soft shadow with distance field
    0x00, 0x00, 0x00, 0x00, // Dummy bytecode
};

// Load all default shaders
pub fn loadDefaultShaders() void {
    loadVertexShader(VERTEX_SHADER_QUAD_BYTECODE);
    loadPixelShader(PIXEL_SHADER_QUAD_BYTECODE);
}

// ============================================================================
// Shader Statistics
// ============================================================================

pub const ShaderStats = struct {
    vertex_shaders_loaded: u32 = 0,
    pixel_shaders_loaded: u32 = 0,
    total_shader_size: usize = 0,
    compilation_failures: u32 = 0,
};

pub var g_shader_stats: ShaderStats = .{};

pub fn getShaderStats() ShaderStats {
    return g_shader_stats;
}
