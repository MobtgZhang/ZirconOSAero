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

//! D3D10 InputLayout Implementation

const d3d10_types = @import("d3d10_types.zig");
const d3d10_errors = @import("d3d10_errors.zig");

// ============================================================================
// Input Layout Interface
// ============================================================================

pub const ID3D10InputLayout = extern struct {
    QueryInterface: fn (*const ID3D10InputLayout, *const [16]u8, *?*anyopaque) callconv(.C) d3d10_types.HRESULT,
    AddRef: fn (*const ID3D10InputLayout) callconv(.C) u32,
    Release: fn (*const ID3D10InputLayout) callconv(.C) u32,
    GetDevice: fn (*const ID3D10InputLayout) callconv(.C) *anyopaque,
    GetPrivateData: fn (*const ID3D10InputLayout, *const [16]u8, *u32, *anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateData: fn (*const ID3D10InputLayout, *const [16]u8, u32, *const anyopaque) callconv(.C) d3d10_types.HRESULT,
    SetPrivateDataInterface: fn (*const ID3D10InputLayout, *const [16]u8, ?*const anyopaque) callconv(.C) d3d10_types.HRESULT,
};

// ============================================================================
// Input Layout State
// ============================================================================

pub const InputLayoutState = struct {
    ref_count: u32,
    elements: []d3d10_types.D3D10_INPUT_ELEMENT_DESC,
    element_count: u32,
    total_size: u32,
};

pub const MAX_INPUT_LAYOUTS: usize = 64;
pub var g_input_layout_pool: [MAX_INPUT_LAYOUTS]?InputLayoutState = [_]?InputLayoutState{null} ** MAX_INPUT_LAYOUTS;
pub var g_input_layout_count: usize = 0;

// ============================================================================
// Input Layout Creation
// ============================================================================

pub fn createInputLayout(
    device: *anyopaque,
    num_elements: u32,
    input_element_descs: [*]const d3d10_types.D3D10_INPUT_ELEMENT_DESC,
    bytecode_with_input_signature: [*]const u8,
    bytecode_length: usize,
    ppInputLayout: *?*ID3D10InputLayout,
) d3d10_types.HRESULT {
    _ = device;
    _ = bytecode_with_input_signature;
    _ = bytecode_length;

    if (g_input_layout_count >= MAX_INPUT_LAYOUTS) {
        return d3d10_errors.E_OUTOFMEMORY;
    }

    var total_size: u32 = 0;
    var last_offset: u32 = 0;
    var last_slot: u32 = 0;

    for (0..num_elements) |i| {
        const elem = input_element_descs[i];
        if (elem.InputSlot != last_slot) {
            last_offset = 0;
            last_slot = elem.InputSlot;
        }

        const format_size = getFormatSize(elem.Format);
        total_size += format_size;
        last_offset += format_size;
    }

    g_input_layout_pool[g_input_layout_count] = .{
        .ref_count = 1,
        .elements = &input_element_descs,
        .element_count = num_elements,
        .total_size = total_size,
    };

    g_input_layout_count += 1;
    _ = ppInputLayout;
    return d3d10_errors.S_OK;
}

fn getFormatSize(format: d3d10_types.DXGI_FORMAT) u32 {
    return switch (format) {
        .r32g32b32a32_float, .r32g32b32a32_uint, .r32g32b32a32_sint => 16,
        .r32g32b32_float, .r32g32b32_uint, .r32g32b32_sint => 12,
        .r16g16b16a16_float, .r16g16b16a16_unorm, .r16g16b16a16_uint, .r16g16b16a16_snorm, .r16g16b16a16_sint => 8,
        .r32g32_float, .r32g32_uint, .r32g32_sint => 8,
        .r8g8b8a8_unorm, .r8g8b8a8_uint, .r8g8b8a8_snorm, .r8g8b8a8_sint => 4,
        .r16g16_float, .r16g16_unorm, .r16g16_uint, .r16g16_snorm, .r16g16_sint => 4,
        .r32_float, .r32_uint, .r32_sint => 4,
        .r8g8_unorm, .r8g8_uint, .r8g8_snorm, .r8g8_sint => 2,
        .r16_float, .r16_unorm, .r16_uint, .r16_snorm, .r16_sint, .d16_unorm => 2,
        .r8_unorm, .r8_uint, .r8_snorm, .r8_sint, .a8_unorm => 1,
        else => 4,
    };
}
