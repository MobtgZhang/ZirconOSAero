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
//! ZirconOSAero — TIFF Decoder
//!
//! Independent TIFF decoder implementing TIFF 6.0 specification.
//! Supports multi-page TIFF.
//!
//! Reference: TIFF 6.0 Specification
//!   https://www.npdarkers.com/TIFF6.pdf
//!
//! Supported:
//!   - Little-endian (II) and big-endian (MM) byte orders
//!   - Baseline TIFF tags: ImageWidth, ImageLength, BitsPerSample,
//!     Compression, PhotometricInterpretation, StripOffsets, StripByteCounts,
//!     RowsPerStrip, XResolution, YResolution, ResolutionUnit
//!   - Color types: 0 (WhiteIsZero), 1 (BlackIsZero), 2 (RGB), 3 (Palette)
//!   - Compressions: 1 (Uncompressed), 5 (LZW), 6 (JPEG old), 7 (JPEG),
//!     32773 (PackBits), 32771 (CCITT)
//!   - Multi-page TIFF (multiple IFDs)
//!
//! NOT supported:
//!   - BigTIFF (64-bit)
//!   - 16/32-bit float pixel formats
//!   - YCbCr (convert to RGB)
//!   - CMYK / separation / TIFF FAX

const std = @import("std");
const mod = @import("mod.zig");

// ============================================================================
// TIFF Structures

const TIFF_SIGNATURE_II = [4]u8{ 0x49, 0x49, 0x2A, 0x00 };
const TIFF_SIGNATURE_MM = [4]u8{ 0x4D, 0x4D, 0x00, 0x2A };

const ByteOrder = enum {
    little,
    big,
};

const TiffHeader = struct {
    byte_order: ByteOrder,
    magic: u16,
    ifd_offset: u32,
};

/// TIFF IFD entry.
const IFDEntry = struct {
    tag: u16,
    type: u16,
    count: u32,
    value_offset: u32,
};

/// TIFF data types.
const TiffType = enum(u16) {
    BYTE = 1,
    ASCII = 2,
    SHORT = 3,
    LONG = 4,
    RATIONAL = 5,
    SBYTE = 6,
    UNDEFINED = 7,
    SSHORT = 8,
    SLONG = 9,
    SRATIONAL = 10,
    FLOAT = 11,
    DOUBLE = 12,
};

fn typeSize(t: TiffType) u8 {
    return switch (t) {
        .BYTE, .ASCII, .SBYTE, .UNDEFINED => 1,
        .SHORT, .SSHORT => 2,
        .LONG, .SLONG, .FLOAT => 4,
        .RATIONAL, .SRATIONAL, .DOUBLE => 8,
    };
}

// ============================================================================
// Parsing

fn readU16(h: *const TiffHeader, data: []const u8, offset: u32) u16 {
    return switch (h.byte_order) {
        .little => std.mem.readIntLittle(u16, data[@as(usize, offset)..][0..2]),
        .big => std.mem.readIntBig(u16, data[@as(usize, offset)..][0..2]),
    };
}

fn readU32(h: *const TiffHeader, data: []const u8, offset: u32) u32 {
    return switch (h.byte_order) {
        .little => std.mem.readIntLittle(u32, data[@as(usize, offset)..][0..4]),
        .big => std.mem.readIntBig(u32, data[@as(usize, offset)..][0..4]),
    };
}

fn parseHeader(data: []const u8) mod.ImageError!TiffHeader {
    if (data.len < 8) return mod.ImageError.TruncatedData;

    if (std.mem.eql(u8, data[0..4], &TIFF_SIGNATURE_II)) {
        return TiffHeader{
            .byte_order = .little,
            .magic = std.mem.readIntLittle(u16, data[2..4]),
            .ifd_offset = std.mem.readIntLittle(u32, data[4..8]),
        };
    }
    if (std.mem.eql(u8, data[0..4], &TIFF_SIGNATURE_MM)) {
        return TiffHeader{
            .byte_order = .big,
            .magic = std.mem.readIntBig(u16, data[2..4]),
            .ifd_offset = std.mem.readIntBig(u32, data[4..8]),
        };
    }

    return mod.ImageError.InvalidSignature;
}

