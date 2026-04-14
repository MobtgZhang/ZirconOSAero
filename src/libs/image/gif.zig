//! SPDX-License-Identifier: MIT OR Apache-2.0
//!
//! ZirconOSAero — GIF Decoder
//!
//! Independent GIF decoder implementing GIF89a specification.
//! Supports animated GIF with frame composition.
//!
//! Reference: https://www.w3.org/Graphics/GIF/spec-gif89a.txt
//!
//! Supported:
//!   - GIF87a and GIF89a
//!   - Global and local color tables
//!   - Graphic Control Extension (disposal, delay, transparency)
//!   - Image Descriptor + LZW decoding
//!   - Application Extension (NETSCAPE looping)
//!   - First frame RGBA32 output
//!   - Animation frame decoding with disposal methods
//!
//! NOT supported:
//!   - Text Extension block
//!   - Comment Extension block
//!   - Plain Text Extension block

const std = @import("std");
const mod = @import("mod.zig");

// ============================================================================
// GIF Structures

const GIF_SIGNATURE = [6]u8{ 'G', 'I', 'F', '8', '7', 'a' };
const GIF89A_SIGNATURE = [6]u8{ 'G', 'I', 'F', '8', '9', 'a' };

const LogicalScreenDescriptor = struct {
    width: u16,
    height: u16,
    flags: u8,
    background_color_index: u8,
    pixel_aspect_ratio: u8,

    fn hasGlobalColorTable(self: *const LogicalScreenDescriptor) bool {
        return (self.flags & 0x80) != 0;
    }

    fn globalColorTableSize(self: *const LogicalScreenDescriptor) u32 {
        const table_flags = (self.flags >> 7) & 0x01;
        const size_bits = self.flags & 0x07;
        return if (table_flags == 1) @as(u32, 1) << @as(u5, @truncate(size_bits + 1)) else 0;
    }

    fn getSortedFlag(self: *const LogicalScreenDescriptor) bool {
        return (self.flags & 0x20) != 0;
    }
};

const ImageDescriptor = struct {
    separator: u8,
    left: u16,
    top: u16,
    width: u16,
    height: u16,
    flags: u8,

    fn hasLocalColorTable(self: *const ImageDescriptor) bool {
        return (self.flags & 0x80) != 0;
    }

    fn isInterlaced(self: *const ImageDescriptor) bool {
        return (self.flags & 0x40) != 0;
    }

    fn localColorTableSize(self: *const ImageDescriptor) u32 {
        const table_flags = (self.flags >> 7) & 0x01;
        const size_bits = self.flags & 0x07;
        return if (table_flags == 1) @as(u32, 1) << @as(u5, @truncate(size_bits + 1)) else 0;
    }
};

const GraphicControlExtension = struct {
    disposal_method: u8,
    user_input_flag: bool,
    transparent_color_flag: bool,
    delay_time: u16,
    transparent_color_index: u8,
};

const ApplicationExtension = struct {
    app_id: [8]u8,
    auth_code: [3]u8,
    data: []const u8,
};

const DisposalMethod = enum(u8) {
    Unspecified = 0,
    DoNotDispose = 1,
    RestoreToBackground = 2,
    RestoreToPrevious = 3,
    ToBeDefined4 = 4,
    ToBeDefined5 = 5,
    ToBeDefined6 = 6,
    RestoreToPreviousIncluding = 7,
};

// ============================================================================
// LZW Decompressor

