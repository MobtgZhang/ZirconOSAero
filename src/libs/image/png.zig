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
//! ZirconOSAero — PNG Image Decoder
//!
//! Independent PNG decoder implementing RFC 2083 / ISO/IEC 15948.
//! Outputs RGBA32 pixel buffers in top-down row order.

const std = @import("std");
const mod = @import("mod.zig");

pub const PngError = mod.ImageError;
pub const PixelBuffer = mod.PixelBuffer;

const PNG_SIGNATURE = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

const CHUNK_IHDR: u32 = 0x49484452;
const CHUNK_PLTE: u32 = 0x504C5445;
const CHUNK_IDAT: u32 = 0x49444154;
const CHUNK_IEND: u32 = 0x49454E44;
const CHUNK_tRNS: u32 = 0x74524E53;

const PaletteEntry = [4]u8;

const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

const IhdrData = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,
};

const Transparency = union(enum) {
    none,
    grayscale: u16,
    rgb: [3]u16,
};

const ChunkState = struct {
    idat: []u8,
    palette: ?[]PaletteEntry,
    transparency: Transparency,

    fn deinit(self: *ChunkState, allocator: std.mem.Allocator) void {
        allocator.free(self.idat);
        if (self.palette) |palette| allocator.free(palette);
    }
};

const Adam7Pass = struct {
    start_x: u32,
    start_y: u32,
    step_x: u32,
    step_y: u32,
};

const adam7_passes = [_]Adam7Pass{
    .{ .start_x = 0, .start_y = 0, .step_x = 8, .step_y = 8 },
    .{ .start_x = 4, .start_y = 0, .step_x = 8, .step_y = 8 },
    .{ .start_x = 0, .start_y = 4, .step_x = 4, .step_y = 8 },
    .{ .start_x = 2, .start_y = 0, .step_x = 4, .step_y = 4 },
    .{ .start_x = 0, .start_y = 2, .step_x = 2, .step_y = 4 },
    .{ .start_x = 1, .start_y = 0, .step_x = 2, .step_y = 2 },
    .{ .start_x = 0, .start_y = 1, .step_x = 1, .step_y = 2 },
};

fn readBeU16(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | @as(u16, buf[off + 1]);
}

fn readBeU32(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) |
        (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) |
        @as(u32, buf[off + 3]);
}

