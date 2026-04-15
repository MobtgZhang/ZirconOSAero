// Copyright (c) 2024 ZirconOS Project <mobtgzhang@outlook.com>
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

//! D3D10 Core Types for ZirconOS DWM
//! Clean-room implementation based on public DirectX documentation.
//! Reference: https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/dxgi-format

const std = @import("std");

// ============================================================================
// DXGI_FORMAT Enum
// ============================================================================

pub const DXGI_FORMAT = enum(u32) {
    unknown = 0,
    r32g32b32a32_typeless = 1,
    r32g32b32a32_float = 2,
    r32g32b32a32_uint = 3,
    r32g32b32a32_sint = 4,
    r32g32b32_typeless = 5,
    r32g32b32_float = 6,
    r32g32b32_uint = 7,
    r32g32b32_sint = 8,
    r16g16b16a16_typeless = 9,
    r16g16b16a16_float = 10,
    r16g16b16a16_unorm = 11,
    r16g16b16a16_uint = 12,
    r16g16b16a16_snorm = 13,
    r16g16b16a16_sint = 14,
    r32g32_typeless = 15,
    r32g32_float = 16,
    r32g32_uint = 17,
    r32g32_sint = 18,
    r32g8x24_typeless = 19,
    d32_float_s8x24_uint = 20,
    r32_float_x8x24_typeless = 21,
    x32_typeless_g8x24_uint = 22,
    r10g10b10a2_typeless = 23,
    r10g10b10a2_unorm = 24,
    r10g10b10a2_uint = 25,
    r11g11b10_float = 26,
    r8g8b8a8_typeless = 27,
    r8g8b8a8_unorm = 28,
    r8g8b8a8_unorm_srgb = 29,
    r8g8b8a8_uint = 30,
    r8g8b8a8_snorm = 31,
    r8g8b8a8_sint = 32,
    r16g16_typeless = 33,
    r16g16_float = 34,
    r16g16_unorm = 35,
    r16g16_uint = 36,
    r16g16_snorm = 37,
    r16g16_sint = 38,
    r32_typeless = 39,
    d32_float = 40,
    r32_float = 41,
    r32_uint = 42,
    r32_sint = 43,
    r8g8_typeless = 44,
    r8g8_unorm = 45,
    r8g8_uint = 46,
    r8g8_snorm = 47,
    r8g8_sint = 48,
    r16_typeless = 49,
    r16_float = 50,
    d16_unorm = 51,
    r16_unorm = 52,
    r16_uint = 53,
    r16_snorm = 54,
    r16_sint = 55,
    r8_typeless = 56,
    r8_unorm = 57,
    r8_uint = 58,
    r8_snorm = 59,
    r8_sint = 60,
    a8_unorm = 61,
    r1_unorm = 62,
    r9g9b9e5_sharedexp = 63,
    r8g8_b8g8_unorm = 64,
    g8r8_g8b8_unorm = 65,
    bc1_typeless = 66,
    bc1_unorm = 67,
    bc1_unorm_srgb = 68,
    bc2_typeless = 69,
    bc2_unorm = 70,
    bc2_unorm_srgb = 71,
    bc3_typeless = 72,
    bc3_unorm = 73,
    bc3_unorm_srgb = 74,
    bc4_typeless = 75,
    bc4_unorm = 76,
    bc4_snorm = 77,
    bc5_typeless = 78,
    bc5_unorm = 79,
    bc5_snorm = 80,
    b5g6r5_unorm = 85,
    b5g5r5a1_unorm = 86,
    b8g8r8a8_unorm = 87,
    b8g8r8x8_unorm = 88,
    r10g10b10_xr_bias_a2_unorm = 89,
    b8g8r8a8_typeless = 90,
    b8g8r8a8_unorm_srgb = 91,
    b8g8r8x8_typeless = 92,
    b8g8r8x8_unorm_srgb = 93,
    bc6h_typeless = 94,
    bc6h_uf16 = 95,
    bc6h_sf16 = 96,
    bc7_typeless = 97,
    bc7_unorm = 98,
    bc7_unorm_srgb = 99,
    // ZirconOS DWM专用格式
    b8g8r8a8_typeless_dwm = 100,
    b8g8r8a8_unorm_dwm = 101,
    r8g8b8a8_typeless_dwm = 102,
    r8g8b8a8_unorm_dwm = 103,
};

// ============================================================================
// D3D10_USAGE Enum
// ============================================================================

pub const D3D10_USAGE = enum(u32) {
    default = 0,
    immutable = 1,
    dynamic = 2,
    staging = 3,
};

// ============================================================================
// D3D10_BIND_FLAG
// ============================================================================

pub const D3D10_BIND_FLAG = u32;

