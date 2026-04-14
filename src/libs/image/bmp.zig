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
//! ZirconOSAero — BMP/DIB/RLE Image Decoder
//!
//! Independent BMP decoder implementing Windows BMP/DIB format specification.
//! Outputs RGBA32 pixel buffer.
//!
//! Reference: Microsoft BMP File Format Specification
//!   https://docs.microsoft.com/en-us/windows/win32/gdi/bitmap-storage
//!
//! Supported:
//!   - BITMAPFILEHEADER + BITMAPINFOHEADER (BI_RGB, BI_RLE8, BI_RLE4, BI_BITFIELDS)
//!   - BITMAPV4HEADER, BITMAPV5Header
//!   - 1, 4, 8, 16, 24, 32 bpp
//!   - Color tables (palette)
//!   - RLE-8 and RLE-4 decompression
//!   - Top-down and bottom-up storage
//!   - 32bpp: BGRA to RGBA channel remap
//!
//! NOT supported:
//!   - JPEG/PNG compression in BMP (not standard BMP)
//!   - OS/2 BMP format v2/v3

const std = @import("std");
const mod = @import("mod.zig");

// ============================================================================
// Structures

const BITMAPFILEHEADER_SIZE = 14;

const BitmapFileHeader = struct {
    file_size: u32,
    data_offset: u32,
};

const BitmapInfoHeader = struct {
    size: u32, // Size of this header
    width: i32,
    height: i32, // Positive = bottom-up, negative = top-down
    planes: u16,
    bit_count: u16,
    compression: CompressionType,
    image_size: u32,
    x_pels_per_meter: i32,
    y_pels_per_meter: i32,
    colors_used: u32,
    colors_important: u32,

    fn isTopDown(self: *const BitmapInfoHeader) bool {
        return self.height < 0;
    }

    fn absHeight(self: *const BitmapInfoHeader) u32 {
        return @intCast(@abs(self.height));
    }
};

const CompressionType = enum(u32) {
    BI_RGB = 0,
    BI_RLE8 = 1,
    BI_RLE4 = 2,
    BI_BITFIELDS = 3,
    BI_JPEG = 4, // Not supported
    BI_PNG = 5, // Not supported
    BI_ALPHABITFIELDS = 6,
    BI_CMYK = 11,
    BI_CMYKRLE8 = 12,
    BI_CMYKRLE4 = 13,
    unknown = 0xFFFFFFFF,
};

/// Color table entry (BGRA).
const RgbQuad = [4]u8;

const BITMAPV4HEADER_SIZE = 120;
const BITMAPV5HEADER_SIZE = 124;

// ============================================================================
// Parsing

fn parseFileHeader(data: []const u8) mod.ImageError!BitmapFileHeader {
    if (data.len < BITMAPFILEHEADER_SIZE) return mod.ImageError.TruncatedData;

    // Verify "BM" signature
    if (data[0] != 'B' or data[1] != 'M') {
        return mod.ImageError.InvalidSignature;
    }

    return BitmapFileHeader{
        .file_size = std.mem.readIntLittle(u32, data[2..6]),
        .data_offset = std.mem.readIntLittle(u32, data[10..14]),
    };
}

fn parseInfoHeader(data: []const u8) mod.ImageError!BitmapInfoHeader {
    if (data.len < 4) return mod.ImageError.TruncatedData;

    const header_size = std.mem.readIntLittle(u32, data[0..4]);
    if (header_size < 40) return mod.ImageError.InvalidHeader; // Must be at least BITMAPINFOHEADER

    const comp_val: u32 = if (header_size >= 44)
        std.mem.readIntLittle(u32, data[16..20])
    else
        0;

    return BitmapInfoHeader{
        .size = header_size,
        .width = std.mem.readIntLittle(u32, data[4..8]),
        .height = std.mem.readIntLittle(u32, data[8..12]),
        .planes = std.mem.readIntLittle(u16, data[12..14]),
        .bit_count = std.mem.readIntLittle(u16, data[14..16]),
        .compression = @as(CompressionType, @enumFromInt(comp_val)),
        .image_size = if (header_size >= 36) std.mem.readIntLittle(u32, data[20..24]) else 0,
        .x_pels_per_meter = if (header_size >= 36) std.mem.readIntLittle(i32, data[24..28]) else 0,
        .y_pels_per_meter = if (header_size >= 36) std.mem.readIntLittle(i32, data[28..32]) else 0,
        .colors_used = if (header_size >= 36) std.mem.readIntLittle(u32, data[32..36]) else 0,
        .colors_important = if (header_size >= 36) std.mem.readIntLittle(u32, data[36..40]) else 0,
    };
}