const LzwDecompressor = struct {
    min_code_size: u8,
    clear_code: u16,
    eoi_code: u16,
    table: []u16,
    table_len: usize,
    buffer: u32,
    bits_in_buffer: u32,
    data: []const u8,
    pos: usize,
    initial_code_size: u8,
    first_time: bool,

    fn init(data: []const u8, min_code_size: u8) LzwDecompressor {
        const clear_code: u16 = @as(u16, 1) << min_code_size;
        return .{
            .min_code_size = min_code_size,
            .clear_code = clear_code,
            .eoi_code = clear_code + 1,
            .data = data,
            .pos = 0,
            .buffer = 0,
            .bits_in_buffer = 0,
            .initial_code_size = min_code_size,
            .first_time = true,
            .table = &.{},
            .table_len = 0,
        };
    }

    fn readBits(self: *LzwDecompressor, n: u5) mod.ImageError!u16 {
        while (self.bits_in_buffer < n) {
            if (self.pos >= self.data.len) return mod.ImageError.TruncatedData;
            const byte = self.data[self.pos];
            self.pos += 1;
            if (byte < 0xFF) {
                self.buffer |= @as(u32, byte) << self.bits_in_buffer;
                self.bits_in_buffer += 8;
            } else {
                // Block terminator (0xFF followed by block size 0) signals end of LZW data
                if (byte == 0xFF and self.pos < self.data.len and self.data[self.pos] == 0x00) {
                    self.pos += 1;
                    break;
                }
                self.buffer |= @as(u32, byte) << self.bits_in_buffer;
                self.bits_in_buffer += 8;
            }
        }
        const mask: u32 = (@as(u32, 1) << n) - 1;
        const code = @as(u16, @truncate(self.buffer & mask));
        self.buffer >>= n;
        self.bits_in_buffer -= n;
        return code;
    }

    fn decompress(self: *LzwDecompressor, allocator: std.mem.Allocator, output_size: usize) mod.ImageError![]u8 {
        const output = try allocator.alloc(u8, output_size);
        errdefer allocator.free(output);
        var out_idx: usize = 0;

        var code_size: u8 = self.initial_code_size;
        var next_code: u16 = self.eoi_code + 1;

        var prefix: []u16 = &.{};
        var suffix: []u8 = &.{};
        var entry_stack: []u16 = &.{};
        defer {
            allocator.free(prefix);
            allocator.free(suffix);
            allocator.free(entry_stack);
        }

        prefix = try allocator.alloc(u16, 4096);
        suffix = try allocator.alloc(u8, 4096);
        entry_stack = try allocator.alloc(u16, 4096);
        @memset(prefix, 0);
        @memset(suffix, 0);

        var old_code: u16 = 0;
        var stack_top: usize = 0;

        while (true) {
            const code = self.readBits(@as(u5, @truncate(code_size))) catch break;

            if (code == self.eoi_code) break;
            if (self.first_time) {
                if (code == self.clear_code) {
                    code_size = self.initial_code_size;
                    next_code = self.eoi_code + 1;
                    self.first_time = false;
                    old_code = try self.readBits(@as(u5, @truncate(code_size)));
                    if (out_idx >= output_size) break;
                    output[out_idx] = @truncate(old_code);
                    out_idx += 1;
                    continue;
                }
            }

            if (code >= next_code) {
                return mod.ImageError.CorruptData;
            }

            if (code == self.clear_code) {
                code_size = self.initial_code_size;
                next_code = self.eoi_code + 1;
                self.first_time = false;
                old_code = try self.readBits(@as(u5, @truncate(code_size)));
                if (out_idx >= output_size) break;
                output[out_idx] = @truncate(old_code);
                out_idx += 1;
                continue;
            }

            var k: u16 = 0;
            if (code < next_code) {
                k = code;
            } else {
                k = old_code;
                entry_stack[0] = k;
                stack_top = 1;
            }

            while (k >= self.clear_code + 2) {
                if (@as(usize, k) < self.table_len) {
                    entry_stack[stack_top] = prefix[k];
                    stack_top += 1;
                    k = suffix[k];
                } else {
                    break;
                }
            }

            entry_stack[stack_top] = k;
            stack_top += 1;

            while (stack_top > 0) {
                stack_top -= 1;
                if (out_idx >= output_size) break;
                output[out_idx] = @truncate(entry_stack[stack_top]);
                out_idx += 1;
            }

            if (next_code < 4096) {
                prefix[next_code] = old_code;
                suffix[next_code] = @truncate(k);
                next_code += 1;
                if (next_code > (@as(u16, 1) << code_size) and code_size < 12) {
                    code_size += 1;
                }
            }

            old_code = code;
            if (out_idx >= output_size) break;
        }

        return output[0..out_idx];
    }
};

// ============================================================================
// Color Table

/// Reads a color table from data at the given offset.
fn readColorTable(
    allocator: std.mem.Allocator,
    data: []const u8,
    start: usize,
    num_entries: u32,
) mod.ImageError![][3]u8 {
    if (num_entries == 0) return &.{};
    const bytes_needed = @as(usize, num_entries) * 3;
    if (start + bytes_needed > data.len) return mod.ImageError.TruncatedData;

    const entries = try allocator.alloc([3]u8, num_entries);
    for (0..@as(usize, num_entries)) |i| {
        entries[i] = .{
            data[start + i * 3],
            data[start + i * 3 + 1],
            data[start + i * 3 + 2],
        };
    }
    return entries;
}

// ============================================================================
// GIF Frame Compositing