pub const D3D10_BIND_VERTEX_BUFFER: D3D10_BIND_FLAG = 0x01;
pub const D3D10_BIND_INDEX_BUFFER: D3D10_BIND_FLAG = 0x02;
pub const D3D10_BIND_CONSTANT_BUFFER: D3D10_BIND_FLAG = 0x04;
pub const D3D10_BIND_SHADER_RESOURCE: D3D10_BIND_FLAG = 0x08;
pub const D3D10_BIND_STREAM_OUTPUT: D3D10_BIND_FLAG = 0x10;
pub const D3D10_BIND_RENDER_TARGET: D3D10_BIND_FLAG = 0x20;
pub const D3D10_BIND_DEPTH_STENCIL: D3D10_BIND_FLAG = 0x40;
pub const D3D10_BIND_UNORDERED_ACCESS: D3D10_BIND_FLAG = 0x80;

// ============================================================================
// DXGI_MISC_FLAG
// ============================================================================

pub const DXGI_MISC_FLAG = u32;

pub const DXGI_MISC_GENERATE_MIPS: DXGI_MISC_FLAG = 0x01;
pub const DXGI_MISC_SHARED: DXGI_MISC_FLAG = 0x02;
pub const DXGI_MISC_TEXTURECUBE: DXGI_MISC_FLAG = 0x04;

// ============================================================================
// DXGI_SAMPLE_DESC
// ============================================================================

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: u32 = 1,
    Quality: u32 = 0,
};

// ============================================================================
// DXGI_RATIONAL
// ============================================================================

pub const DXGI_RATIONAL = extern struct {
    Numerator: u32,
    Denominator: u32,
};

// ============================================================================
// D3D10_TEXTURE2D_DESC
// ============================================================================

pub const D3D10_TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32,
    ArraySize: u32,
    Format: DXGI_FORMAT,
    SampleDesc: DXGI_SAMPLE_DESC,
    Usage: D3D10_USAGE,
    BindFlags: D3D10_BIND_FLAG,
    CPUAccessFlags: u32,
    MiscFlags: DXGI_MISC_FLAG,
};

// ============================================================================
// D3D10_VIEWPORT
// ============================================================================

pub const D3D10_VIEWPORT = extern struct {
    TopLeftX: i32,
    TopLeftY: i32,
    Width: u32,
    Height: u32,
    MinDepth: f32,
    MaxDepth: f32,

    pub fn zero() D3D10_VIEWPORT {
        return .{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = 0,
            .Height = 0,
            .MinDepth = 0.0,
            .MaxDepth = 1.0,
        };
    }
};

// ============================================================================
// D3D10_BOX
// ============================================================================

pub const D3D10_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

// ============================================================================
// D3D10_RESOURCE_DIMENSION
// ============================================================================

pub const D3D10_RESOURCE_DIMENSION = enum(u32) {
    unknown = 0,
    buffer = 1,
    texture1d = 2,
    texture2d = 3,
    texture3d = 4,
};

// ============================================================================
// D3D10_SUBRESOURCE_DATA
// ============================================================================

pub const D3D10_SUBRESOURCE_DATA = extern struct {
    pSysMem: [*]const anyopaque,
    SysMemPitch: u32,
    SysMemSlicePitch: u32,
};

// ============================================================================
// D3D10_BUFFER_DESC
// ============================================================================

pub const D3D10_BUFFER_DESC = extern struct {
    ByteWidth: u32,
    Usage: D3D10_USAGE,
    BindFlags: D3D10_BIND_FLAG,
    CPUAccessFlags: u32,
    MiscFlags: u32,
};

// ============================================================================
// D3D10_BLEND_DESC
// ============================================================================

pub const D3D10_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL,
    SrcBlend: D3D10_BLEND,
    DestBlend: D3D10_BLEND,
    BlendOp: D3D10_BLEND_OP,
    SrcBlendAlpha: D3D10_BLEND,
    DestBlendAlpha: D3D10_BLEND,
    BlendOpAlpha: D3D10_BLEND_OP,
    RenderTargetWriteMask: u8,
};

// ============================================================================
// D3D10_BLEND
// ============================================================================

pub const D3D10_BLEND = enum(u32) {
    zero = 1,
    one = 2,
    src_color = 3,
    inv_src_color = 4,
    src_alpha = 5,
    inv_src_alpha = 6,
    dest_alpha = 7,
    inv_dest_alpha = 8,
    dest_color = 9,
    inv_dest_color = 10,
    src_alpha_sat = 11,
    blend_factor = 12,
    inv_blend_factor = 13,
    src1_color = 14,
    inv_src1_color = 15,
    src1_alpha = 16,
    inv_src1_alpha = 17,
};

// ============================================================================
// D3D10_BLEND_OP
// ============================================================================