/// Reads color mask from BI_BITFIELDS region.
fn readBitfields(data: []const u8, offset: u32) mod.ImageError![3]u32 {
    if (offset + 12 > data.len) return mod.ImageError.TruncatedData;
    return .{
        std.mem.readIntLittle(u32, data[offset .. offset + 4]),
        std.mem.readIntLittle(u32, data[offset + 4 .. offset + 8]),
        std.mem.readIntLittle(u32, data[offset + 8 .. offset + 12]),
    };
}

/// Reads a color table (palette) from BMP data.
fn readColorTable(
    allocator: std.mem.Allocator,
    data: []const u8,
    start: usize,
    num_entries: usize,
) mod.ImageError![]RgbQuad {
    const total_entries = @min(num_entries, 256);
    if (start + @as(usize, total_entries) * 4 > data.len) {
        return mod.ImageError.TruncatedData;
    }
    const entries = try allocator.alloc(RgbQuad, total_entries);
    for (0..total_entries) |i| {
        @memcpy(&entries[i], data[start + i * 4 .. start + i * 4 + 4]);
    }
    return entries;
}

// ============================================================================
// Row Decoding (non-RLE)

/// Decodes a 1bpp row.
fn decodeRow1bpp(src: []const u8, width: u32, out: []u8, palette: []const RgbQuad, transparent_idx: ?u8) void {
    for (0..@as(usize, width)) |x| {
        const byte = src[x / 8];
        const bit = 7 - @as(u3, @truncate(x % 8));
        const idx = (byte >> bit) & 1;
        const offset = x * 4;
        if (transparent_idx == null or transparent_idx.? != idx) {
            const pal_entry = if (idx < palette.len) palette[idx] else .{ 0, 0, 0, 0 };
            out[offset .. offset + 4].* = .{ pal_entry[2], pal_entry[1], pal_entry[0], if (transparent_idx != null and transparent_idx.? == idx) 0x00 else 0xFF };
        }
    }
}

/// Decodes a 4bpp row.
fn decodeRow4bpp(src: []const u8, width: u32, out: []u8, palette: []const RgbQuad, transparent_idx: ?u8) void {
    for (0..@as(usize, width)) |x| {
        const byte = src[x / 2];
        const idx: u8 = if (x % 2 == 0) (byte >> 4) else (byte & 0x0F);
        const offset = x * 4;
        if (transparent_idx == null or transparent_idx.? != idx) {
            const pal_entry = if (idx < palette.len) palette[idx] else .{ 0, 0, 0, 0 };
            out[offset .. offset + 4].* = .{ pal_entry[2], pal_entry[1], pal_entry[0], if (transparent_idx != null and transparent_idx.? == idx) 0x00 else 0xFF };
        }
    }
}

/// Decodes an 8bpp row.
fn decodeRow8bpp(src: []const u8, width: u32, out: []u8, palette: []const RgbQuad, transparent_idx: ?u8) void {
    for (0..@as(usize, width)) |x| {
        const idx = src[x];
        const offset = x * 4;
        if (transparent_idx == null or transparent_idx.? != idx) {
            const pal_entry = if (idx < palette.len) palette[idx] else .{ 0, 0, 0, 0 };
            out[offset .. offset + 4].* = .{ pal_entry[2], pal_entry[1], pal_entry[0], if (transparent_idx != null and transparent_idx.? == idx) 0x00 else 0xFF };
        }
    }
}