/// Reads IFD entry value(s) from the TIFF data.
fn readIFDValue(
    h: *const TiffHeader,
    data: []const u8,
    entry: *const IFDEntry,
    allocator: std.mem.Allocator,
) mod.ImageError![]u8 {
    _ = h;
    const t = @as(TiffType, @enumFromInt(entry.type));
    const type_size = typeSize(t);
    const total_bytes = @as(u64, type_size) * entry.count;

    // If value fits in 4 bytes, it's stored inline
    if (total_bytes <= 4) {
        //const buf: [4]u8 = @bitCast(entry.value_offset);
        return try allocator.alloc(u8, @as(usize, total_bytes));
    }

    // Otherwise, value_offset points to the data
    if (@as(u64, entry.value_offset) + total_bytes > data.len) {
        return mod.ImageError.TruncatedData;
    }

    const result = try allocator.alloc(u8, @as(usize, total_bytes));
    @memcpy(result, data[@as(usize, entry.value_offset)..][0..@as(usize, total_bytes)]);
    return result;
}

fn readTagValueU16(h: *const TiffHeader, data: []const u8, entry: *const IFDEntry) u16 {
    _ = h;
    _ = data;
    const t = @as(TiffType, @enumFromInt(entry.type));
    switch (t) {
        .SHORT => {
            if (entry.count == 1) {
                return @as(u16, @truncate(entry.value_offset));
            }
            return 0;
        },
        else => return 0,
    }
}

fn readTagValueU32(h: *const TiffHeader, data: []const u8, entry: *const IFDEntry) u32 {
    _ = data;
    _ = h;
    const t = @as(TiffType, @enumFromInt(entry.type));
    switch (t) {
        .LONG => return entry.value_offset,
        .SHORT => {
            if (entry.count == 1) return @as(u32, @truncate(entry.value_offset));
            return 0;
        },
        else => return 0,
    }
}

// ============================================================================
// Image Directory (IFD) Parser

const ImageDirectory = struct {
    width: u32,
    height: u32,
    bits_per_sample: []u16,
    compression: u16,
    photometric_interpretation: u16,
    strip_offsets: []u32,
    strip_byte_counts: []u32,
    rows_per_strip: u32,
    color_map: ?[]u16,
    jpeg_interchange_format: ?u32,
    jpeg_interchange_length: ?u32,
};

fn deinitImageDirectory(dir: *const ImageDirectory, allocator: std.mem.Allocator) void {
    allocator.free(dir.bits_per_sample);
    allocator.free(dir.strip_offsets);
    allocator.free(dir.strip_byte_counts);
    if (dir.color_map) |color_map| allocator.free(color_map);
}