pub const D3D10_BLEND_OP = enum(u32) {
    add = 1,
    subtract = 2,
    rev_subtract = 3,
    min = 4,
    max = 5,
};

// ============================================================================
// D3D10_RASTERIZER_DESC
// ============================================================================

pub const D3D10_RASTERIZER_DESC = extern struct {
    FillMode: D3D10_FILL_MODE,
    CullMode: D3D10_CULL_MODE,
    FrontCounterClockwise: BOOL,
    DepthBias: i32,
    DepthBiasClamp: f32,
    SlopeScaledDepthBias: f32,
    DepthClipEnable: BOOL,
    ScissorEnable: BOOL,
    MultisampleEnable: BOOL,
    AntialiasedLineEnable: BOOL,
};

// ============================================================================
// D3D10_FILL_MODE
// ============================================================================

pub const D3D10_FILL_MODE = enum(u32) {
    wireframe = 2,
    solid = 3,
};

// ============================================================================
// D3D10_CULL_MODE
// ============================================================================

pub const D3D10_CULL_MODE = enum(u32) {
    none = 1,
    front = 2,
    back = 3,
};

// ============================================================================
// D3D10_DEPTH_STENCIL_DESC
// ============================================================================

pub const D3D10_DEPTH_STENCIL_DESC = extern struct {
    DepthEnable: BOOL,
    DepthWriteMask: D3D10_DEPTH_WRITE_MASK,
    DepthFunc: D3D10_COMPARISON_FUNC,
    StencilEnable: BOOL,
    StencilReadMask: u8,
    StencilWriteMask: u8,
    FrontFace: D3D10_DEPTH_STENCILOP_DESC,
    BackFace: D3D10_DEPTH_STENCILOP_DESC,
};

// ============================================================================
// D3D10_DEPTH_WRITE_MASK
// ============================================================================

pub const D3D10_DEPTH_WRITE_MASK = enum(u32) {
    zero = 0,
    all = 1,
};

// ============================================================================
// D3D10_COMPARISON_FUNC
// ============================================================================

pub const D3D10_COMPARISON_FUNC = enum(u32) {
    never = 1,
    less = 2,
    equal = 3,
    less_equal = 4,
    greater = 5,
    not_equal = 6,
    greater_equal = 7,
    always = 8,
};

// ============================================================================
// D3D10_DEPTH_STENCILOP_DESC
// ============================================================================

pub const D3D10_DEPTH_STENCILOP_DESC = extern struct {
    StencilFailOp: D3D10_STENCIL_OP,
    StencilDepthFailOp: D3D10_STENCIL_OP,
    StencilPassOp: D3D10_STENCIL_OP,
    StencilFunc: D3D10_COMPARISON_FUNC,
};

// ============================================================================
// D3D10_STENCIL_OP
// ============================================================================

pub const D3D10_STENCIL_OP = enum(u32) {
    keep = 1,
    zero = 2,
    replace = 3,
    incr_sat = 4,
    decr_sat = 5,
    invert = 6,
    incr = 7,
    decr = 8,
};

// ============================================================================
// D3D10_INPUT_ELEMENT_DESC
// ============================================================================

pub const D3D10_INPUT_ELEMENT_DESC = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: u32,
    Format: DXGI_FORMAT,
    InputSlot: u32,
    AlignedByteOffset: u32,
    InputSlotClass: D3D10_INPUT_CLASSIFICATION,
    InstanceDataStepRate: u32,
};

// ============================================================================
// D3D10_INPUT_CLASSIFICATION
// ============================================================================

pub const D3D10_INPUT_CLASSIFICATION = enum(u32) {
    per_vertex_data = 0,
    per_instance_data = 1,
};

// ============================================================================
// D3D10_SAMPLER_DESC
// ============================================================================

pub const D3D10_SAMPLER_DESC = extern struct {
    Filter: D3D10_FILTER,
    AddressU: D3D10_TEXTURE_ADDRESS_MODE,
    AddressV: D3D10_TEXTURE_ADDRESS_MODE,
    AddressW: D3D10_TEXTURE_ADDRESS_MODE,
    MipLODBias: f32,
    MaxAnisotropy: u32,
    ComparisonFunc: D3D10_COMPARISON_FUNC,
    BorderColor: [4]f32,
    MinLOD: f32,
    MaxLOD: f32,
};

// ============================================================================
// D3D10_FILTER
// ============================================================================