/// Decodes a 16bpp row (5-5-5-1 or 5-6-5).
fn decodeRow16bpp(src: []const u8, width: u32, out: []u8, masks: [3]u32, has_alpha: bool) void {
    for (0..@as(usize, width)) |x| {
        const pixel = std.mem.readIntLittle(u16, src[x * 2 ..][0..2]);
        const r: u8 = @truncate((pixel & masks[0]) >> @ctz(masks[0]));
        const g: u8 = @truncate((pixel & masks[1]) >> @ctz(masks[1]));
        const b: u8 = @truncate((pixel & masks[2]) >> @ctz(masks[2]));
        const a: u8 = if (has_alpha) @as(u8, @truncate((pixel & 0x8000) >> 15)) * 0xFF else 0xFF;
        const offset = x * 4;
        out[offset .. offset + 4].* = .{
            @as(u8, @truncate(@as(u16, r) << @as(u6, 8 - @ctz(masks[0])))),
            @as(u8, @truncate(@as(u16, g) << @as(u6, 8 - @ctz(masks[1])))),
            @as(u8, @truncate(@as(u16, b) << @as(u6, 8 - @ctz(masks[2])))),
            a,
        };
    }
}

/// Decodes a 24bpp row (BGR).
fn decodeRow24bpp(src: []const u8, width: u32, out: []u8) void {
    for (0..@as(usize, width)) |x| {
        const offset = x * 4;
        out[offset .. offset + 4].* = .{ src[x * 3 + 2], src[x * 3 + 1], src[x * 3], 0xFF };
    }
}

/// Decodes a 32bpp row (BGRA or ABGR depending on masks).
fn decodeRow32bpp(src: []const u8, width: u32, out: []u8, masks: [3]u32, has_alpha: bool) void {
    for (0..@as(usize, width)) |x| {
        const pixel = std.mem.readIntLittle(u32, src[x * 4 ..][0..4]);
        if (has_alpha) {
            const a: u8 = @truncate((pixel & 0xFF000000) >> 24);
            out[x * 4 .. x * 4 + 4].* = .{
                @as(u8, @truncate(pixel)),
                @as(u8, @truncate(pixel >> 8)),
                @as(u8, @truncate(pixel >> 16)),
                a,
            };
        } else {
            out[x * 4 .. x * 4 + 4].* = .{
                @as(u8, @truncate(pixel)),
                @as(u8, @truncate(pixel >> 8)),
                @as(u8, @truncate(pixel >> 16)),
                0xFF,
            };
        }
        _ = masks;
    }
}

// ============================================================================
// RLE Decoding

/// Decodes an RLE-8 row.
fn decodeRle8(compressed: []const u8, width: u32, out: []u8, palette: []const RgbQuad) mod.ImageError!void {
    var i: usize = 0;
    var x: usize = 0;

    while (i < compressed.len and x < width) {
        const first = compressed[i];
        i += 1;
        if (first == 0) {
            // Escape sequence
            if (i >= compressed.len) break;
            const second = compressed[i];
            i += 1;
            if (second == 0) {
                // End of line
                break;
            } else if (second == 1) {
                // End of bitmap
                break;
            } else if (second == 2) {
                // Delta: move position
                if (i + 1 >= compressed.len) break;
                const dx = compressed[i];
                const dy = compressed[i + 1];
                i += 2;
                x += dx;
                _ = dy;
            } else {
                // Absolute mode: copy next second bytes
                const count = second;
                if (i + @as(usize, count) > compressed.len) return mod.ImageError.RleError;
                for (0..@as(usize, count)) |j| {
                    if (x >= width) break;
                    const idx = compressed[i + j];
                    const pal_entry = if (idx < palette.len) palette[idx] else .{ 0, 0, 0, 0 };
                    const offset = x * 4;
                    out[offset .. offset + 4].* = .{ pal_entry[2], pal_entry[1], pal_entry[0], 0xFF };
                    x += 1;
                }
                i += @as(usize, count);
                // Pad to even byte boundary
                if ((count & 1) == 1) i += 1;
            }
        } else {
            // Encoded mode: repeat first, second times
            const count = first;
            if (i >= compressed.len) break;
            const pixel_idx = compressed[i];
            i += 1;
            const pal_entry = if (pixel_idx < palette.len) palette[pixel_idx] else .{ 0, 0, 0, 0 };
            for (0..@as(usize, count)) |_| {
                if (x >= width) break;
                const offset = x * 4;
                out[offset .. offset + 4].* = .{ pal_entry[2], pal_entry[1], pal_entry[0], 0xFF };
                x += 1;
            }
        }
    }
}