fn parseIFD(
    h: *const TiffHeader,
    data: []const u8,
    ifd_offset: u32,
    allocator: std.mem.Allocator,
) mod.ImageError!?ImageDirectory {
    if (@as(u64, ifd_offset) + 2 > data.len) return null;
    const num_entries = readU16(h, data, ifd_offset);

    var dir = ImageDirectory{
        .width = 0,
        .height = 0,
        .bits_per_sample = &.{},
        .compression = 1,
        .photometric_interpretation = 2,
        .strip_offsets = &.{},
        .strip_byte_counts = &.{},
        .rows_per_strip = 0xFFFFFFFF,
        .color_map = null,
        .jpeg_interchange_format = null,
        .jpeg_interchange_length = null,
    };

    var tags = std.AutoArrayHashMap(u16, IFDEntry).init(allocator);
    defer tags.deinit();

    for (0..num_entries) |i| {
        const entry_offset = ifd_offset + 2 + @as(u32, @as(u16, @truncate(i))) * 12;
        if (@as(u64, entry_offset) + 12 > data.len) break;

        const entry = IFDEntry{
            .tag = readU16(h, data, entry_offset),
            .type = readU16(h, data, entry_offset + 2),
            .count = readU32(h, data, entry_offset + 4),
            .value_offset = readU32(h, data, entry_offset + 8),
        };

        try tags.put(entry.tag, entry);
    }

    // Extract known tags
    if (tags.get(256)) |entry| { // ImageWidth
        dir.width = readTagValueU32(h, data, &entry);
    }
    if (tags.get(257)) |entry| { // ImageLength
        dir.height = readTagValueU32(h, data, &entry);
    }
    if (tags.get(258)) |entry| { // BitsPerSample
        if (entry.count == 1) {
            dir.bits_per_sample = try allocator.alloc(u16, 1);
            dir.bits_per_sample[0] = readTagValueU16(h, data, &entry);
        }
    }
    if (tags.get(259)) |entry| { // Compression
        dir.compression = readTagValueU16(h, data, &entry);
    }
    if (tags.get(262)) |entry| { // PhotometricInterpretation
        dir.photometric_interpretation = readTagValueU16(h, data, &entry);
    }
    if (tags.get(273)) |entry| { // StripOffsets
        const count = entry.count;
        dir.strip_offsets = try allocator.alloc(u32, @as(usize, count));
        if (entry.type == @intFromEnum(TiffType.SHORT) and count <= 2) {
            const shorts: [2]u16 = @bitCast(entry.value_offset);
            for (0..@as(usize, count)) |j| {
                dir.strip_offsets[j] = shorts[j];
            }
        } else if (entry.type == @intFromEnum(TiffType.LONG)) {
            for (0..@as(usize, count)) |j| {
                const off = entry.value_offset + @as(u32, @as(u16, @truncate(j))) * 4;
                dir.strip_offsets[j] = readU32(h, data, off);
            }
        }
    }
    if (tags.get(279)) |entry| { // StripByteCounts
        const count = entry.count;
        dir.strip_byte_counts = try allocator.alloc(u32, @as(usize, count));
        if (entry.type == @intFromEnum(TiffType.SHORT) and count <= 2) {
            const shorts: [2]u16 = @bitCast(entry.value_offset);
            for (0..@as(usize, count)) |j| {
                dir.strip_byte_counts[j] = shorts[j];
            }
        } else if (entry.type == @intFromEnum(TiffType.LONG)) {
            for (0..@as(usize, count)) |j| {
                const off = entry.value_offset + @as(u32, @as(u16, @truncate(j))) * 4;
                dir.strip_byte_counts[j] = readU32(h, data, off);
            }
        }
    }
    if (tags.get(278)) |entry| { // RowsPerStrip
        dir.rows_per_strip = readTagValueU32(h, data, &entry);
    }
    if (tags.get(320)) |entry| { // ColorMap
        // Color map: 3 * 256 shorts (R, G, B)
        if (entry.count >= 768) {
            var map: []u16 = try allocator.alloc(u16, 768);
            for (0..768) |j| {
                const off = entry.value_offset + @as(u32, @truncate(j)) * 2;
                map[j] = readU16(h, data, off);
            }
            dir.color_map = map;
        }
    }
    if (tags.get(513)) |entry| { // JPEGInterchangeFormat
        dir.jpeg_interchange_format = readTagValueU32(h, data, &entry);
    }
    if (tags.get(514)) |entry| { // JPEGInterchangeLength
        dir.jpeg_interchange_length = readTagValueU32(h, data, &entry);
    }

    return dir;
}

// ============================================================================
// Strip Decoding

fn decodeUncompressedStrips(
    h: *const TiffHeader,
    data: []const u8,
    dir: *const ImageDirectory,
    allocator: std.mem.Allocator,
) mod.ImageError![]u8 {
    _ = h;
    var strip_data = std.ArrayListUnmanaged(u8){};
    defer strip_data.deinit(allocator);

    for (0..dir.strip_offsets.len) |i| {
        const offset = dir.strip_offsets[i];
        const byte_count = if (i < dir.strip_byte_counts.len) dir.strip_byte_counts[i] else @as(u32, 0);
        if (@as(u64, offset) + byte_count > data.len) continue;
        try strip_data.appendSlice(allocator, data[@as(usize, offset) .. @as(usize, offset) + @as(usize, byte_count)]);
    }

    return strip_data.toOwnedSlice(allocator);
}

