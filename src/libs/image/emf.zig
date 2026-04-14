// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
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

//! SPDX-License-Identifier: MIT OR Apache-2.0
//!
//! ZirconOSAero — EMF (Enhanced Metafile) Decoder
//!
//! Independent EMF decoder. EMF is a 32-bit vector graphics format,
//! the enhanced version of WMF.
//!
//! Reference:
//!   - [MS-EMF]: Enhanced Metafile Format (Microsoft)
//!
//! Supported EMR record types:
//!   EMR_HEADER, EMR_SETBKMODE, EMR_SETBKCOLOR, EMR_SETTEXTCOLOR,
//!   EMR_ELLIPSE, EMR_RECTANGLE, EMR_ROUNDRECT, EMR_ARC, EMR_CHORD, EMR_PIE,
//!   EMR_POLYLINE, EMR_POLYGON, EMR_POLYBEZIER, EMR_POLYBEZIERTO,
//!   EMR_POLYLINETO, EMR_POLYGONTO, EMR_STRETCHBLT, EMR_STRETCHDIBITS,
//!   EMR_SETPIXELV, EMR_CREATEBRUSHINDIRECT, EMR_CREATEPEN,
//!   EMR_CREATEMONOBRUSH, EMR_SELECTOBJECT, EMR_DELETEOBJECT,
//!   EMR_SAVEDC, EMR_RESTOREDC, EMR_SETTEXTALIGN, EMR_EXTTEXTOUTW, EMR_TEXTOUTW,
//!   EMR_BITBLT, EMR_MASKBLT, EMR_ALPHABLEND, EMR_GRADIENTFILL,
//!   EMR_TRANSPARENTBLT, EMR_HEADER (end)
//!
//! NOT supported:
//!   EMF+ records (record type >= 0x40000000)
//!   WMF records embedded in EMF

const std = @import("std");
const mod = @import("mod.zig");

// ============================================================================
// Structures

/// EMF record types.
const EmrRecordType = enum(u32) {
    // Drawing records
    EMR_SETPIXELV = 15,
    EMR_LINETO = 54,
    EMR_MOVETOEX = 27,
    EMR_RECTANGLE = 40,
    EMR_ELLIPSE = 42,
    EMR_ARC = 43,
    EMR_CHORD = 46,
    EMR_PIE = 47,
    EMR_ROUNDRECT = 48,
    EMRANGLE = 49,
    EMR_ARCTO = 55,
    EMR_SETMAPMODE = 17,
    EMR_SETVIEWPORTEXTEX = 26,
    EMR_SETVIEWPORTORGEX = 25,
    EMR_SETWINDOWEXTEX = 9,
    EMR_SETWINDOWORGEX = 10,

    // Polyline/polygon
    EMR_POLYLINE = 70,
    EMR_POLYLINE16 = 87,
    EMR_POLYGON = 68,
    EMR_POLYGON16 = 86,
    EMR_POLYBEZIER = 2,
    EMR_POLYBEZIER16 = 85,
    EMR_POLYBEZIERTO = 3,
    EMR_POLYBEZIERTO16 = 88,
    EMR_POLYLINETO = 57,
    EMR_POLYLINETO16 = 90,
    EMR_POLYPOLYGON = 53,
    EMR_POLYPOLYGON16 = 91,
    EMR_POLYPOLYLINE = 65,
    EMR_POLYPOLYLINE16 = 89,

    // Bitmap operations
    EMR_STRETCHBLT = 78,
    EMR_STRETCHDIBITS = 81,
    EMR_BITBLT = 76,
    EMR_MASKBLT = 79,
    EMR_ALPHABLEND = 125,
    EMR_TRANSPARENTBLT = 122,

    // Gradient fill
    EMR_GRADIENTFILL = 118,

    // Text
    EMR_EXTTEXTOUTW = 84,
    EMR_TEXTOUTW = 83,
    EMR_SETTEXTALIGN = 22,
    EMR_SETTEXTCOLOR = 24,

    // Object management
    EMR_CREATEBRUSHINDIRECT = 38,
    EMR_CREATEPEN = 37,
    EMR_CREATEMONOBRUSH = 93,
    EMR_SELECTOBJECT = 13,
    EMR_DELETEOBJECT = 14,
    EMR_SAVEDC = 30,
    EMR_RESTOREDC = 33,

    // Header
    EMR_HEADER = 1,
    EMR_EOF = 14,

    // Color modes
    EMR_SETBKMODE = 18,
    EMR_SETBKCOLOR = 19,

    UNKNOWN = 0,
};