fn chunkType(data: []const u8) u32 {
    return readBeU32(data, 0);
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const ai = @as(i32, a);
    const bi = @as(i32, b);
    const ci = @as(i32, c);
    const p = ai + bi - ci;
    const pa = @abs(p - ai);
    const pb = @abs(p - bi);
    const pc = @abs(p - ci);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn validateBitDepth(color_type: ColorType, bit_depth: u8) bool {
    return switch (color_type) {
        .grayscale => switch (bit_depth) {
            1, 2, 4, 8, 16 => true,
            else => false,
        },
        .rgb => bit_depth == 8 or bit_depth == 16,
        .indexed => switch (bit_depth) {
            1, 2, 4, 8 => true,
            else => false,
        },
        .grayscale_alpha, .rgba => bit_depth == 8 or bit_depth == 16,
    };
}

fn parseIhdr(data: []const u8) PngError!IhdrData {
    if (data.len < 33) return PngError.TruncatedData;
    if (!std.mem.eql(u8, data[0..8], &PNG_SIGNATURE)) return PngError.InvalidSignature;
    if (readBeU32(data, 8) != 13) return PngError.InvalidHeader;
    if (chunkType(data[12..16]) != CHUNK_IHDR) return PngError.InvalidHeader;

    const raw_color_type = data[25];
    const color_type: ColorType = switch (raw_color_type) {
        0 => .grayscale,
        2 => .rgb,
        3 => .indexed,
        4 => .grayscale_alpha,
        6 => .rgba,
        else => return PngError.UnsupportedFormat,
    };

    const ihdr = IhdrData{
        .width = readBeU32(data, 16),
        .height = readBeU32(data, 20),
        .bit_depth = data[24],
        .color_type = color_type,
        .compression_method = data[26],
        .filter_method = data[27],
        .interlace_method = data[28],
    };

    if (ihdr.width == 0 or ihdr.height == 0) return PngError.InvalidDimension;
    if (!validateBitDepth(ihdr.color_type, ihdr.bit_depth)) return PngError.UnsupportedFormat;
    if (ihdr.compression_method != 0 or ihdr.filter_method != 0) return PngError.UnsupportedFormat;
    if (ihdr.interlace_method != 0 and ihdr.interlace_method != 1) return PngError.UnsupportedFormat;

    return ihdr;
}

fn bitsPerPixel(ihdr: IhdrData) usize {
    const channels: usize = switch (ihdr.color_type) {
        .grayscale => 1,
        .rgb => 3,
        .indexed => 1,
        .grayscale_alpha => 2,
        .rgba => 4,
    };
    return channels * ihdr.bit_depth;
}

fn filterBytesPerPixel(ihdr: IhdrData) usize {
    return switch (ihdr.color_type) {
        .grayscale => if (ihdr.bit_depth < 8) 1 else @as(usize, ihdr.bit_depth) / 8,
        .rgb => 3 * (@as(usize, ihdr.bit_depth) / 8),
        .indexed => 1,
        .grayscale_alpha => 2 * (@as(usize, ihdr.bit_depth) / 8),
        .rgba => 4 * (@as(usize, ihdr.bit_depth) / 8),
    };
}

fn rowByteCount(width: u32, ihdr: IhdrData) PngError!usize {
    const bits = std.math.mul(usize, width, bitsPerPixel(ihdr)) catch return PngError.InvalidDimension;
    return bits / 8 + @intFromBool(bits % 8 != 0);
}

fn decodeZlib(allocator: std.mem.Allocator, compressed: []const u8) PngError![]u8 {
    var reader: std.Io.Reader = .fixed(compressed);
    var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);

    decompress.reader.appendRemainingUnlimited(allocator, &output) catch return PngError.ZlibError;
    return output.toOwnedSlice(allocator) catch return PngError.OutOfMemory;
}

fn decodePalette(chunk_data: []const u8, allocator: std.mem.Allocator) PngError![]PaletteEntry {
    if (chunk_data.len == 0 or chunk_data.len % 3 != 0) return PngError.InvalidPalette;
    const count = chunk_data.len / 3;
    if (count > 256) return PngError.InvalidPalette;

    const palette = allocator.alloc(PaletteEntry, count) catch return PngError.OutOfMemory;
    errdefer allocator.free(palette);

    for (0..count) |i| {
        palette[i] = .{
            chunk_data[i * 3],
            chunk_data[i * 3 + 1],
            chunk_data[i * 3 + 2],
            0xFF,
        };
    }
    return palette;
}

fn applyTrns(
    chunk_data: []const u8,
    ihdr: IhdrData,
    palette: ?[]PaletteEntry,
) PngError!Transparency {
    return switch (ihdr.color_type) {
        .indexed => blk: {
            const pal = palette orelse return PngError.InvalidPalette;
            for (0..@min(chunk_data.len, pal.len)) |i| {
                pal[i][3] = chunk_data[i];
            }
            break :blk .none;
        },
        .grayscale => blk: {
            if (chunk_data.len != 2) return PngError.InvalidChunk;
            break :blk .{ .grayscale = readBeU16(chunk_data, 0) };
        },
        .rgb => blk: {
            if (chunk_data.len != 6) return PngError.InvalidChunk;
            break :blk .{
                .rgb = .{
                    readBeU16(chunk_data, 0),
                    readBeU16(chunk_data, 2),
                    readBeU16(chunk_data, 4),
                },
            };
        },
        .grayscale_alpha, .rgba => return PngError.InvalidChunk,
    };
}

