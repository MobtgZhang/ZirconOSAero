//! SPDX-License-Identifier: MIT OR Apache-2.0
//!
//! ZirconOSAero — ICO (Windows Icon) Decoder
//!
//! Independent ICO decoder implementing Windows Icon format specification.
//! Supports embedded PNG and BMP images in ICO containers.
//!
//! Reference: Windows Icon Format Specification
//!   https://docs.microsoft.com/en-us/windows/win32/api/_winicon/
//!
//! Supported:
//!   - ICONDIR header + ICONDIRENTRY array
//!   - Embedded BMP (DIB) images (32bpp preferred)
//!   - Embedded PNG images (Vista+ PNG icons)
//!   - Multi-image ICO files
//!   - Best-size matching for icon selection
//!
//! NOT supported:
//!   - ICO with JPEG images (non-standard)
//!   - Writing / encoding

const std = @import("std");
const mod = @import("mod.zig");
const png_lib = @import("png.zig");
const bmp_lib = @import("bmp.zig");

// ============================================================================
// Structures

const ICONDIR_SIZE = 6;
const ICONDIRENTRY_SIZE = 16;

const IconDirHeader = struct {
    reserved: u16,
    type: u16,
    count: u16,
};

const IconDirEntry = struct {
    width: u8,
    height: u8,
    color_count: u8,
    reserved: u8,
    planes: u16,
    bit_count: u16,
    bytes_in_res: u32,
    image_offset: u32,
};

/// Container for a single image entry from an ICO file.
pub const IconImage = struct {
    entry: IconDirEntry,
    raw_data: []const u8,
    is_png: bool,
};

/// Icon image type embedded in ICO.
pub const IconImageType = enum {
    bmp,
    png,
};

// ============================================================================
// Parsing

fn parseIconDir(data: []const u8) mod.ImageError!IconDirHeader {
    if (data.len < ICONDIR_SIZE) return mod.ImageError.TruncatedData;
    const reserved = std.mem.readIntLittle(u16, data[0..2]);
    const typ = std.mem.readIntLittle(u16, data[2..4]);
    const cnt = std.mem.readIntLittle(u16, data[4..6]);

    if (reserved != 0) return mod.ImageError.InvalidSignature;
    if (typ != 1) return mod.ImageError.InvalidSignature; // 1 = icon, 2 = cursor

    return IconDirHeader{
        .reserved = reserved,
        .type = typ,
        .count = cnt,
    };
}

fn parseIconDirEntries(allocator: std.mem.Allocator, data: []const u8, count: u16) mod.ImageError![]IconDirEntry {
    if (data.len < @as(usize, count) * ICONDIRENTRY_SIZE) {
        return mod.ImageError.TruncatedData;
    }
    const entries = try allocator.alloc(IconDirEntry, count);
    for (0..count) |i| {
        const offset = i * ICONDIRENTRY_SIZE;
        entries[i] = IconDirEntry{
            .width = data[offset],
            .height = data[offset + 1],
            .color_count = data[offset + 2],
            .reserved = data[offset + 3],
            .planes = std.mem.readIntLittle(u16, data[offset + 4..offset + 6]),
            .bit_count = std.mem.readIntLittle(u16, data[offset + 6..offset + 8]),
            .bytes_in_res = std.mem.readIntLittle(u32, data[offset + 8..offset + 12]),
            .image_offset = std.mem.readIntLittle(u32, data[offset + 12..offset + 16]),
        };
    }
    return entries;
}

fn detectIco(data: []const u8) bool {
    return data.len >= ICONDIR_SIZE and
        data[0] == 0 and
        data[1] == 0 and
        data[2] == 1 and
        data[3] == 0;
}

/// Detects if an embedded image is PNG or BMP based on its header.
fn detectImageType(data: []const u8) IconImageType {
    if (data.len >= 8 and
        std.mem.eql(u8, data[0..8], &.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }))
    {
        return .png;
    }
    if (data.len >= 2 and data[0] == 'B' and data[1] == 'M') {
        return .bmp;
    }
    return .bmp; // Default to BMP
}

// ============================================================================
// Image Selection

