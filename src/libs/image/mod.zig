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
//! ZirconOSAero — Image Format Decoder Registry
//!
//! Unified interface and registry for all image format decoders.
//! Implements clean-room image decoding for Windows 7 SP1 native formats:
//! PNG, JPEG, BMP, GIF, TIFF, WDP/HD Photo, ICO, CUR, ANI, WMF, EMF.
//!
//! Reference standards:
//!   - RFC 2083        (PNG)
//!   - ITU-T T.81      (JPEG)
//!   - TIFF 6.0        (TIFF)
//!   - GIF89a          (GIF)
//!   - Windows BMP     (BMP/DIB)
//!   - Windows ICO/CUR  (Icon/Cursor)
//!   - Windows ANI      (Animated Cursor)
//!   - Windows Media Photo / JPEG XR (WDP/HDP)
//!   - Windows Metafile (WMF/EMF)

const std = @import("std");
const root = @This();

// ============================================================================
// Public Types

/// Unified decoded pixel buffer returned by all decoders.
pub const PixelBuffer = struct {
    width: u32,
    height: u32,
    bytes_per_pixel: u16,
    row_pitch: u32,
    data: []u8,

    pub fn free(self: *const PixelBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    /// Returns pixel at (x, y). Caller must ensure bounds.
    pub fn pixelAt(self: *const PixelBuffer, x: u32, y: u32) []const u8 {
        const offset = @as(usize, y) * @as(usize, self.row_pitch) + @as(usize, x) * @as(usize, self.bytes_per_pixel);
        return self.data[offset .. offset + @as(usize, self.bytes_per_pixel)];
    }
};

pub fn checkedBufferLen(width: u32, height: u32, bytes_per_pixel: u16) ImageError!usize {
    const row_pitch = std.math.mul(u32, width, bytes_per_pixel) catch return ImageError.InvalidDimension;
    return std.math.mul(usize, row_pitch, height) catch return ImageError.InvalidDimension;
}

pub fn allocPixelBuffer(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    bytes_per_pixel: u16,
) ImageError!PixelBuffer {
    const row_pitch = std.math.mul(u32, width, bytes_per_pixel) catch return ImageError.InvalidDimension;
    const total_len = std.math.mul(usize, row_pitch, height) catch return ImageError.InvalidDimension;
    const data = allocator.alloc(u8, total_len) catch return ImageError.OutOfMemory;
    return .{
        .width = width,
        .height = height,
        .bytes_per_pixel = bytes_per_pixel,
        .row_pitch = row_pitch,
        .data = data,
    };
}

/// Per-format decoder error types.
/// Individual decoders may extend this with format-specific errors.
pub const ImageError = error{
    InvalidSignature,
    InvalidHeader,
    CorruptData,
    UnsupportedFormat,
    OutOfMemory,
    InvalidDimension,
    TruncatedData,
    InvalidPalette,
    InvalidFilter,
    ZlibError,
    HuffmanError,
    IdctError,
    ColorConversionError,
    InvalidMarker,
    MissingEoi,
    RleError,
    InvalidChunk,
    UnsupportedCompression,
    InvalidFrame,
    InvalidAnimation,
};

/// Decoder trait — each image format implements this interface.
pub const Decoder = struct {
    /// Magic bytes (signature) used for format detection.
    signature: []const u8,
    /// Human-readable format name.
    name: []const u8,
    /// Common file extensions for this format.
    extensions: []const []const u8,
    /// Optional stronger detector used when signatures overlap.
    detectFn: ?*const fn (data: []const u8) bool = null,
    /// Decodes from a byte slice. Caller owns returned PixelBuffer.
    /// The caller must call pixels.free(allocator) when done.
    decodeFn: *const fn (allocator: std.mem.Allocator, data: []const u8) ImageError!PixelBuffer,

    pub fn decode(self: *const Decoder, allocator: std.mem.Allocator, data: []const u8) ImageError!PixelBuffer {
        return self.decodeFn(allocator, data);
    }
};

/// Animation frame — used by GIF and ANI decoders.
pub const AnimationFrame = struct {
    /// Decoded pixel buffer for this frame.
    pixels: PixelBuffer,
    /// Display delay in milliseconds. 0 means use default.
    delay_ms: u32,
    /// Disposal method: how to handle the frame after display.
    /// 1=keep, 2=restore background, 3=restore previous, 7=restore to specific
    disposal: u8,
    /// Alpha/transparency index for this frame (GIF only).
    transparent_index: ?u8,
};

/// Animation container — returned by animated format decoders.
pub const Animation = struct {
    frames: []AnimationFrame,
    loop_count: u16,
    width: u32,
    height: u32,

    pub fn free(self: *Animation, allocator: std.mem.Allocator) void {
        for (self.frames) |*frame| {
            frame.pixels.free(allocator);
        }
        allocator.free(self.frames);
    }
};

/// TIFF page — multi-page TIFF returns one per page.
pub const TiffPage = struct {
    pixels: PixelBuffer,
    page_number: u32,
    description: []const u8,
};

// ============================================================================
// Format Signatures (Magic Bytes)

pub const Signatures = struct {
    /// PNG: 137 80 78 71 13 10 26 10
    pub const png = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    /// JPEG: FF D8 FF
    pub const jpeg = [_]u8{ 0xFF, 0xD8, 0xFF };

    /// GIF87a: 47 49 46 38 37 61
    /// GIF89a: 47 49 46 38 39 61
    pub const gif = [_]u8{ 0x47, 0x49, 0x46, 0x38 };

    /// TIFF little-endian: 49 49 2A 00
    pub const tiff_le = [_]u8{ 0x49, 0x49, 0x2A, 0x00 };

    /// TIFF big-endian: 4D 4D 00 2A
    pub const tiff_be = [_]u8{ 0x4D, 0x4D, 0x00, 0x2A };

    /// BMP: 42 4D ("BM")
    pub const bmp = [_]u8{ 0x42, 0x4D };

    /// WDP/HDP: 00 00 00 ... 48 44 50 4C (MFHDR\0HDRL)
    /// Real WDP signature: 49 49 88 3F 3A ... but we detect by RIFF/WAVE-like container.
    pub const wdp = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x48, 0x44, 0x50, 0x4C };

    /// ICO: 00 00 (reserved) — ICONDIR has reserved=0 at offset 0.
    pub const ico = [_]u8{ 0x00, 0x00 };

    /// CUR: 00 00 (reserved) — same as ICO, resolved by resource type.
    /// Detection: ICOCURRES (ANI) or CURSORSIZE fields.
    pub const cur = [_]u8{ 0x00, 0x00 };

    /// ANI: RIFF....ACON
    pub const ani = [_]u8{ 0x52, 0x49, 0x46, 0x46 };

    /// EMF/WMF placeable: 00 00 01 00 (MetaHeader record type)
    pub const emf = [_]u8{ 0x00, 0x00, 0x00, 0x00 };

    /// WMF placeable: D7 CD C6 9A (META_PLACABLE_WMF signature)
    pub const wmf_placeable = [_]u8{ 0xD7, 0xCD, 0xC6, 0x9A };
};