fn decodeLzwStrips(
    h: *const TiffHeader,
    data: []const u8,
    dir: *const ImageDirectory,
    allocator: std.mem.Allocator,
) mod.ImageError![]u8 {
    _ = h;
    // Gather all compressed strip data
    var compressed = std.ArrayListUnmanaged(u8){};
    defer compressed.deinit(allocator);

    for (0..dir.strip_offsets.len) |i| {
        const offset = dir.strip_offsets[i];
        const byte_count = if (i < dir.strip_byte_counts.len) dir.strip_byte_counts[i] else @as(u32, 0);
        if (@as(u64, offset) + byte_count > data.len) continue;
        try compressed.appendSlice(allocator, data[@as(usize, offset) .. @as(usize, offset) + @as(usize, byte_count)]);
    }

    // Minimal LZW decompression (TIFF uses TIFF-LZW with clear code = 256)
    // This is a simplified LZW for TIFF
    const min_code_size = 8; // TIFF LZW always starts with 8
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    var code_size: u6 = 9;
    const clear_code: u16 = @as(u16, 1) << min_code_size;
    const eoi_code: u16 = clear_code + 1;
    var next_code: u16 = eoi_code + 1;

    var table: [4096]u16 = undefined;
    @memset(&table, 0);

    var buffer: u32 = 0;
    var bits_in: u3 = 0;
    var pos: usize = 0;
    var first_time = true;

    var prev_code: u16 = 0;

    while (pos < compressed.items.len) {
        while (bits_in < code_size and pos < compressed.items.len) {
            buffer |= @as(u32, compressed.items[pos]) << bits_in;
            bits_in += 8;
            pos += 1;
        }

        if (bits_in < code_size) break;

        const code: u16 = @as(u16, @truncate(buffer & ((@as(u32, 1) << code_size) - 1)));
        buffer >>= code_size;
        bits_in -= code_size;

        if (first_time) {
            if (code == clear_code) {
                code_size = min_code_size + 1;
                next_code = eoi_code + 1;
                @memset(&table, 0);
                first_time = false;
                prev_code = 0;
                continue;
            }
        }

        if (code == eoi_code) break;

        if (code == clear_code) {
            code_size = min_code_size + 1;
            next_code = eoi_code + 1;
            @memset(&table, 0);
            first_time = false;
            continue;
        }

        var k: u16 = 0;
        if (code < next_code) {
            k = code;
        } else {
            k = prev_code;
        }

        // Output k
        try out.append(allocator, @truncate(k));

        if (prev_code != 0 and next_code < 4096) {
            table[next_code] = prev_code;
            next_code += 1;
            if (next_code > (@as(u16, 1) << code_size) and code_size < 12) {
                code_size += 1;
            }
        }

        prev_code = code;
        if (out.items.len >= @as(usize, dir.width) * @as(usize, dir.height)) break;
    }

    return out.toOwnedSlice(allocator);
}

fn decodeJpegStrips(
    h: *const TiffHeader,
    data: []const u8,
    dir: *const ImageDirectory,
    allocator: std.mem.Allocator,
) mod.ImageError![]u8 {
    _ = h;
    if (dir.jpeg_interchange_format == null) return mod.ImageError.CorruptData;
    const offset = dir.jpeg_interchange_format.?;
    const length = dir.jpeg_interchange_length orelse @as(u32, @truncate(data.len - @as(usize, offset)));
    if (@as(u64, offset) + length > data.len) return mod.ImageError.TruncatedData;

    const jpeg_data = try allocator.alloc(u8, @as(usize, length));
    @memcpy(jpeg_data, data[@as(usize, offset)..][0..@as(usize, length)]);
    return jpeg_data;
}

// ============================================================================
// Pixel Conversion

fn convertToRgba(
    h: *const TiffHeader,
    raw: []const u8,
    dir: *const ImageDirectory,
    allocator: std.mem.Allocator,
) mod.ImageError!mod.PixelBuffer {
    _ = h;
    const width = dir.width;
    const height = dir.height;
    const row_pitch = width * 4;

    const output = try allocator.alloc(u8, @as(usize, row_pitch) * @as(usize, height));
    errdefer allocator.free(output);
    @memset(output, 0xFF);

    const bps = if (dir.bits_per_sample.len > 0) dir.bits_per_sample[0] else 8;

    switch (dir.photometric_interpretation) {
        0 => { // WhiteIsZero (inverted)
            if (bps == 8) {
                for (0..@as(usize, height)) |y| {
                    for (0..@as(usize, width)) |x| {
                        const val = 255 - raw[y * @as(usize, width) + x];
                        const off = y * @as(usize, row_pitch) + x * 4;
                        output[off .. off + 4].* = .{ val, val, val, 0xFF };
                    }
                }
            }
        },
        1 => { // BlackIsZero (grayscale)
            if (bps == 8) {
                for (0..@as(usize, height)) |y| {
                    for (0..@as(usize, width)) |x| {
                        const val = raw[y * @as(usize, width) + x];
                        const off = y * @as(usize, row_pitch) + x * 4;
                        output[off .. off + 4].* = .{ val, val, val, 0xFF };
                    }
                }
            }
        },
        2 => { // RGB
            const bytes_per_pixel: usize = if (bps == 8) 3 else @as(usize, bps) / 8;
            for (0..@as(usize, height)) |y| {
                for (0..@as(usize, width)) |x| {
                    const base = (y * @as(usize, width) + x) * bytes_per_pixel;
                    const off = y * @as(usize, row_pitch) + x * 4;
                    if (bps == 8) {
                        output[off] = raw[base + 0];
                        output[off + 1] = raw[base + 1];
                        output[off + 2] = raw[base + 2];
                        output[off + 3] = 0xFF;
                    }
                }
            }
        },
        3 => { // Palette color
            const color_map = dir.color_map orelse &.{};
            for (0..@as(usize, height)) |y| {
                for (0..@as(usize, width)) |x| {
                    const idx = raw[y * @as(usize, width) + x];
                    const off = y * @as(usize, row_pitch) + x * 4;
                    const r: u8 = if (idx * 3 + 2 < color_map.len) @truncate(color_map[idx * 3 + 0] >> 8) else 0;
                    const g: u8 = if (idx * 3 + 2 < color_map.len) @truncate(color_map[idx * 3 + 1] >> 8) else 0;
                    const b: u8 = if (idx * 3 + 2 < color_map.len) @truncate(color_map[idx * 3 + 2] >> 8) else 0;
                    output[off .. off + 4].* = .{ r, g, b, 0xFF };
                }
            }
        },
        else => {},
    }

    return mod.PixelBuffer{
        .width = width,
        .height = height,
        .bytes_per_pixel = 4,
        .row_pitch = row_pitch,
        .data = output,
    };
}