pub const D3D10_FILTER = enum(u32) {
    min_mag_mip_point = 0,
    min_mag_point_mip_linear = 0x1,
    min_point_mag_linear_mip_point = 0x2,
    min_point_mag_mip_linear = 0x3,
    min_linear_mag_point_mip_point = 0x4,
    min_linear_mag_point_mip_linear = 0x5,
    min_mag_linear_mip_point = 0x6,
    min_mag_linear_mip_linear = 0x7,
    anisotropic = 0xD,
    comparison_min_mag_mip_point = 0x81,
    comparison_min_mag_point_mip_linear = 0x91,
    comparison_min_point_mag_linear_mip_point = 0xA2,
    comparison_min_point_mag_mip_linear = 0xB3,
    comparison_min_linear_mag_point_mip_point = 0xC4,
    comparison_min_linear_mag_point_mip_linear = 0xD5,
    comparison_min_mag_linear_mip_point = 0xE6,
    comparison_min_mag_linear_mip_linear = 0xF7,
    comparison_anisotropic = 0xDD,
};

// ============================================================================
// D3D10_TEXTURE_ADDRESS_MODE
// ============================================================================

pub const D3D10_TEXTURE_ADDRESS_MODE = enum(u32) {
    wrap = 1,
    border = 2,
    clamp = 3,
    mirror = 4,
    mirror_once = 5,
};

// ============================================================================
// DXGI_SWAP_CHAIN_DESC
// ============================================================================

pub const DXGI_SWAP_CHAIN_DESC = extern struct {
    BufferDesc: DXGI_MODE_DESC,
    SampleDesc: DXGI_SAMPLE_DESC,
    BufferUsage: DXGI_USAGE,
    BufferCount: u32,
    OutputWindow: ?*anyopaque,
    Windowed: BOOL,
    SwapEffect: DXGI_SWAP_EFFECT,
    Flags: DXGI_SWAP_CHAIN_FLAG,
};

// ============================================================================
// DXGI_MODE_DESC
// ============================================================================

pub const DXGI_MODE_DESC = extern struct {
    Width: u32,
    Height: u32,
    RefreshRate: DXGI_RATIONAL,
    Format: DXGI_FORMAT,
    ScanlineOrdering: DXGI_MODE_SCANLINE_ORDER,
    Scaling: DXGI_MODE_SCALING,
};

// ============================================================================
// DXGI_MODE_SCANLINE_ORDER
// ============================================================================

pub const DXGI_MODE_SCANLINE_ORDER = enum(u32) {
    unspecified = 0,
    progressive = 1,
    upper_field_first = 2,
    lower_field_first = 3,
};

// ============================================================================
// DXGI_MODE_SCALING
// ============================================================================

pub const DXGI_MODE_SCALING = enum(u32) {
    centerd = 0,
    stretched = 1,
    aspect_ratio_centered = 2,
};

// ============================================================================
// DXGI_USAGE
// ============================================================================

pub const DXGI_USAGE = u32;

pub const DXGI_USAGE_BACK_BUFFER: DXGI_USAGE = 0x2;
pub const DXGI_USAGE_READ_WRITE: DXGI_USAGE = 0x4;
pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: DXGI_USAGE = 0x1;
pub const DXGI_USAGE_SHADER_INPUT: DXGI_USAGE = 0x10;
pub const DXGI_USAGE_DISCARD_AT_PRESENT: DXGI_USAGE = 0x8;

// ============================================================================
// DXGI_SWAP_EFFECT
// ============================================================================

pub const DXGI_SWAP_EFFECT = enum(u32) {
    discard = 0,
    sequential = 1,
    flip_discarded = 2,
    flip_sequential = 3,
};

// ============================================================================
// DXGI_SWAP_CHAIN_FLAG
// ============================================================================

pub const DXGI_SWAP_CHAIN_FLAG = u32;

pub const DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH: DXGI_SWAP_CHAIN_FLAG = 0x1;
pub const DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING: DXGI_SWAP_CHAIN_FLAG = 0x2;
pub const DXGI_SWAP_CHAIN_FLAG_FORCE_DWORD: DXGI_SWAP_CHAIN_FLAG = 0x7FFFFFFF;

// ============================================================================
// DXGI_PRESENT_PARAMETERS
// ============================================================================

pub const DXGI_PRESENT_PARAMETERS = extern struct {
    SrcRect: D3D10_RECT,
    DstRect: D3D10_RECT,
    DirtyRectsCount: u32,
    pDirtyRects: [*]D3D10_RECT,
};

// ============================================================================
// D3D10_RECT
// ============================================================================

pub const D3D10_RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

// ============================================================================
// D3D10_RECT supported helpers
// ============================================================================

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn toD3D10Rect(self: Rect) D3D10_RECT {
        return .{
            .left = self.x,
            .top = self.y,
            .right = self.x + self.w,
            .bottom = self.y + self.h,
        };
    }
};

// ============================================================================
// BOOL type (Windows-compatible)
// ============================================================================

pub const BOOL = i32;
pub const FALSE: BOOL = 0;
pub const TRUE: BOOL = 1;