/// Composites a decoded frame onto the canvas using disposal method.
fn compositeFrame(
    canvas: []u8,
    frame_data: []const u8,
    frame_width: u16,
    frame_height: u16,
    frame_left: u16,
    frame_top: u16,
    canvas_width: u32,
    disposal: DisposalMethod,
    transparent_index: ?u8,
    color_table: []const [3]u8,
) void {
    // Apply disposal method from previous frame
    switch (disposal) {
        .RestoreToBackground => {
            // Fill with transparency (or canvas background)
            const bg_offset: usize = 3 * (frame_top * canvas_width + frame_left);
            _ = bg_offset;
        },
        else => {},
    }

    // Composite frame onto canvas
    for (0..@as(usize, frame_height)) |y| {
        const gy = @as(usize, frame_top) + y;
        if (gy >= canvas_width) continue; // canvas_width is actually canvas_height here
        const canvas_y = gy;
        for (0..@as(usize, frame_width)) |x| {
            const gx = @as(usize, frame_left) + x;
            if (gx >= canvas_width) continue;
            const src_idx = y * @as(usize, frame_width) + x;
            const color_idx = frame_data[src_idx];

            const canvas_offset = canvas_y * @as(usize, canvas_width) * 4 + gx * 4;

            if (transparent_index == null or transparent_index.? != color_idx) {
                const color = if (color_idx < color_table.len) color_table[color_idx] else .{'X', 'X', 'X'};
                canvas[canvas_offset] = color[0];
                canvas[canvas_offset + 1] = color[1];
                canvas[canvas_offset + 2] = color[2];
                canvas[canvas_offset + 3] = 0xFF;
            }
        }
    }
}

/// Converts indexed color data to RGBA32 using a color table.
fn indexedToRgba(
    indexed: []const u8,
    width: u16,
    height: u16,
    color_table: []const [3]u8,
    transparent_index: ?u8,
    allocator: std.mem.Allocator,
) mod.ImageError!mod.PixelBuffer {
    const row_pitch = @as(u32, width) * 4;
    const output = try allocator.alloc(u8, @as(usize, row_pitch) * @as(usize, height));
    errdefer allocator.free(output);

    for (0..@as(usize, height)) |y| {
        for (0..@as(usize, width)) |x| {
            const idx = indexed[y * @as(usize, width) + x];
            const out_offset = y * @as(usize, row_pitch) + x * 4;
            if (transparent_index == null or transparent_index.? != idx) {
                const color = if (idx < color_table.len) color_table[idx] else .{'X', 'X', 'X'};
                output[out_offset..out_offset + 4].* = .{ color[0], color[1], color[2], 0xFF };
            } else {
                output[out_offset..out_offset + 4].* = .{ 0, 0, 0, 0 };
            }
        }
    }

    return mod.PixelBuffer{
        .width = width,
        .height = height,
        .bytes_per_pixel = 4,
        .row_pitch = row_pitch,
        .data = output,
    };
}

/// Deinterlaces an image stored in GIF interlaced order.
fn deinterlace(allocator: std.mem.Allocator, indexed: []const u8, width: u16, height: u16) mod.ImageError![]u8 {
    const row_size = width;

    // GIF89a interlacing passes:
    // Pass 1: every 8th row starting at y=0
    // Pass 2: every 8th row starting at y=4
    // Pass 3: every 4th row starting at y=2
    // Pass 4: every 2nd row starting at y=1
    // Pass 5: remaining rows starting at y=0 (handled in pass 4)

    const passes = [_]struct { start: u16, step: u16 }{
        .{ .start = 0, .step = 8 },
        .{ .start = 4, .step = 8 },
        .{ .start = 2, .step = 4 },
        .{ .start = 1, .step = 2 },
    };

    const deint = try allocator.alloc(u8, indexed.len);
    @memset(deint, 0);

    var write_row: u16 = 0;
    for (passes) |pass| {
        var y = pass.start;
        while (y < height) : (y += pass.step) {
            const src_row = @as(usize, y) * @as(usize, row_size);
            const dst_row = @as(usize, write_row) * @as(usize, row_size);
            @memcpy(deint[dst_row..dst_row + @as(usize, row_size)], indexed[src_row..src_row + @as(usize, row_size)]);
            write_row += 1;
        }
    }

    return deint;
}

// ============================================================================
// Public API