/// EMF record header (always 8 bytes).
const EmfRecordHeader = struct {
    record_type: u32,
    record_size: u32,
};

/// EMF header record (EMR_HEADER).
const EmfHeader = struct {
    record_type: u32,
    record_size: u32,
    bounds_left: i32,
    bounds_top: i32,
    bounds_right: i32,
    bounds_bottom: i32,
    frame_left: i32,
    frame_top: i32,
    frame_right: i32,
    frame_bottom: i32,
    signature: u32, // 0x464D4520
    version: u32,
    bytes: u32,
    records: u32,
    hands: u16,
    description_len: u32,
    description_offset: u32,
    pal_entries: u32,
    device_width: u32,
    device_height: u32,
    device_units: u32,
    pixel_format: u32,
    open_gl: u32,
};

/// EMF record wrapper.
pub const EmfRecord = struct {
    record_type: u32,
    size: u32,
    data: []const u8,
};

/// EMF playback context.
pub const EmfPlayback = struct {
    records: []EmfRecord,
    bounds: struct { left: i32, top: i32, right: i32, bottom: i32 },
    device_extent: struct { width: i32, height: i32 },
    device_units: i32,
};

/// EMF object types.
pub const EmfObjectType = enum(u8) {
    brush = 0,
    pen = 1,
    font = 2,
    region = 3,
    palette = 4,
    null_brush = 5,
    null_pen = 6,
};

// ============================================================================
// Parsing

fn emfRecordTypeFromU32(t: u32) EmrRecordType {
    return @as(EmrRecordType, @enumFromInt(t));
}

/// Parses an EMF header from data.
fn parseEmfHeader(data: []const u8) mod.ImageError!EmfHeader {
    if (data.len < 80) return mod.ImageError.TruncatedData;

    return EmfHeader{
        .record_type = std.mem.readIntLittle(u32, data[0..4]),
        .record_size = std.mem.readIntLittle(u32, data[4..8]),
        .bounds_left = std.mem.readIntLittle(i32, data[8..12]),
        .bounds_top = std.mem.readIntLittle(i32, data[12..16]),
        .bounds_right = std.mem.readIntLittle(i32, data[16..20]),
        .bounds_bottom = std.mem.readIntLittle(i32, data[20..24]),
        .frame_left = std.mem.readIntLittle(i32, data[24..28]),
        .frame_top = std.mem.readIntLittle(i32, data[28..32]),
        .frame_right = std.mem.readIntLittle(i32, data[32..36]),
        .frame_bottom = std.mem.readIntLittle(i32, data[36..40]),
        .signature = std.mem.readIntLittle(u32, data[40..44]),
        .version = std.mem.readIntLittle(u32, data[44..48]),
        .bytes = std.mem.readIntLittle(u32, data[48..52]),
        .records = std.mem.readIntLittle(u32, data[52..56]),
        .hands = std.mem.readIntLittle(u16, data[56..58]),
        .description_len = std.mem.readIntLittle(u32, data[58..62]),
        .description_offset = std.mem.readIntLittle(u32, data[62..66]),
        .pal_entries = std.mem.readIntLittle(u32, data[66..70]),
        .device_width = std.mem.readIntLittle(u32, data[70..74]),
        .device_height = std.mem.readIntLittle(u32, data[74..78]),
        .device_units = std.mem.readIntLittle(u32, data[78..82]),
        .pixel_format = std.mem.readIntLittle(u32, data[82..86]),
        .open_gl = std.mem.readIntLittle(u32, data[86..90]),
    };
}

// ============================================================================
// EMF Object Table Parsing

/// Parses an EMR_CREATEBRUSHINDIRECT record.
fn parseCreateBrush(data: []const u8) mod.ImageError!struct {
    i_brush: u32,
    style: u32,
    color: u32,
    hatch: u32,
} {
    if (data.len < 16) return mod.ImageError.TruncatedData;
    return .{
        .i_brush = std.mem.readIntLittle(u32, data[0..4]),
        .style = std.mem.readIntLittle(u32, data[4..8]),
        .color = std.mem.readIntLittle(u32, data[8..12]),
        .hatch = std.mem.readIntLittle(u32, data[12..16]),
    };
}