fn collectChunks(allocator: std.mem.Allocator, data: []const u8, ihdr: IhdrData) PngError!ChunkState {
    var pos: usize = 8;
    var idat_list = std.ArrayListUnmanaged(u8){};
    defer idat_list.deinit(allocator);

    var palette: ?[]PaletteEntry = null;
    errdefer if (palette) |p| allocator.free(p);

    var transparency: Transparency = .none;
    var saw_trns = false;
    var saw_iend = false;

    while (pos + 12 <= data.len) {
        const length = readBeU32(data, pos);
        const chunk_data_start = pos + 8;
        const chunk_data_end = chunk_data_start + length;
        const crc_end = chunk_data_end + 4;
        if (crc_end > data.len) return PngError.TruncatedData;

        const ct = chunkType(data[pos + 4 .. pos + 8]);
        const chunk_data = data[chunk_data_start..chunk_data_end];
        const expected_crc = readBeU32(data, chunk_data_end);
        const actual_crc = std.hash.Crc32.hash(data[pos + 4 .. chunk_data_end]);
        if (actual_crc != expected_crc) return PngError.InvalidChunk;

        switch (ct) {
            CHUNK_IHDR => {
                if (pos != 8) return PngError.InvalidChunk;
            },
            CHUNK_PLTE => {
                if (palette != null) return PngError.InvalidChunk;
                palette = try decodePalette(chunk_data, allocator);
            },
            CHUNK_tRNS => {
                if (saw_trns) return PngError.InvalidChunk;
                transparency = try applyTrns(chunk_data, ihdr, palette);
                saw_trns = true;
            },
            CHUNK_IDAT => {
                try idat_list.appendSlice(allocator, chunk_data);
            },
            CHUNK_IEND => {
                saw_iend = true;
                break;
            },
            else => {},
        }

        pos = crc_end;
    }

    if (!saw_iend or idat_list.items.len == 0) return PngError.CorruptData;
    if (ihdr.color_type == .indexed and palette == null) return PngError.InvalidPalette;

    const idat = allocator.alloc(u8, idat_list.items.len) catch return PngError.OutOfMemory;
    @memcpy(idat, idat_list.items);
    return .{
        .idat = idat,
        .palette = palette,
        .transparency = transparency,
    };
}

fn unpackPackedSample(data: []const u8, bit_depth: u8, index: usize) u8 {
    const bit_index = index * bit_depth;
    const byte_index = bit_index / 8;
    const intra_byte = @as(u8, @intCast(bit_index % 8));
    const shift: u3 = @intCast(8 - bit_depth - intra_byte);
    const mask: u8 = @intCast((@as(u16, 1) << @intCast(bit_depth)) - 1);
    return (data[byte_index] >> shift) & mask;
}

fn sampleToU8(sample: u16, bit_depth: u8) u8 {
    return switch (bit_depth) {
        8 => @intCast(sample),
        16 => @intCast(sample >> 8),
        else => blk: {
            const max_sample = (@as(u32, 1) << @intCast(bit_depth)) - 1;
            break :blk @intCast((@as(u32, sample) * 255 + max_sample / 2) / max_sample);
        },
    };
}

