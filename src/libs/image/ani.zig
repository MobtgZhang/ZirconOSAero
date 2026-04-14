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
//! ZirconOSAero — ANI (Animated Cursor) Decoder
//!
//! Independent ANI decoder. ANI files are RIFF-based containers holding
//! animated cursor sequences.
//!
//! Reference: Windows Animated Cursor Format (ANI)
//!   https://docs.microsoft.com/en-us/windows/win32/api/_winicon/
//!
//! Supported:
//!   - RIFF/..../ACON container format
//!   - ANIH chunk (animated cursor header)
//!   - LIST/fram chunk (frame data — embedded .cur files)
//!   - Rate chunk (frame delays)
//!   - Icon directory resolution
//!   - NETSCAPE-style looping
//!
//! NOT supported:
//!   - Rate chunk per-frame (all frames use same delay)

const std = @import("std");
const mod = @import("mod.zig");
const cur_lib = @import("cur.zig");

// ============================================================================
// ANI Structures

const RIFF_SIGNATURE = [4]u8{ 0x52, 0x49, 0x46, 0x46 }; // 'RIFF'
const ACON_FORM = [4]u8{ 0x41, 0x43, 0x4F, 0x4E }; // 'ACON'

// Chunk IDs
const ANIH_CHUNK = [4]u8{ 0x41, 0x4E, 0x49, 0x48 }; // 'ANIH'
const FRAM_CHUNK = [4]u8{ 0x66, 0x72, 0x61, 0x6D }; // 'fram'
const RATE_CHUNK = [4]u8{ 0x72, 0x61, 0x74, 0x65 }; // 'rate'
const ICON_CHUNK = [4]u8{ 0x69, 0x63, 0x6F, 0x6E }; // 'icon'

const AniHeader = struct {
    cb_size: u32,
    frames: u32,
    steps: u32,
    width: u32,
    height: u32,
    bpp: u32,
    num_planes: u32,
    display_rate: u32,
    flags: u32,

    const FLAG_ICON = 0x00000001;
    const FLAG_SEQUENCE = 0x00000002;
};

/// Animation frame.
pub const AniFrame = struct {
    cur_data: []const u8,
    hotspot_x: u16,
    hotspot_y: u16,
};

/// Full animated cursor container.
pub const AniCursor = struct {
    frames: []AniFrame,
    delays_ms: []u32,
    width: u32,
    height: u32,
    frame_count: u32,
    loop_count: u16,
};

// ============================================================================
// Parsing

fn readFourCC(data: []const u8, pos: usize) [4]u8 {
    return .{
        data[pos],
        data[pos + 1],
        data[pos + 2],
        data[pos + 3],
    };
}

fn readU32LE(data: []const u8, pos: usize) u32 {
    return std.mem.readIntLittle(u32, data[pos .. pos + 4]);
}