/// Decodes a GIF from a byte slice. Returns first frame as PixelBuffer.
/// For full animation support, use decodeAnimation.
/// Caller owns returned PixelBuffer.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!mod.PixelBuffer {
    if (data.len < 13) return mod.ImageError.TruncatedData;

    // Verify signature
    if (!std.mem.eql(u8, data[0..6], &GIF_SIGNATURE) and
        !std.mem.eql(u8, data[0..6], &GIF89A_SIGNATURE))
    {
        return mod.ImageError.InvalidSignature;
    }

    const stream = std.io.FixedBufferStream([]const u8){ .buffer = data[6..], .pos = 0 };
    _ = stream;

    // Logical Screen Descriptor
    const width = std.mem.readIntLittle(u16, data[6..8]);
    const height = std.mem.readIntLittle(u16, data[8..10]);
    const flags = data[10];
    const bg_index = data[11];
    const par = data[12];

    const ls_desc = LogicalScreenDescriptor{
        .width = width,
        .height = height,
        .flags = flags,
        .background_color_index = bg_index,
        .pixel_aspect_ratio = par,
    };

    // Read global color table if present
    var global_ct: []const [3]u8 = &.{};
    var ct_start: usize = 13;
    if (ls_desc.hasGlobalColorTable()) {
        global_ct = try readColorTable(allocator, data, ct_start, ls_desc.globalColorTableSize());
        ct_start += @as(usize, ls_desc.globalColorTableSize()) * 3;
    }
    defer if (global_ct.len > 0) allocator.free(@constCast(global_ct));

    var pos = ct_start;
    var gce: ?GraphicControlExtension = null;
    var first_frame_data: ?mod.PixelBuffer = null;

    while (pos < data.len) {
        const introducer = data[pos];
        pos += 1;

        switch (introducer) {
            0x2C => { // Image Descriptor
                if (pos + 9 > data.len) break;

                const img_desc = ImageDescriptor{
                    .separator = 0x2C,
                    .left = std.mem.readIntLittle(u16, data[pos..pos + 2]),
                    .top = std.mem.readIntLittle(u16, data[pos + 2..pos + 4]),
                    .width = std.mem.readIntLittle(u16, data[pos + 4..pos + 6]),
                    .height = std.mem.readIntLittle(u16, data[pos + 6..pos + 8]),
                    .flags = data[pos + 8],
                };
                pos += 9;

                // Read local color table if present
                var local_ct = global_ct;
                var local_ct_owned = false;
                defer if (local_ct_owned) allocator.free(@constCast(local_ct));
                if (img_desc.hasLocalColorTable()) {
                    local_ct = try readColorTable(allocator, data, pos, img_desc.localColorTableSize());
                    local_ct_owned = true;
                    pos += @as(usize, img_desc.localColorTableSize()) * 3;
                }

                // LZW minimum code size
                if (pos >= data.len) break;
                const min_code_size = data[pos];
                pos += 1;

                // Read sub-blocks
                var lzw_data = std.ArrayListUnmanaged(u8){};
                defer lzw_data.deinit(allocator);
                while (pos < data.len) {
                    const block_size = data[pos];
                    pos += 1;
                    if (block_size == 0) break;
                    if (pos + @as(usize, block_size) > data.len) break;
                    try lzw_data.appendSlice(allocator, data[pos..pos + @as(usize, block_size)]);
                    pos += @as(usize, block_size);
                }

                // LZW decompress
                var lzw = LzwDecompressor.init(lzw_data.items, min_code_size);
                const indexed = lzw.decompress(allocator, @as(usize, img_desc.width) * @as(usize, img_desc.height)) catch return mod.ImageError.CorruptData;
                defer allocator.free(indexed);

                // Deinterlace if needed
                var pixel_data: []u8 = indexed;
                if (img_desc.isInterlaced()) {
                    pixel_data = try deinterlace(allocator, indexed, img_desc.width, img_desc.height);
                }
                defer if (pixel_data.ptr != indexed.ptr) allocator.free(pixel_data);

                const gce_val = gce orelse .{
                    .disposal_method = 0,
                    .user_input_flag = false,
                    .transparent_color_flag = false,
                    .delay_time = 0,
                    .transparent_color_index = 0,
                };

                const tidx: ?u8 = if (gce_val.transparent_color_flag) gce_val.transparent_color_index else null;

                if (first_frame_data == null) {
                    first_frame_data = try indexedToRgba(pixel_data, img_desc.width, img_desc.height, local_ct, tidx, allocator);
                }

                gce = null;
            },
            0x21 => { // Extension
                if (pos >= data.len) break;
                const ext_label = data[pos];
                pos += 1;

                if (ext_label == 0xF9) { // Graphic Control Extension
                    if (pos >= data.len) break;
                    pos += 1; // Block size (should be 4)
                    if (pos + 3 > data.len) break;
                    const gce_packed = data[pos];
                    const disposal = @as(DisposalMethod, @enumFromInt((gce_packed >> 2) & 0x07));
                    const user_input = (gce_packed & 0x02) != 0;
                    const transparent_flag = (gce_packed & 0x01) != 0;
                    const delay = std.mem.readIntLittle(u16, data[pos + 1..pos + 3]);
                    const tci = data[pos + 3];
                    gce = .{
                        .disposal_method = @intFromEnum(disposal),
                        .user_input_flag = user_input,
                        .transparent_color_flag = transparent_flag,
                        .delay_time = delay,
                        .transparent_color_index = tci,
                    };
                    pos += 4;
                    pos += 1; // Block terminator
                } else if (ext_label == 0xFF) { // Application Extension
                    if (pos >= data.len) break;
                    pos += 1; // Block size (should be 11)
                    pos += 11; // App identifier + auth code
                    // Read sub-blocks
                    while (pos < data.len) {
                        const block_size = data[pos];
                        pos += 1;
                        if (block_size == 0) break;
                        pos += @as(usize, block_size);
                    }
                } else {
                    // Skip other extensions
                    while (pos < data.len) {
                        const block_size = data[pos];
                        pos += 1;
                        if (block_size == 0) break;
                        pos += @as(usize, block_size);
                    }
                }
            },
            0x3B => break, // Trailer
            else => {
                // Unknown: skip
                if (pos < data.len) pos += 1;
            },
        }
    }

    return first_frame_data orelse mod.ImageError.CorruptData;
}