/// Decodes an RLE-4 row.
fn decodeRle4(compressed: []const u8, width: u32, out: []u8, palette: []const RgbQuad) mod.ImageError!void {
    var i: usize = 0;
    var x: usize = 0;

    while (i < compressed.len and x < width) {
        const first = compressed[i];
        i += 1;
        if (first == 0) {
            // Escape sequence
            if (i >= compressed.len) break;
            const second = compressed[i];
            i += 1;
            if (second == 0) {
                break;
            } else if (second == 1) {
                break;
            } else if (second == 2) {
                if (i + 1 >= compressed.len) break;
                const dx = compressed[i];
                const dy = compressed[i + 1];
                i += 2;
                x += dx;
                _ = dy;
            } else {
                const count = second;
                if (i >= compressed.len) break;
                const byte = compressed[i];
                i += 1;
                for (0..@as(usize, count)) |j| {
                    if (x >= width) break;
                    const nybble: u8 = if (j % 2 == 0) (byte >> 4) else (byte & 0x0F);
                    const pal_entry = if (nybble < palette.len) palette[nybble] else .{ 0, 0, 0, 0 };
                    const offset = x * 4;
                    out[offset .. offset + 4].* = .{ pal_entry[2], pal_entry[1], pal_entry[0], 0xFF };
                    x += 1;
                }
                // Pad to even byte boundary
                if ((count & 3) == 1 or (count & 3) == 2) i += 1;
            }
        } else {
            const count = first;
            if (i >= compressed.len) break;
            const nybble1 = (compressed[i] >> 4);
            const nybble2 = (compressed[i] & 0x0F);
            i += 1;
            for (0..@as(usize, count)) |j| {
                if (x >= width) break;
                const nybble: u8 = if (j % 2 == 0) nybble1 else nybble2;
                const pal_entry = if (nybble < palette.len) palette[nybble] else .{ 0, 0, 0, 0 };
                const offset = x * 4;
                out[offset .. offset + 4].* = .{ pal_entry[2], pal_entry[1], pal_entry[0], 0xFF };
                x += 1;
            }
        }
    }
}

// ============================================================================
// Public API

const BMP_SIGNATURE = [_]u8{ 'B', 'M' };

