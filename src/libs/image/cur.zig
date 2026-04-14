//! SPDX-License-Identifier: MIT OR Apache-2.0
//!
//! ZirconOSAero — CUR (Windows Cursor) Decoder
//!
//! Independent CUR decoder. CUR format is nearly identical to ICO with
//! the addition of hotspot coordinates.
//!
//! Reference: Windows Cursor Format
//!   https://docs.microsoft.com/en-us/windows/win32/api/_winicon/
//!
//! Supported:
//!   - CURDIR header + CURSORDIRENTRY array
//!   - Hotspot coordinates (cursor hotspot)
//!   - Embedded BMP/DIB and PNG images
//!   - Multi-image cursor files
//!
//! NOT supported:
//!   - CUR with embedded JPEG

const std = @import("std");
const mod = @import("mod.zig");
const png_lib = @import("png.zig");
const bmp_lib = @import("bmp.zig");

// ============================================================================
// Structures

pub const CURDIR_SIZE = 6;
pub const CURSORDIRENTRY_SIZE = 16;

/// Same as ICO header but type=2.
const CurDirHeader = struct {
    reserved: u16,
    type: u16,
    count: u16,
};

/// Same as ICONDIRENTRY but with hotspot fields.
const CurDirEntry = struct {
    width: u8,
    height: u8,
    color_count: u8,
    reserved: u8,
    hotspot_x: u16,
    hotspot_y: u16,
    bytes_in_res: u32,
    image_offset: u32,
};

pub const CurImage = struct {
    entry: CurDirEntry,
    raw_data: []const u8,
    is_png: bool,
};

// ============================================================================
// Parsing

fn parseCurDir(data: []const u8) mod.ImageError!CurDirHeader {
    if (data.len < CURDIR_SIZE) return mod.ImageError.TruncatedData;
    const reserved = std.mem.readIntLittle(u16, data[0..2]);
    const typ = std.mem.readIntLittle(u16, data[2..4]);
    const cnt = std.mem.readIntLittle(u16, data[4..6]);

    if (reserved != 0) return mod.ImageError.InvalidSignature;
    if (typ != 2) return mod.ImageError.InvalidSignature; // 2 = cursor

    return CurDirHeader{
        .reserved = reserved,
        .type = typ,
        .count = cnt,
    };
}

fn parseCurDirEntries(allocator: std.mem.Allocator, data: []const u8, count: u16) mod.ImageError![]CurDirEntry {
    if (data.len < @as(usize, count) * CURSORDIRENTRY_SIZE) {
        return mod.ImageError.TruncatedData;
    }
    const entries = try allocator.alloc(CurDirEntry, count);
    for (0..count) |i| {
        const offset = i * CURSORDIRENTRY_SIZE;
        entries[i] = CurDirEntry{
            .width = data[offset],
            .height = data[offset + 1],
            .color_count = data[offset + 2],
            .reserved = data[offset + 3],
            .hotspot_x = std.mem.readIntLittle(u16, data[offset + 4..offset + 6]),
            .hotspot_y = std.mem.readIntLittle(u16, data[offset + 6..offset + 8]),
            .bytes_in_res = std.mem.readIntLittle(u32, data[offset + 8..offset + 12]),
            .image_offset = std.mem.readIntLittle(u32, data[offset + 12..offset + 16]),
        };
    }
    return entries;
}

fn detectCur(data: []const u8) bool {
    return data.len >= CURDIR_SIZE and
        data[0] == 0 and
        data[1] == 0 and
        data[2] == 2 and
        data[3] == 0;
}

fn detectImageType(data: []const u8) bool {
    return data.len >= 8 and
        std.mem.eql(u8, data[0..8], &.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
}

// ============================================================================
// Public API

const CUR_SIGNATURE = [_]u8{ 0x00, 0x00 };

/// Decodes a CUR file. Returns first image with hotspot.
/// Caller owns returned PixelBuffer.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!mod.PixelBuffer {
    const images = try decodeCurFile(allocator, data);
    defer {
        for (images) |*img| allocator.free(img.raw_data);
        allocator.free(images);
    }

    if (images.len == 0) return mod.ImageError.CorruptData;
    const largest = blk: {
        var best: ?*CurImage = null;
        var max_size: u32 = 0;
        for (images) |*img| {
            const w: u32 = if (img.entry.width == 0) 256 else img.entry.width;
            const h: u32 = if (img.entry.height == 0) 256 else img.entry.height;
            const size: u32 = @min(w, h);
            if (size > max_size) {
                max_size = size;
                best = img;
            }
        }
        break :blk best orelse &images[0];
    };

    if (largest.is_png) {
        return png_lib.decode(allocator, largest.raw_data);
    }
    var bmp_data = largest.raw_data;
    if (bmp_data.len >= 4) {
        const maybe_size = std.mem.readIntLittle(u32, bmp_data[0..4]);
        if (maybe_size < bmp_data.len) {
            const hdr = std.mem.readIntLittle(u32, bmp_data[maybe_size..maybe_size + 4]);
            if (hdr == 40 or hdr == 124) {
                bmp_data = bmp_data[4..];
            }
        }
    }
    return bmp_lib.decode(allocator, bmp_data);
}

/// Decodes all images from a CUR file.
pub fn decodeCurFile(allocator: std.mem.Allocator, data: []const u8) mod.ImageError![]CurImage {
    if (data.len < CURDIR_SIZE) return mod.ImageError.TruncatedData;

    const header = try parseCurDir(data);
    const entries = try parseCurDirEntries(allocator, data[CURDIR_SIZE..], header.count);
    defer allocator.free(entries);

    var images = try allocator.alloc(CurImage, entries.len);
    errdefer allocator.free(images);

    for (entries, 0..) |entry, i| {
        const offset = @as(usize, entry.image_offset);
        const end = offset + @as(usize, entry.bytes_in_res);
        if (offset >= data.len or end > data.len) {
            images[i] = .{ .entry = entry, .raw_data = &.{}, .is_png = false };
            continue;
        }
        const img_data = try allocator.alloc(u8, @as(usize, entry.bytes_in_res));
        @memcpy(img_data, data[offset..end]);
        images[i] = .{
            .entry = entry,
            .raw_data = img_data,
            .is_png = detectImageType(img_data),
        };
    }

    return images;
}

/// Decoder interface entry.
pub const curDecoder: mod.Decoder = .{
    .signature = &CUR_SIGNATURE,
    .name = "CUR",
    .extensions = &.{ ".cur" },
    .detectFn = detectCur,
    .decodeFn = decode,
};