fn expandRowToRgba(
    raw_row: []const u8,
    width: u32,
    ihdr: IhdrData,
    palette: ?[]const PaletteEntry,
    transparency: Transparency,
    rgba: []u8,
) PngError!void {
    if (rgba.len < @as(usize, width) * 4) return PngError.CorruptData;

    switch (ihdr.color_type) {
        .grayscale => switch (ihdr.bit_depth) {
            1, 2, 4 => {
                for (0..@as(usize, width)) |x| {
                    const sample = @as(u16, unpackPackedSample(raw_row, ihdr.bit_depth, x));
                    const alpha: u8 = switch (transparency) {
                        .none => 0xFF,
                        .grayscale => |key| if (key == sample) 0 else 0xFF,
                        .rgb => 0xFF,
                    };
                    const gray = sampleToU8(sample, ihdr.bit_depth);
                    const dst = x * 4;
                    rgba[dst + 0] = gray;
                    rgba[dst + 1] = gray;
                    rgba[dst + 2] = gray;
                    rgba[dst + 3] = alpha;
                }
            },
            8 => {
                for (0..@as(usize, width)) |x| {
                    const sample = @as(u16, raw_row[x]);
                    const alpha: u8 = switch (transparency) {
                        .none => 0xFF,
                        .grayscale => |key| if (key == sample) 0 else 0xFF,
                        .rgb => 0xFF,
                    };
                    const dst = x * 4;
                    rgba[dst + 0] = raw_row[x];
                    rgba[dst + 1] = raw_row[x];
                    rgba[dst + 2] = raw_row[x];
                    rgba[dst + 3] = alpha;
                }
            },
            16 => {
                for (0..@as(usize, width)) |x| {
                    const sample = readBeU16(raw_row, x * 2);
                    const alpha: u8 = switch (transparency) {
                        .none => 0xFF,
                        .grayscale => |key| if (key == sample) 0 else 0xFF,
                        .rgb => 0xFF,
                    };
                    const gray = sampleToU8(sample, 16);
                    const dst = x * 4;
                    rgba[dst + 0] = gray;
                    rgba[dst + 1] = gray;
                    rgba[dst + 2] = gray;
                    rgba[dst + 3] = alpha;
                }
            },
            else => return PngError.UnsupportedFormat,
        },
        .rgb => switch (ihdr.bit_depth) {
            8 => {
                for (0..@as(usize, width)) |x| {
                    const src = x * 3;
                    const r = raw_row[src + 0];
                    const g = raw_row[src + 1];
                    const b = raw_row[src + 2];
                    const alpha: u8 = switch (transparency) {
                        .none => 0xFF,
                        .grayscale => 0xFF,
                        .rgb => |key| if (key[0] == r and key[1] == g and key[2] == b) 0 else 0xFF,
                    };
                    const dst = x * 4;
                    rgba[dst + 0] = r;
                    rgba[dst + 1] = g;
                    rgba[dst + 2] = b;
                    rgba[dst + 3] = alpha;
                }
            },
            16 => {
                for (0..@as(usize, width)) |x| {
                    const src = x * 6;
                    const r = readBeU16(raw_row, src + 0);
                    const g = readBeU16(raw_row, src + 2);
                    const b = readBeU16(raw_row, src + 4);
                    const alpha: u8 = switch (transparency) {
                        .none => 0xFF,
                        .grayscale => 0xFF,
                        .rgb => |key| if (key[0] == r and key[1] == g and key[2] == b) 0 else 0xFF,
                    };
                    const dst = x * 4;
                    rgba[dst + 0] = sampleToU8(r, 16);
                    rgba[dst + 1] = sampleToU8(g, 16);
                    rgba[dst + 2] = sampleToU8(b, 16);
                    rgba[dst + 3] = alpha;
                }
            },
            else => return PngError.UnsupportedFormat,
        },
        .indexed => {
            const pal = palette orelse return PngError.InvalidPalette;
            switch (ihdr.bit_depth) {
                1, 2, 4, 8 => {
                    for (0..@as(usize, width)) |x| {
                        const index: usize = if (ihdr.bit_depth == 8)
                            raw_row[x]
                        else
                            unpackPackedSample(raw_row, ihdr.bit_depth, x);
                        if (index >= pal.len) return PngError.InvalidPalette;
                        const entry = pal[index];
                        const dst = x * 4;
                        rgba[dst + 0] = entry[0];
                        rgba[dst + 1] = entry[1];
                        rgba[dst + 2] = entry[2];
                        rgba[dst + 3] = entry[3];
                    }
                },
                else => return PngError.UnsupportedFormat,
            }
        },
        .grayscale_alpha => switch (ihdr.bit_depth) {
            8 => {
                for (0..@as(usize, width)) |x| {
                    const src = x * 2;
                    const gray = raw_row[src];
                    const alpha = raw_row[src + 1];
                    const dst = x * 4;
                    rgba[dst + 0] = gray;
                    rgba[dst + 1] = gray;
                    rgba[dst + 2] = gray;
                    rgba[dst + 3] = alpha;
                }
            },
            16 => {
                for (0..@as(usize, width)) |x| {
                    const src = x * 4;
                    const gray = readBeU16(raw_row, src);
                    const alpha = readBeU16(raw_row, src + 2);
                    const dst = x * 4;
                    rgba[dst + 0] = sampleToU8(gray, 16);
                    rgba[dst + 1] = sampleToU8(gray, 16);
                    rgba[dst + 2] = sampleToU8(gray, 16);
                    rgba[dst + 3] = sampleToU8(alpha, 16);
                }
            },
            else => return PngError.UnsupportedFormat,
        },
        .rgba => switch (ihdr.bit_depth) {
            8 => {
                for (0..@as(usize, width)) |x| {
                    const src = x * 4;
                    const dst = x * 4;
                    @memcpy(rgba[dst .. dst + 4], raw_row[src .. src + 4]);
                }
            },
            16 => {
                for (0..@as(usize, width)) |x| {
                    const src = x * 8;
                    const dst = x * 4;
                    rgba[dst + 0] = sampleToU8(readBeU16(raw_row, src + 0), 16);
                    rgba[dst + 1] = sampleToU8(readBeU16(raw_row, src + 2), 16);
                    rgba[dst + 2] = sampleToU8(readBeU16(raw_row, src + 4), 16);
                    rgba[dst + 3] = sampleToU8(readBeU16(raw_row, src + 6), 16);
                }
            },
            else => return PngError.UnsupportedFormat,
        },
    }
}