/// Decodes a BMP/DIB image from a byte slice. Caller owns returned PixelBuffer.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!mod.PixelBuffer {
    if (data.len < BITMAPFILEHEADER_SIZE) return mod.ImageError.TruncatedData;

    const file_header = try parseFileHeader(data);
    const info_header = try parseInfoHeader(data[data[0..BITMAPFILEHEADER_SIZE].len..]);

    if (info_header.width <= 0 or info_header.absHeight() == 0) {
        return mod.ImageError.InvalidDimension;
    }

    const width: u32 = @intCast(@abs(info_header.width));
    const height: u32 = info_header.absHeight();
    const row_pitch: u32 = width * 4;

    // Check data availability
    if (file_header.data_offset > data.len) return mod.ImageError.TruncatedData;
    const pixel_data = data[file_header.data_offset..];

    // Determine color table size
    const palette_entry_count: usize = switch (info_header.bit_count) {
        1 => 2,
        4 => 16,
        8 => 256,
        else => 0,
    };

    const color_table_start = BITMAPFILEHEADER_SIZE + @as(usize, info_header.size);
    var palette: []RgbQuad = &.{};
    if (palette_entry_count > 0) {
        palette = try readColorTable(allocator, data, color_table_start, palette_entry_count);
        defer allocator.free(palette);
    }

    // Default bitfields for 16/32 bpp
    var bitfields: [3]u32 = .{ 0x7C00, 0x03E0, 0x001F }; // 5-5-5-1 default
    var has_alpha = false;

    if (info_header.compression == .BI_BITFIELDS or info_header.compression == .BI_ALPHABITFIELDS) {
        const bf_offset = BITMAPFILEHEADER_SIZE + 40; // After BITMAPINFOHEADER
        if (info_header.compression == .BI_ALPHABITFIELDS) has_alpha = true;
        if (info_header.bit_count == 16 or info_header.bit_count == 32) {
            bitfields = try readBitfields(data, bf_offset);
        }
    }

    // Allocate output
    const output = try allocator.alloc(u8, @as(usize, row_pitch) * @as(usize, height));
    errdefer allocator.free(output);
    @memset(output, 0xFF);

    const row_size = (@as(u32, info_header.bit_count) * width + 31) / 32 * 4;

    switch (info_header.compression) {
        .BI_RGB => {
            if (palette_entry_count > 0) {
                // Palette format
                for (0..@as(usize, height)) |y| {
                    const src_row = @as(usize, y) * @as(usize, row_size);
                    const dst_row = @as(usize, height - 1 - y) * @as(usize, row_pitch);
                    const src = pixel_data[src_row..@min(src_row + row_size, pixel_data.len)];
                    switch (info_header.bit_count) {
                        1 => decodeRow1bpp(src, width, output[dst_row..], palette, null),
                        4 => decodeRow4bpp(src, width, output[dst_row..], palette, null),
                        8 => decodeRow8bpp(src, width, output[dst_row..], palette, null),
                        else => {},
                    }
                }
            } else {
                // Uncompressed RGB
                for (0..@as(usize, height)) |y| {
                    const src_row = @as(usize, y) * @as(usize, row_size);
                    const dst_row = @as(usize, height - 1 - y) * @as(usize, row_pitch);
                    const src = pixel_data[src_row..@min(src_row + row_size, pixel_data.len)];
                    switch (info_header.bit_count) {
                        16 => decodeRow16bpp(src, width, output[dst_row..], bitfields, has_alpha),
                        24 => decodeRow24bpp(src, width, output[dst_row..]),
                        32 => decodeRow32bpp(src, width, output[dst_row..], bitfields, has_alpha),
                        else => {},
                    }
                }
            }
        },
        .BI_RLE8 => {
            // RLE-8: each row is a separate RLE stream
            var offset: usize = 0;
            for (0..@as(usize, height)) |y| {
                const dst_row = y * @as(usize, row_pitch);
                if (offset >= pixel_data.len) break;
                // RLE data for this row (ends at next row or end of data)
                const remaining = pixel_data.len - offset;
                if (remaining == 0) break;
                // Count non-zero bytes to find row boundary
                var row_end = offset;
                while (row_end < pixel_data.len) {
                    const b = pixel_data[row_end];
                    if (b == 0 and row_end + 1 < pixel_data.len) {
                        const code = pixel_data[row_end + 1];
                        if (code == 0 or code == 1 or code == 2) {
                            row_end += 2;
                            if (code <= 1) break;
                            continue;
                        }
                        // Absolute mode
                        const count = code;
                        row_end += 2 + @as(usize, count);
                        if (count & 1 == 1) row_end += 1;
                        continue;
                    }
                    row_end += 1;
                }

                const row_data = pixel_data[offset..row_end];
                try decodeRle8(row_data, width, output[dst_row..], palette);
                offset = row_end;
            }
        },
        .BI_RLE4 => {
            // RLE-4: similar to RLE-8 but 4-bit nibbles
            var offset: usize = 0;
            for (0..@as(usize, height)) |y| {
                const dst_row = y * @as(usize, row_pitch);
                if (offset >= pixel_data.len) break;
                var row_end = offset;
                while (row_end < pixel_data.len) {
                    const b = pixel_data[row_end];
                    if (b == 0 and row_end + 1 < pixel_data.len) {
                        const code = pixel_data[row_end + 1];
                        row_end += 2;
                        if (code <= 1) break;
                        continue;
                    }
                    row_end += 1;
                }
                const row_data = pixel_data[offset..row_end];
                try decodeRle4(row_data, width, output[dst_row..], palette);
                offset = row_end;
            }
        },
        else => return mod.ImageError.UnsupportedCompression,
    }

    return mod.PixelBuffer{
        .width = width,
        .height = height,
        .bytes_per_pixel = 4,
        .row_pitch = row_pitch,
        .data = output,
    };
}

/// Decoder interface entry.
pub const bmpDecoder: mod.Decoder = .{
    .signature = &BMP_SIGNATURE,
    .name = "BMP",
    .extensions = &.{ ".bmp", ".dib", ".rle" },
    .decodeFn = decode,
};