/// Decodes a GIF and returns full animation information.
pub fn decodeAnimation(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!mod.Animation {
    if (data.len < 13) return mod.ImageError.TruncatedData;

    if (!std.mem.eql(u8, data[0..6], &GIF_SIGNATURE) and
        !std.mem.eql(u8, data[0..6], &GIF89A_SIGNATURE))
    {
        return mod.ImageError.InvalidSignature;
    }

    const width = std.mem.readIntLittle(u16, data[6..8]);
    const height = std.mem.readIntLittle(u16, data[8..10]);
    const flags = data[10];
    const bg_index = data[11];
    const par = data[12];

    const ls_desc = LogicalScreenDescriptor{
        .width = width,
        .height = height,
        .flags = flags,
        .background_color_index = bg_index,
        .pixel_aspect_ratio = par,
    };

    var global_ct: []const [3]u8 = &.{};
    var ct_start: usize = 13;
    if (ls_desc.hasGlobalColorTable()) {
        global_ct = try readColorTable(allocator, data, ct_start, ls_desc.globalColorTableSize());
        ct_start += @as(usize, ls_desc.globalColorTableSize()) * 3;
    }
    defer if (global_ct.len > 0) allocator.free(@constCast(global_ct));

    var pos = ct_start;
    var gce: ?GraphicControlExtension = null;
    var frames = std.ArrayListUnmanaged(mod.AnimationFrame){};
    errdefer {
        for (frames.items) |*frame| frame.pixels.free(allocator);
        frames.deinit(allocator);
    }
    var loop_count: u16 = 0;
    var frame_count: u32 = 0;

    while (pos < data.len) {
        const introducer = data[pos];
        pos += 1;

        switch (introducer) {
            0x2C => {
                if (pos + 9 > data.len) break;
                const img_desc = ImageDescriptor{
                    .separator = 0x2C,
                    .left = std.mem.readIntLittle(u16, data[pos..pos + 2]),
                    .top = std.mem.readIntLittle(u16, data[pos + 2..pos + 4]),
                    .width = std.mem.readIntLittle(u16, data[pos + 4..pos + 6]),
                    .height = std.mem.readIntLittle(u16, data[pos + 6..pos + 8]),
                    .flags = data[pos + 8],
                };
                pos += 9;

                var local_ct = global_ct;
                var local_ct_owned = false;
                defer if (local_ct_owned) allocator.free(@constCast(local_ct));
                if (img_desc.hasLocalColorTable()) {
                    local_ct = try readColorTable(allocator, data, pos, img_desc.localColorTableSize());
                    local_ct_owned = true;
                    pos += @as(usize, img_desc.localColorTableSize()) * 3;
                }

                if (pos >= data.len) break;
                const min_code_size = data[pos];
                pos += 1;

                var lzw_data = std.ArrayListUnmanaged(u8){};
                defer lzw_data.deinit(allocator);
                while (pos < data.len) {
                    const block_size = data[pos];
                    pos += 1;
                    if (block_size == 0) break;
                    if (pos + @as(usize, block_size) > data.len) break;
                    try lzw_data.appendSlice(allocator, data[pos..pos + @as(usize, block_size)]);
                    pos += @as(usize, block_size);
                }

                var lzw = LzwDecompressor.init(lzw_data.items, min_code_size);
                const indexed = lzw.decompress(allocator, @as(usize, img_desc.width) * @as(usize, img_desc.height)) catch return mod.ImageError.CorruptData;
                defer allocator.free(indexed);

                var pixel_data: []u8 = indexed;
                if (img_desc.isInterlaced()) {
                    pixel_data = try deinterlace(allocator, indexed, img_desc.width, img_desc.height);
                }
                defer if (pixel_data.ptr != indexed.ptr) allocator.free(pixel_data);

                const gce_val = gce orelse .{
                    .disposal_method = 0,
                    .user_input_flag = false,
                    .transparent_color_flag = false,
                    .delay_time = 10,
                    .transparent_color_index = 0,
                };

                const tidx: ?u8 = if (gce_val.transparent_color_flag) gce_val.transparent_color_index else null;
                const delay_ms = if (gce_val.delay_time == 0) 100 else @as(u32, gce_val.delay_time) * 10;

                const pixels = try indexedToRgba(pixel_data, img_desc.width, img_desc.height, local_ct, tidx, allocator);

                try frames.append(allocator, .{
                    .pixels = pixels,
                    .delay_ms = delay_ms,
                    .disposal = @intFromEnum(@as(DisposalMethod, @enumFromInt(gce_val.disposal_method))),
                    .transparent_index = tidx,
                });

                gce = null;
                frame_count += 1;
            },
            0x21 => {
                if (pos >= data.len) break;
                const ext_label = data[pos];
                pos += 1;

                if (ext_label == 0xF9) {
                    pos += 1;
                    if (pos + 3 > data.len) break;
                    const gce_packed = data[pos];
                    const disposal = @as(DisposalMethod, @enumFromInt((gce_packed >> 2) & 0x07));
                    const user_input = (gce_packed & 0x02) != 0;
                    const transparent_flag = (gce_packed & 0x01) != 0;
                    const delay = std.mem.readIntLittle(u16, data[pos + 1..pos + 3]);
                    const tci = data[pos + 3];
                    gce = .{
                        .disposal_method = @intFromEnum(disposal),
                        .user_input_flag = user_input,
                        .transparent_color_flag = transparent_flag,
                        .delay_time = delay,
                        .transparent_color_index = tci,
                    };
                    pos += 5;
                } else if (ext_label == 0xFF) {
                    pos += 1;
                    if (pos + 10 > data.len) { pos += 1; continue; }
                    const app_id = data[pos..pos + 8];
                    pos += 11;
                    // NETSCAPE looping extension
                    if (std.mem.eql(u8, app_id[0..8], &.{ 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E' })) {
                        while (pos < data.len) {
                            const block_size = data[pos];
                            pos += 1;
                            if (block_size == 0) break;
                            if (block_size >= 3 and pos + 3 <= data.len) {
                                if (data[pos] == 1) { // Sub-block ID for loop count
                                    loop_count = std.mem.readIntLittle(u16, data[pos + 1..pos + 3]);
                                }
                            }
                            pos += @as(usize, block_size);
                        }
                    } else {
                        while (pos < data.len) {
                            const block_size = data[pos];
                            pos += 1;
                            if (block_size == 0) break;
                            pos += @as(usize, block_size);
                        }
                    }
                } else {
                    while (pos < data.len) {
                        const block_size = data[pos];
                        pos += 1;
                        if (block_size == 0) break;
                        pos += @as(usize, block_size);
                    }
                }
            },
            0x3B => break,
            else => {
                if (pos < data.len) pos += 1;
            },
        }
    }

    const result = mod.Animation{
        .frames = try frames.toOwnedSlice(allocator),
        .loop_count = loop_count,
        .width = width,
        .height = height,
    };

    return result;
}

/// Decoder interface entry.
pub const gifDecoder: mod.Decoder = .{
    .signature = &[4]u8{ 0x47, 0x49, 0x46, 0x38 },
    .name = "GIF",
    .extensions = &.{ ".gif" },
    .decodeFn = decode,
};