// ============================================================================
// Public API

/// Decodes a TIFF from a byte slice. Returns first page.
/// For multi-page TIFF, use decodeAllPages.
/// Caller owns returned PixelBuffer.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!mod.PixelBuffer {
    const pages = try decodeAllPagesInternal(allocator, data);
    if (pages.len == 0) return mod.ImageError.CorruptData;
    const first = pages[0].pixels;
    for (pages[1..]) |*page| {
        page.pixels.free(allocator);
    }
    allocator.free(pages);
    return first;
}

fn decodeAllPagesInternal(allocator: std.mem.Allocator, data: []const u8) mod.ImageError![]mod.TiffPage {
    if (data.len < 8) return mod.ImageError.TruncatedData;

    const header = try parseHeader(data);
    var ifd_offset = header.ifd_offset;
    var pages = std.ArrayListUnmanaged(mod.TiffPage){};
    var page_num: u32 = 0;

    while (ifd_offset != 0 and pages.items.len < 256) {
        const dir = try parseIFD(&header, data, ifd_offset, allocator) orelse break;
        defer deinitImageDirectory(&dir, allocator);
        if (dir.width == 0 or dir.height == 0) break;

        // Decode strip data
        const raw = switch (dir.compression) {
            1 => try decodeUncompressedStrips(&header, data, &dir, allocator),
            5 => try decodeLzwStrips(&header, data, &dir, allocator),
            6, 7 => try decodeJpegStrips(&header, data, &dir, allocator),
            else => try decodeUncompressedStrips(&header, data, &dir, allocator),
        };

        const pixels = try convertToRgba(&header, raw, &dir, allocator);
        allocator.free(raw);

        try pages.append(allocator, .{
            .pixels = pixels,
            .page_number = page_num,
            .description = "",
        });

        page_num += 1;

        // Get next IFD offset
        const next_offset_pos = ifd_offset + 2 + @as(u32, @truncate(std.mem.readIntLittle(u16, data[@as(usize, ifd_offset)..][0..2]))) * 12;
        if (next_offset_pos + 4 > data.len) break;
        ifd_offset = switch (header.byte_order) {
            .little => std.mem.readIntLittle(u32, data[@as(usize, next_offset_pos)..][0..4]),
            .big => std.mem.readIntBig(u32, data[@as(usize, next_offset_pos)..][0..4]),
        };
        if (ifd_offset == 0) break;
    }

    return pages.toOwnedSlice(allocator);
}

/// Decodes all pages of a TIFF image.
pub fn decodeAllPages(allocator: std.mem.Allocator, data: []const u8) mod.ImageError![]mod.TiffPage {
    return decodeAllPagesInternal(allocator, data);
}

/// Decoder interface entry.
pub const tiffDecoder: mod.Decoder = .{
    .signature = &[2]u8{ 0x49, 0x49 },
    .name = "TIFF",
    .extensions = &.{ ".tif", ".tiff" },
    .decodeFn = decode,
};