/// Checks if data starts with the given signature.
fn matchesSignature(data: []const u8, sig: []const u8) bool {
    if (data.len < sig.len) return false;
    return std.mem.eql(u8, data[0..sig.len], sig);
}

// ============================================================================
// Decoder Registry

/// Global decoder registry — format detection + dispatch.
/// Decoders are checked in order of specificity; more specific signatures first.
pub const DecoderRegistry = struct {
    decoders: []const *const Decoder,

    /// Detects format from magic bytes and decodes.
    pub fn detectAndDecode(
        registry: *const DecoderRegistry,
        allocator: std.mem.Allocator,
        data: []const u8,
    ) ImageError!PixelBuffer {
        const decoder = registry.detect(data) orelse return ImageError.UnsupportedFormat;
        return decoder.decode(allocator, data);
    }

    /// Detects format from magic bytes. Returns null if unknown.
    pub fn detect(registry: *const DecoderRegistry, data: []const u8) ?*const Decoder {
        inline for (registry.decoders) |dec| {
            if (dec.detectFn) |detect_fn| {
                if (detect_fn(data)) return dec;
            } else if (matchesSignature(data, dec.signature)) {
                return dec;
            }
        }
        return null;
    }

    /// Detects format by file extension. Extension should include the dot.
    pub fn detectByExtension(
        registry: *const DecoderRegistry,
        ext: []const u8,
    ) ?*const Decoder {
        const lower_ext = ext;
        inline for (registry.decoders) |dec| {
            for (dec.extensions) |e| {
                if (std.ascii.eqlIgnoreCase(lower_ext, e)) {
                    return dec;
                }
            }
        }
        return null;
    }
};

// ============================================================================
// Format Names

pub const FormatName = struct {
    pub const png = "PNG";
    pub const jpeg = "JPEG";
    pub const bmp = "BMP";
    pub const gif = "GIF";
    pub const tiff = "TIFF";
    pub const wdp = "WDP/HD Photo";
    pub const ico = "ICO";
    pub const cur = "CUR";
    pub const ani = "ANI";
    pub const wmf = "WMF";
    pub const emf = "EMF";
    pub const unknown = "Unknown";
};

// ============================================================================
// Standard Extensions