fn unfilterScanline(
    filter_type: u8,
    bytes_per_pixel: usize,
    raw_row: []const u8,
    prev_row: []const u8,
    out: []u8,
) PngError!void {
    if (raw_row.len != out.len or prev_row.len != out.len) return PngError.CorruptData;

    switch (filter_type) {
        0 => @memcpy(out, raw_row),
        1 => {
            for (0..raw_row.len) |i| {
                const left: u8 = if (i >= bytes_per_pixel) out[i - bytes_per_pixel] else 0;
                out[i] = raw_row[i] +% left;
            }
        },
        2 => {
            for (0..raw_row.len) |i| {
                out[i] = raw_row[i] +% prev_row[i];
            }
        },
        3 => {
            for (0..raw_row.len) |i| {
                const left: u8 = if (i >= bytes_per_pixel) out[i - bytes_per_pixel] else 0;
                const above: u8 = prev_row[i];
                const avg: u8 = @truncate((@as(u16, left) + @as(u16, above)) / 2);
                out[i] = raw_row[i] +% avg;
            }
        },
        4 => {
            for (0..raw_row.len) |i| {
                const left: u8 = if (i >= bytes_per_pixel) out[i - bytes_per_pixel] else 0;
                const above: u8 = prev_row[i];
                const upper_left: u8 = if (i >= bytes_per_pixel) prev_row[i - bytes_per_pixel] else 0;
                out[i] = raw_row[i] +% paethPredictor(left, above, upper_left);
            }
        },
        else => return PngError.InvalidFilter,
    }
}

fn passDimension(full: u32, start: u32, step: u32) u32 {
    if (start >= full) return 0;
    return (full - start + step - 1) / step;
}