/// Parses an EMR_CREATEPEN record.
fn parseCreatePen(data: []const u8) mod.ImageError!struct {
    i_pen: u32,
    style: u32,
    width: u32,
    color: u32,
} {
    if (data.len < 20) return mod.ImageError.TruncatedData;
    return .{
        .i_pen = std.mem.readIntLittle(u32, data[0..4]),
        .style = std.mem.readIntLittle(u32, data[4..8]),
        .width = std.mem.readIntLittle(u32, data[8..12]),
        .color = std.mem.readIntLittle(u32, data[12..16]),
    };
}

/// Parses an EMR_STRETCHDIBITS record.
fn parseStretchDibits(data: []const u8) mod.ImageError!struct {
    rcl_bounds_left: i32,
    rcl_bounds_top: i32,
    rcl_bounds_right: i32,
    rcl_bounds_bottom: i32,
    i_usage: u32,
    off_bmi_src: u32,
    cb_bmi_src: u32,
    off_bits_src: u32,
    cb_bits_src: u32,
} {
    if (data.len < 56) return mod.ImageError.TruncatedData;
    return .{
        .rcl_bounds_left = std.mem.readIntLittle(i32, data[0..4]),
        .rcl_bounds_top = std.mem.readIntLittle(i32, data[4..8]),
        .rcl_bounds_right = std.mem.readIntLittle(i32, data[8..12]),
        .rcl_bounds_bottom = std.mem.readIntLittle(i32, data[12..16]),
        .i_usage = std.mem.readIntLittle(u32, data[16..20]),
        .off_bmi_src = std.mem.readIntLittle(u32, data[20..24]),
        .cb_bmi_src = std.mem.readIntLittle(u32, data[24..28]),
        .off_bits_src = std.mem.readIntLittle(u32, data[28..32]),
        .cb_bits_src = std.mem.readIntLittle(u32, data[32..36]),
    };
}

// ============================================================================
// Public API

/// Decodes an EMF file. Returns playback context with all records.
/// Caller must free the records array.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!EmfPlayback {
    if (data.len < 8) return mod.ImageError.TruncatedData;

    // Validate EMF signature
    const hdr = parseEmfHeader(data) catch return mod.ImageError.InvalidSignature;

    if (hdr.signature != 0x464D4520) { // ' EMF'
        return mod.ImageError.InvalidSignature;
    }

    var records = std.ArrayListUnmanaged(EmfRecord){};
    errdefer records.deinit(allocator);

    var pos: usize = 0;
    while (pos + 8 <= data.len) {
        const record_type = std.mem.readIntLittle(u32, data[pos..pos + 4]);
        const record_size = std.mem.readIntLittle(u32, data[pos + 4..pos + 8]);

        if (record_size < 8) break;
        if (pos + @as(usize, record_size) > data.len) break;

        // Skip EMF+ records (type >= 0x40000000)
        if (record_type < 0x40000000) {
            const rec_data = data[pos + 8 .. pos + @as(usize, record_size)];
            try records.append(allocator, .{
                .record_type = record_type,
                .size = record_size,
                .data = rec_data,
            });
        }

        pos += @as(usize, record_size);
    }

    const recs = try records.toOwnedSlice(allocator);

    return EmfPlayback{
        .records = recs,
        .bounds = .{
            .left = hdr.bounds_left,
            .top = hdr.bounds_top,
            .right = hdr.bounds_right,
            .bottom = hdr.bounds_bottom,
        },
        .device_extent = .{
            .width = hdr.device_width,
            .height = hdr.device_height,
        },
        .device_units = hdr.device_units,
    };
}

/// Returns bounding box from EMF playback context.
pub fn getBounds(playback: *const EmfPlayback) struct { i32, i32, i32, i32 } {
    return playback.bounds;
}

/// Decoder interface entry.
pub const emfDecoder: mod.Decoder = .{
    .signature = &[1]u8{ 0x00 },
    .name = "EMF",
    .extensions = &.{ ".emf" },
    .decodeFn = struct {
        fn call(_: std.mem.Allocator, _: []const u8) mod.ImageError!mod.PixelBuffer {
            // EMF is a vector format — return a placeholder
            // Actual rendering requires a full GDI implementation
            return mod.ImageError.UnsupportedFormat;
        }
    }.call,
};