pub const StdExtensions = struct {
    pub const png = &.{ ".png" };
    pub const jpeg = &.{ ".jpg", ".jpeg", ".jpe", ".jfif" };
    pub const bmp = &.{ ".bmp", ".dib", ".rle" };
    pub const gif = &.{ ".gif" };
    pub const tiff = &.{ ".tif", ".tiff" };
    pub const wdp = &.{ ".wdp", ".hdp" };
    pub const ico = &.{ ".ico" };
    pub const cur = &.{ ".cur" };
    pub const ani = &.{ ".ani" };
    pub const wmf = &.{ ".wmf" };
    pub const emf = &.{ ".emf" };
};

// ============================================================================
// Utility

/// Copies RGBA pixel data to a new buffer with the specified row pitch.
pub fn copyWithRowPitch(
    allocator: std.mem.Allocator,
    src: []const u8,
    width: u32,
    height: u32,
    src_row_pitch: u32,
    dst_bytes_per_pixel: u16,
    dst_row_pitch: u32,
) ![]u8 {
    const dst = try allocator.alloc(u8, @as(usize, dst_row_pitch) * @as(usize, height));
    const bpp = @as(usize, dst_bytes_per_pixel);
    for (0..@as(usize, height)) |y| {
        const src_row = @as(usize, y) * @as(usize, src_row_pitch);
        const dst_row = @as(usize, y) * @as(usize, dst_row_pitch);
        @memcpy(dst[dst_row..dst_row + @as(usize, width) * bpp], src[src_row..src_row + @as(usize, width) * bpp]);
    }
    return dst;
}

/// Fills an RGBA pixel at `(x, y)` with `[R, G, B, A]`.
pub fn fillPixel(buf: *PixelBuffer, x: u32, y: u32, color: [4]u8) void {
    if (buf.bytes_per_pixel < 4) return;
    const offset = @as(usize, y) * @as(usize, buf.row_pitch) + @as(usize, x) * @as(usize, buf.bytes_per_pixel);
    @memcpy(buf.data[offset..offset + 4], &color);
}

/// Returns a vertically flipped copy of `buf`.
pub fn flipVertically(buf: *PixelBuffer, allocator: std.mem.Allocator) !PixelBuffer {
    const new_data = try allocator.alloc(u8, @as(usize, buf.row_pitch) * @as(usize, buf.height));
    const h = @as(usize, buf.height);
    const rp = @as(usize, buf.row_pitch);
    for (0..h) |y| {
        const src_row = y * rp;
        const dst_row = (h - 1 - y) * rp;
        @memcpy(new_data[dst_row..dst_row + rp], buf.data[src_row..src_row + rp]);
    }
    return PixelBuffer{
        .width = buf.width,
        .height = buf.height,
        .bytes_per_pixel = buf.bytes_per_pixel,
        .row_pitch = buf.row_pitch,
        .data = new_data,
    };
}

// ============================================================================
// Format Detection by Extension

/// Returns format name from file extension.
pub fn formatFromExtension(ext: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return FormatName.png;
    if (std.ascii.eqlIgnoreCase(ext, ".jpg")) return FormatName.jpeg;
    if (std.ascii.eqlIgnoreCase(ext, ".jpeg")) return FormatName.jpeg;
    if (std.ascii.eqlIgnoreCase(ext, ".jpe")) return FormatName.jpeg;
    if (std.ascii.eqlIgnoreCase(ext, ".jfif")) return FormatName.jpeg;
    if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return FormatName.bmp;
    if (std.ascii.eqlIgnoreCase(ext, ".dib")) return FormatName.bmp;
    if (std.ascii.eqlIgnoreCase(ext, ".rle")) return FormatName.bmp;
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return FormatName.gif;
    if (std.ascii.eqlIgnoreCase(ext, ".tif")) return FormatName.tiff;
    if (std.ascii.eqlIgnoreCase(ext, ".tiff")) return FormatName.tiff;
    if (std.ascii.eqlIgnoreCase(ext, ".wdp")) return FormatName.wdp;
    if (std.ascii.eqlIgnoreCase(ext, ".hdp")) return FormatName.wdp;
    if (std.ascii.eqlIgnoreCase(ext, ".ico")) return FormatName.ico;
    if (std.ascii.eqlIgnoreCase(ext, ".cur")) return FormatName.cur;
    if (std.ascii.eqlIgnoreCase(ext, ".ani")) return FormatName.ani;
    if (std.ascii.eqlIgnoreCase(ext, ".wmf")) return FormatName.wmf;
    if (std.ascii.eqlIgnoreCase(ext, ".emf")) return FormatName.emf;
    return FormatName.unknown;
}

/// Returns true if the format is a known Windows 7 SP1 native image format.
pub fn isWindowsNativeFormat(ext: []const u8) bool {
    return !std.ascii.eqlIgnoreCase(formatFromExtension(ext), FormatName.unknown);
}