fn decodeSequentialRows(
    allocator: std.mem.Allocator,
    raw_data: []const u8,
    ihdr: IhdrData,
    palette: ?[]const PaletteEntry,
    transparency: Transparency,
    output: *PixelBuffer,
) PngError!void {
    const bytes_per_pixel = filterBytesPerPixel(ihdr);
    const row_bytes = try rowByteCount(ihdr.width, ihdr);
    const rgba_row_bytes = @as(usize, ihdr.width) * 4;

    const prev_row = allocator.alloc(u8, row_bytes) catch return PngError.OutOfMemory;
    defer allocator.free(prev_row);
    const curr_row = allocator.alloc(u8, row_bytes) catch return PngError.OutOfMemory;
    defer allocator.free(curr_row);
    @memset(prev_row, 0);

    var raw_pos: usize = 0;
    for (0..ihdr.height) |y| {
        if (raw_pos >= raw_data.len) return PngError.TruncatedData;
        const filter_type = raw_data[raw_pos];
        raw_pos += 1;
        if (raw_pos + row_bytes > raw_data.len) return PngError.TruncatedData;

        const raw_row = raw_data[raw_pos .. raw_pos + row_bytes];
        raw_pos += row_bytes;
        try unfilterScanline(filter_type, bytes_per_pixel, raw_row, prev_row, curr_row);

        const dst_offset = @as(usize, y) * @as(usize, output.row_pitch);
        try expandRowToRgba(curr_row, ihdr.width, ihdr, palette, transparency, output.data[dst_offset .. dst_offset + rgba_row_bytes]);
        @memcpy(prev_row, curr_row);
    }

    if (raw_pos != raw_data.len) return PngError.CorruptData;
}

fn decodeAdam7(
    allocator: std.mem.Allocator,
    raw_data: []const u8,
    ihdr: IhdrData,
    palette: ?[]const PaletteEntry,
    transparency: Transparency,
    output: *PixelBuffer,
) PngError!void {
    const bytes_per_pixel = filterBytesPerPixel(ihdr);
    const rgba_temp = allocator.alloc(u8, @as(usize, ihdr.width) * 4) catch return PngError.OutOfMemory;
    defer allocator.free(rgba_temp);

    var raw_pos: usize = 0;
    for (adam7_passes) |pass| {
        const pass_width = passDimension(ihdr.width, pass.start_x, pass.step_x);
        const pass_height = passDimension(ihdr.height, pass.start_y, pass.step_y);
        if (pass_width == 0 or pass_height == 0) continue;

        const pass_row_bytes = try rowByteCount(pass_width, ihdr);
        const prev_row = allocator.alloc(u8, pass_row_bytes) catch return PngError.OutOfMemory;
        defer allocator.free(prev_row);
        const curr_row = allocator.alloc(u8, pass_row_bytes) catch return PngError.OutOfMemory;
        defer allocator.free(curr_row);
        @memset(prev_row, 0);

        for (0..pass_height) |pass_y| {
            if (raw_pos >= raw_data.len) return PngError.TruncatedData;
            const filter_type = raw_data[raw_pos];
            raw_pos += 1;
            if (raw_pos + pass_row_bytes > raw_data.len) return PngError.TruncatedData;

            const raw_row = raw_data[raw_pos .. raw_pos + pass_row_bytes];
            raw_pos += pass_row_bytes;
            try unfilterScanline(filter_type, bytes_per_pixel, raw_row, prev_row, curr_row);

            const pass_rgba = rgba_temp[0 .. @as(usize, pass_width) * 4];
            try expandRowToRgba(curr_row, pass_width, ihdr, palette, transparency, pass_rgba);

            const dst_y = pass.start_y + @as(u32, @intCast(pass_y)) * pass.step_y;
            const row_base = @as(usize, dst_y) * @as(usize, output.row_pitch);
            for (0..pass_width) |pass_x| {
                const dst_x = pass.start_x + pass_x * pass.step_x;
                const src_offset = @as(usize, pass_x) * 4;
                const dst_offset = row_base + @as(usize, dst_x) * 4;
                @memcpy(output.data[dst_offset .. dst_offset + 4], pass_rgba[src_offset .. src_offset + 4]);
            }

            @memcpy(prev_row, curr_row);
        }
    }

    if (raw_pos != raw_data.len) return PngError.CorruptData;
}

fn decodePixelBuffer(allocator: std.mem.Allocator, data: []const u8) PngError!PixelBuffer {
    const ihdr = try parseIhdr(data);
    var chunks = try collectChunks(allocator, data, ihdr);
    defer chunks.deinit(allocator);

    const raw_data = try decodeZlib(allocator, chunks.idat);
    defer allocator.free(raw_data);

    var pixels = try mod.allocPixelBuffer(allocator, ihdr.width, ihdr.height, 4);
    errdefer pixels.free(allocator);
    @memset(pixels.data, 0);

    if (ihdr.interlace_method == 0) {
        try decodeSequentialRows(allocator, raw_data, ihdr, chunks.palette, chunks.transparency, &pixels);
    } else {
        try decodeAdam7(allocator, raw_data, ihdr, chunks.palette, chunks.transparency, &pixels);
    }

    return pixels;
}