fn chunkIdMatch(a: [4]u8, b: [4]u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

/// Parses the ANIH chunk from ANI data.
fn parseAnih(data: []const u8) mod.ImageError!AniHeader {
    if (data.len < 36) return mod.ImageError.TruncatedData;

    return AniHeader{
        .cb_size = readU32LE(data, 0),
        .frames = readU32LE(data, 4),
        .steps = readU32LE(data, 8),
        .width = readU32LE(data, 12),
        .height = readU32LE(data, 16),
        .bpp = readU32LE(data, 20),
        .num_planes = readU32LE(data, 24),
        .display_rate = readU32LE(data, 28),
        .flags = readU32LE(data, 32),
    };
}

/// Reads the frame delays from a RATE chunk.
fn parseRateChunk(allocator: std.mem.Allocator, data: []const u8) mod.ImageError![]u32 {
    const count = data.len / 4;
    if (count == 0) return &.{};
    const delays = try allocator.alloc(u32, count);
    for (0..count) |i| {
        delays[i] = readU32LE(data, i * 4);
    }
    return delays;
}

/// Parses a LIST/fram container to extract individual .cur images.
fn parseFramList(data: []const u8, num_frames: u32, allocator: std.mem.Allocator) mod.ImageError![]AniFrame {
    var frames = std.ArrayListUnmanaged(AniFrame){};
    errdefer {
        for (frames.items) |frame| allocator.free(frame.cur_data);
        frames.deinit(allocator);
    }

    var pos: usize = 0;

    while (pos + 8 < data.len and frames.items.len < num_frames) {
        const chunk_id = readFourCC(data, pos);
        const chunk_size = readU32LE(data, pos + 4);
        pos += 8;

        if (chunkIdMatch(chunk_id, ICON_CHUNK)) {
            // Each icon chunk contains a complete .cur file
            const cur_data = try allocator.alloc(u8, @as(usize, chunk_size));
            @memcpy(cur_data, data[pos .. pos + @as(usize, chunk_size)]);

            // Try to extract hotspot from CUR header
            var hotspot_x: u16 = 0;
            var hotspot_y: u16 = 0;
            if (chunk_size >= cur_lib.CURDIR_SIZE + cur_lib.CURSORDIRENTRY_SIZE) {
                // CUR header is 6 bytes; hotspot_x/y live at +4/+6 inside the first entry.
                hotspot_x = std.mem.readIntLittle(u16, cur_data[10..12]);
                hotspot_y = std.mem.readIntLittle(u16, cur_data[12..14]);
            }

            try frames.append(allocator, .{
                .cur_data = cur_data,
                .hotspot_x = hotspot_x,
                .hotspot_y = hotspot_y,
            });
        }

        // Round up to 2-byte boundary
        pos += @as(usize, chunk_size);
        if (chunk_size & 1 == 1) pos += 1;

        if (frames.items.len >= num_frames) break;
    }

    return frames.toOwnedSlice(allocator);
}

// ============================================================================
// Public API

/// Decodes an ANI (animated cursor) file.
/// Returns AniCursor with decoded frame data.
/// Caller must free all frame cur_data arrays and delays.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!AniCursor {
    if (data.len < 12) return mod.ImageError.TruncatedData;

    // Verify RIFF signature
    if (!std.mem.eql(u8, data[0..4], &RIFF_SIGNATURE)) {
        return mod.ImageError.InvalidSignature;
    }

    // Verify ACON form type
    if (!std.mem.eql(u8, data[8..12], &ACON_FORM)) {
        return mod.ImageError.InvalidSignature;
    }

    var pos: usize = 12;
    var header: ?AniHeader = null;
    var rate_delays: []u32 = &.{};
    var frame_data: ?[]u8 = null;
    var default_delay_ms: u32 = 100;
    errdefer if (rate_delays.len > 0) allocator.free(rate_delays);
    errdefer if (frame_data) |bytes| allocator.free(bytes);

    while (pos + 8 < data.len) {
        const chunk_id = readFourCC(data, pos);
        const chunk_size = readU32LE(data, pos + 4);
        pos += 8;

        const chunk_end = pos + @as(usize, chunk_size);

        if (chunkIdMatch(chunk_id, ANIH_CHUNK)) {
            header = try parseAnih(data[@as(usize, pos)..@as(usize, chunk_end)]);
            default_delay_ms = header.?.display_rate / 60 * 1000 / header.?.display_rate;
            if (default_delay_ms == 0) default_delay_ms = 100;
        } else if (chunkIdMatch(chunk_id, RATE_CHUNK)) {
            if (rate_delays.len > 0) allocator.free(rate_delays);
            rate_delays = try parseRateChunk(allocator, data[@as(usize, pos)..@as(usize, chunk_end)]);
        } else if (chunkIdMatch(chunk_id, [4]u8{ 0x4C, 0x49, 0x53, 0x54 })) {
            // LIST chunk — check form type
            if (pos + 4 <= data.len) {
                const form_type = readFourCC(data, @as(usize, pos));
                if (chunkIdMatch(form_type, FRAM_CHUNK)) {
                    // LIST/fram contains the frame data
                    const list_data = data[@as(usize, pos + 4)..@as(usize, chunk_end)];
                    if (frame_data) |old_data| allocator.free(old_data);
                    frame_data = try allocator.alloc(u8, @as(usize, chunk_size - 4));
                    @memcpy(frame_data.?, list_data);
                }
            }
        }

        pos = chunk_end;
        if (chunk_size & 1 == 1) pos += 1;
    }

    const hdr = header orelse return mod.ImageError.InvalidHeader;
    if (frame_data == null) return mod.ImageError.CorruptData;

    // Parse frames from LIST/fram data
    const frames = try parseFramList(frame_data.?, hdr.frames, allocator);
    allocator.free(frame_data.?);

    // Build delays array
    const delays = try allocator.alloc(u32, frames.len);
    for (0..frames.len) |i| {
        if (i < rate_delays.len) {
            // Rate is in jiffies (1/60th of a second)
            const jiffies = rate_delays[i];
            delays[i] = @as(u32, @intCast(jiffies)) * 1000 / 60;
        } else {
            delays[i] = default_delay_ms;
        }
    }

    if (rate_delays.len > 0) allocator.free(rate_delays);

    return AniCursor{
        .frames = frames,
        .delays_ms = delays,
        .width = hdr.width,
        .height = hdr.height,
        .frame_count = hdr.frames,
        .loop_count = 0, // Infinite by default
    };
}

/// Decoder interface entry.
pub const aniDecoder: mod.Decoder = .{
    .signature = &[4]u8{ 0x52, 0x49, 0x46, 0x46 },
    .name = "ANI",
    .extensions = &.{".ani"},
    .decodeFn = struct {
        fn call(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!mod.PixelBuffer {
            // ANI is animated, but we return the first frame for decoder interface
            const ani = try decode(allocator, data);
            defer {
                for (ani.frames) |*f| allocator.free(f.cur_data);
                allocator.free(ani.frames);
                allocator.free(ani.delays_ms);
            }
            if (ani.frames.len == 0) return mod.ImageError.CorruptData;
            return cur_lib.decode(allocator, ani.frames[0].cur_data);
        }
    }.call,
};