/// Finds the best matching image for a target size.
/// Prefers: exact size > largest <= target > smallest > first
pub fn findBestImage(images: []IconImage, target_size: u32) ?*IconImage {
    var best: ?*IconImage = null;
    var best_score: i32 = -1;

    for (images) |*img| {
        const w = if (img.entry.width == 0) 256 else img.entry.width;
        const h = if (img.entry.height == 0) 256 else img.entry.height;
        const size: u32 = @min(w, h);

        const score: i32 = if (size == target_size) 1000 else if (size < target_size) @as(i32, @intCast(size)) else -@as(i32, @intCast(size));

        if (score > best_score) {
            best_score = score;
            best = img;
        }
    }

    return best;
}

/// Finds the largest image in the ICO file.
pub fn findLargestImage(images: []IconImage) ?*IconImage {
    var largest: ?*IconImage = null;
    var max_size: u32 = 0;

    for (images) |*img| {
        const w = if (img.entry.width == 0) 256 else img.entry.width;
        const h = if (img.entry.height == 0) 256 else img.entry.height;
        const size: u32 = @min(w, h);
        if (size > max_size) {
            max_size = size;
            largest = img;
        }
    }

    return largest;
}

// ============================================================================
// Decoding

/// Decodes the raw image data of an ICONDIRENTRY into a PixelBuffer.
pub fn decodeImageData(allocator: std.mem.Allocator, img: *const IconImage) mod.ImageError!mod.PixelBuffer {
    if (img.is_png) {
        return png_lib.decode(allocator, img.raw_data);
    }

    // BMP/DIB embedded image
    // ICO BMP images may have a BITMAPINFOHEADER without BITMAPFILEHEADER
    // The header might be prefixed with a 4-byte AND mask
    var bmp_data = img.raw_data;

    // Check for AND mask prefix (4-byte size before BITMAPINFOHEADER)
    if (bmp_data.len >= 4) {
        const maybe_and_mask_size = std.mem.readIntLittle(u32, bmp_data[0..4]);
        // AND mask size should match (width_padded_to_4_bytes * height / 8)
        if (maybe_and_mask_size < bmp_data.len) {
            const header_start = std.mem.readIntLittle(u32, bmp_data[maybe_and_mask_size..maybe_and_mask_size + 4]);
            // BITMAPINFOHEADER starts with its size (40 for standard)
            if (header_start == 40 or header_start == 124) {
                bmp_data = bmp_data[4..];
            }
        }
    }

    return bmp_lib.decode(allocator, bmp_data);
}

// ============================================================================
// Public API

const ICO_SIGNATURE = [_]u8{ 0x00, 0x00 };

/// Decodes an ICO file. Returns first (largest) image.
/// For full ICO support, use decodeIcoFile.
/// Caller owns returned PixelBuffer.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!mod.PixelBuffer {
    const images = try decodeIcoFile(allocator, data);
    defer {
        for (images) |*img| allocator.free(img.raw_data);
        allocator.free(images);
    }

    const largest = findLargestImage(images) orelse return mod.ImageError.CorruptData;
    return decodeImageData(allocator, largest);
}

/// Decodes all images from an ICO file.
/// Caller must free each raw_data array and the returned slice.
pub fn decodeIcoFile(allocator: std.mem.Allocator, data: []const u8) mod.ImageError![]IconImage {
    if (data.len < ICONDIR_SIZE) return mod.ImageError.TruncatedData;
    if (data[0] != 0 or data[1] != 0) return mod.ImageError.InvalidSignature;

    const header = try parseIconDir(data);
    const entries = try parseIconDirEntries(allocator, data[ICONDIR_SIZE..], header.count);
    defer allocator.free(entries);

    var images = try allocator.alloc(IconImage, entries.len);
    errdefer allocator.free(images);

    for (entries, 0..) |entry, i| {
        const offset = @as(usize, entry.image_offset);
        const end = offset + @as(usize, entry.bytes_in_res);
        if (end > data.len) {
            images[i] = .{
                .entry = entry,
                .raw_data = &.{},
                .is_png = false,
            };
            continue;
        }

        const img_data = try allocator.alloc(u8, @as(usize, entry.bytes_in_res));
        @memcpy(img_data, data[offset..end]);

        images[i] = .{
            .entry = entry,
            .raw_data = img_data,
            .is_png = detectImageType(img_data) == .png,
        };
    }

    return images;
}

/// Decoder interface entry.
pub const icoDecoder: mod.Decoder = .{
    .signature = &ICO_SIGNATURE,
    .name = "ICO",
    .extensions = &.{ ".ico" },
    .detectFn = detectIco,
    .decodeFn = decode,
};