/// Decodes a PNG from memory and returns owned RGBA pixels.
pub fn decodePixels(allocator: std.mem.Allocator, data: []const u8) PngError![]u8 {
    const pixels = try decodePixelBuffer(allocator, data);
    return pixels.data;
}

/// Decodes a PNG from a byte slice. Caller owns returned PixelBuffer.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) PngError!PixelBuffer {
    return decodePixelBuffer(allocator, data);
}

pub const pngDecoder: mod.Decoder = .{
    .signature = &PNG_SIGNATURE,
    .name = "PNG",
    .extensions = &.{ ".png" },
    .decodeFn = decode,
};

test "png packed row bytes for grayscale1" {
    const ihdr = IhdrData{
        .width = 9,
        .height = 1,
        .bit_depth = 1,
        .color_type = .grayscale,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 0,
    };
    try std.testing.expectEqual(@as(usize, 2), try rowByteCount(ihdr.width, ihdr));
}

test "png sub filter uses actual bytes per pixel" {
    const raw_row = [_]u8{ 10, 20, 30, 40, 1, 2, 3, 4 };
    const prev_row = [_]u8{0} ** raw_row.len;
    var out = [_]u8{0} ** raw_row.len;

    try unfilterScanline(1, 4, &raw_row, &prev_row, &out);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 11, 22, 33, 44 }, &out);
}

test "png decodes rgba sub-filter image end-to-end" {
    const fixture = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0xF4, 0x22, 0x7F,
        0x8A, 0x00, 0x00, 0x00, 0x0E, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0xE4, 0x12, 0x91, 0xD3,
        0x00, 0x01, 0x00, 0x03, 0xFA, 0x01, 0x06, 0xF7,
        0x0C, 0x92, 0x37, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    var pixels = try decode(std.testing.allocator, &fixture);
    defer pixels.free(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), pixels.width);
    try std.testing.expectEqual(@as(u32, 1), pixels.height);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60, 70, 80 }, pixels.data);
}

test "png decodes indexed palette transparency" {
    const fixture = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x03, 0x00, 0x00, 0x00, 0xC3, 0xFC, 0x8F,
        0xB8, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4C, 0x54,
        0x45, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xD2,
        0x87, 0xEF, 0x71, 0x00, 0x00, 0x00, 0x02, 0x74,
        0x52, 0x4E, 0x53, 0xFF, 0x00, 0xE5, 0xB7, 0x30,
        0x4A, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x60, 0x60, 0x04, 0x00,
        0x00, 0x04, 0x00, 0x02, 0xBF, 0x7A, 0x3F, 0x4A,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82,
    };

    var pixels = try decode(std.testing.allocator, &fixture);
    defer pixels.free(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00 }, pixels.data);
}

test "png decodes adam7 interlaced rgba image" {
    const fixture = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
        0x08, 0x06, 0x00, 0x00, 0x01, 0x05, 0xB1, 0x3D,
        0xB2, 0x00, 0x00, 0x00, 0x13, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x46, 0x40, 0x82, 0xE1, 0x3F, 0x18, 0x00, 0x00,
        0x4B, 0xC7, 0x09, 0xF7, 0x41, 0xA9, 0xBF, 0x18,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82,
    };

    var pixels = try decode(std.testing.allocator, &fixture);
    defer pixels.free(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), pixels.width);
    try std.testing.expectEqual(@as(u32, 2), pixels.height);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            0xFF, 0x00, 0x00, 0xFF,
            0x00, 0xFF, 0x00, 0xFF,
            0x00, 0x00, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF,
        },
        pixels.data,
    );
}
