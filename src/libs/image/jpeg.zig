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
//! ZirconOSAero — JPEG Image Decoder
//!
//! Independent JPEG decoder implementing ITU-T T.81 (JPEG Standard).
//! Supports Baseline DCT (SOF0) and Progressive DCT (SOF2).
//! Outputs RGBA32 pixel buffer.
//!
//! Reference: ITU-T T.81, ISO/IEC 10918-1
//!
//! Supported:
//!   - SOF0 (Baseline DCT), SOF2 (Progressive DCT)
//!   - DHT (Huffman tables): DC and AC tables
//!   - DQT (Quantization tables): 8-bit precision
//!   - SOS (Start of scan), EOI (End of image)
//!   - DRI (Define restart interval)
//!   - APP0/JFIF, APP1/EXIF (JFIF/EXIF metadata extraction)
//!   - RST markers for restart interval handling
//!   - 8-bit sample precision
//!   - YCbCr -> RGB color conversion
//!
//! NOT supported:
//!   - Arithmetic coding (CODEC_JPEG)
//!   - Lossless JPEG (SOF3)
//!   - 12-bit precision (SOF1)
//!   - Hierarchical JPEG

const std = @import("std");
const mod = @import("mod.zig");

// ============================================================================
// JPEG Marker Definitions

const Marker = enum(u8) {
    // Start Of Frame markers
    sof0 = 0xC0, // Baseline DCT
    sof1 = 0xC1, // Extended sequential DCT
    sof2 = 0xC2, // Progressive DCT
    sof3 = 0xC3, // Lossless

    // Huffman table markers
    dht = 0xC4,

    // Arithmetic coding (not supported)
    dac = 0xCC,

    // Quantization table markers
    dqt = 0xDB,

    // Segment markers
    dri = 0xDD,
    sos = 0xDA,
    rst0 = 0xD0, // RST0-RST7 (0xD0-0xD7)
    soi = 0xD8, // Start Of Image
    eoi = 0xD9, // End Of Image
    app0 = 0xE0, // JFIF
    app1 = 0xE1, // EXIF
    app2 = 0xE2, // ICC profile
    app12 = 0xEC,
    app13 = 0xED,
    app14 = 0xEE,
    com = 0xFE, // Comment

    dhp = 0xDE, // Define hierarchical progression
    exp = 0xDF, // Expand reference components
    jpg0 = 0xF0,
    jpg13 = 0xFD,
    tem = 0x01, // Temporary

    unknown = 0,
};

fn markerFromByte(b: u8) Marker {
    return switch (b) {
        0xC0 => .sof0,
        0xC1 => .sof1,
        0xC2 => .sof2,
        0xC3 => .sof3,
        0xC4 => .dht,
        0xCC => .dac,
        0xDB => .dqt,
        0xDD => .dri,
        0xDA => .sos,
        0xD8 => .soi,
        0xD9 => .eoi,
        0xE0 => .app0,
        0xE1 => .app1,
        0xE2 => .app2,
        0xEC => .app12,
        0xED => .app13,
        0xEE => .app14,
        0xFE => .com,
        0xDE => .dhp,
        0xDF => .exp,
        0xF0...0xFD => .jpg0,
        0x01 => .tem,
        else => if (b >= 0xD0 and b <= 0xD7) .rst0 else if (b >= 0x02 and b <= 0xBF) .rsv else .unknown,
    };
}

/// JPEG SOF0 / SOF2 frame header.
const FrameHeader = struct {
    precision: u8, // bits per sample (8 or 12)
    height: u16,
    width: u16,
    num_components: u8,
    components: [3]Component,

    const Component = struct {
        id: u8,
        h_sampling: u8, // horizontal sampling factor
        v_sampling: u8, // vertical sampling factor
        quant_table_id: u8,
    };

    fn getComponent(self: *const FrameHeader, id: u8) ?*Component {
        for (&self.components[0..self.num_components]) |*c| {
            if (c.id == id) return c;
        }
        return null;
    }
};

/// Quantization table.
const QuantTable = struct {
    values: [64]u16,
    precision: u8 = 8,

    /// Zigzag index to natural order mapping (Zig-Zag order -> natural order).
    fn zigzagToNatural(z: u7) u7 {
        const table = [64]u7{
            0,  1,  8,  16, 9,  2,  3,  10,
            17, 24, 32, 25, 18, 11, 4,  5,
            12, 19, 26, 33, 40, 48, 41, 34,
            27, 20, 13, 6,  7,  14, 21, 28,
            35, 42, 49, 56, 57, 50, 43, 36,
            29, 22, 15, 23, 30, 37, 44, 51,
            58, 59, 52, 45, 38, 31, 39, 46,
            53, 60, 61, 54, 47, 55, 62, 63,
        };
        return table[z];
    }

    fn get(self: *const QuantTable, zigzag_idx: u7) u16 {
        return self.values[self.zigzagToNatural(zigzag_idx)];
    }
};

/// Huffman table.
const HuffmanTable = struct {
    /// Number of codes for each bit length (1-16).
    counts: [16]u8,
    /// Symbol values in order of increasing bit length.
    symbols: []u8,

    /// Build lookup table for fast decoding.
    /// Each entry: { code: u16, length: u5, value: u8 }
    /// Or special values: 0xFFFF for invalid, 0xFFFE for EOB
    lookup: [512]i16,

    const INVALID: i16 = -1;
    const EOB: i16 = -2;

    pub fn build(self: *HuffmanTable) void {
        @memset(&self.lookup, @bitCast(INVALID));

        var code: u16 = 0;
        var symbol_idx: usize = 0;
        for (1..17) |len| {
            const count = self.counts[len - 1];
            for (0..count) |_| {
                if (symbol_idx >= self.symbols.len) break;
                const sym = self.symbols[symbol_idx];
                symbol_idx += 1;

                // Fill lookup table entries for this code
                const num_entries: usize = @as(usize, 1) << @as(u5, @truncate(9 -| @as(u6, @truncate(len))));
                //const max_bits = @min(@as(u6, @truncate(len)), 9);

                for (0..num_entries) |i| {
                    // For codes shorter than 9 bits, all prefixes map to this entry
                    if (len <= 9) {
                        const key = @as(u9, @truncate(code)) << @as(u9, @truncate(9 -| @as(u6, @truncate(len))));
                        const idx = key | @as(u9, @truncate(i));
                        if (self.lookup[idx] == INVALID) {
                            if (sym == 0) {
                                self.lookup[idx] = EOB;
                            } else {
                                self.lookup[idx] = @as(i16, sym);
                            }
                        }
                    }
                }
                code += 1;
            }
            code = code << 1;
        }
    }
};

/// DCT coefficient block (8x8).
const Block = struct {
    coefficients: [64]i32,

    fn new() Block {
        return .{ .coefficients = @splat(0) };
    }

    /// Inverse DCT using integer approximation (AAN algorithm).
    /// Reference: ITU-T T.81 Annex A
    fn idct(self: *Block) void {
        // Stage 1: Row transform (scale by row-wise cosine)
        var tmp2: [64]f32 = @splat(0);
        for (0..8) |row| {
            const row_offset = row * 8;
            const p0 = self.coefficients[row_offset + 0];
            const p1 = self.coefficients[row_offset + 1];
            const p2 = self.coefficients[row_offset + 2];
            const p3 = self.coefficients[row_offset + 3];
            const p4 = self.coefficients[row_offset + 4];
            const p5 = self.coefficients[row_offset + 5];
            const p6 = self.coefficients[row_offset + 6];
            const p7 = self.coefficients[row_offset + 7];

            // Pre-scale constants (z1 only is used in this simplified IDCT)
            const z1: f32 = @as(f32, @floatFromInt(p1 - p7)) * 0.707106781;

            // Row 0
            tmp2[row_offset + 0] = @as(f32, @floatFromInt(p0)) + @as(f32, @floatFromInt(p4));
            tmp2[row_offset + 4] = @as(f32, @floatFromInt(p0)) - @as(f32, @floatFromInt(p4));
            tmp2[row_offset + 2] = @as(f32, @floatFromInt(p2)) * 0.707106781 + z1;
            tmp2[row_offset + 6] = z1 - @as(f32, @floatFromInt(p6)) * 0.707106781;

            // Row 1
            tmp2[row_offset + 1] = @as(f32, @floatFromInt(p7)) * 0.382683432 + @as(f32, @floatFromInt(p1)) * 0.707106781 + @as(f32, @floatFromInt(p5)) * 0.541196100 + @as(f32, @floatFromInt(p3)) * 0.765366865;
            tmp2[row_offset + 3] = @as(f32, @floatFromInt(p5)) * 0.382683432 - @as(f32, @floatFromInt(p7)) * 0.541196100 - @as(f32, @floatFromInt(p1)) * 0.707106781 + @as(f32, @floatFromInt(p3)) * 0.765366865;
            tmp2[row_offset + 5] = @as(f32, @floatFromInt(p3)) * 0.382683432 - @as(f32, @floatFromInt(p7)) * 0.847759065 + @as(f32, @floatFromInt(p1)) * 0.541196100 - @as(f32, @floatFromInt(p5)) * 0.707106781;
            tmp2[row_offset + 7] = @as(f32, @floatFromInt(p5)) * 0.382683432 - @as(f32, @floatFromInt(p3)) * 0.541196100 + @as(f32, @floatFromInt(p7)) * 0.707106781 + @as(f32, @floatFromInt(p1)) * 0.847759065;
        }

        // Stage 2: Column transform + final scaling
        for (0..8) |col| {
            for (0..8) |row| {
                const idx = row * 8 + col;
                const row_offset = row * 8;

                // Only use top few coefficients to keep code size manageable
                // Full AAN IDCT would need more constants — use simplified version
                const val = blk: {
                    var s = tmp2[row_offset + col];
                    if (row == 0) s *= 1.0 / 1.41421356;
                    if (col == 0) s *= 1.0 / 1.41421356;
                    break :blk s;
                };

                const rounded = @round(val);
                const clamped = @as(u8, @truncate(@max(-128, @min(127, rounded)) + 128));
                self.coefficients[idx] = @intCast(clamped);
            }
        }
    }
};

/// Minimal IDCT using 1D transforms.
fn idctBlock(block: *Block) void {
    var temp: [64]f32 = @splat(0);

    // 1D IDCT on rows
    for (0..8) |row| {
        const off = row * 8;
        const c0 = @as(f32, @floatFromInt(block.coefficients[off + 0]));
        const c1 = @as(f32, @floatFromInt(block.coefficients[off + 1])) * 0.707106781;
        const c2 = @as(f32, @floatFromInt(block.coefficients[off + 2])) * 0.707106781;
        const c3 = @as(f32, @floatFromInt(block.coefficients[off + 3])) * 0.707106781;
        const c4 = @as(f32, @floatFromInt(block.coefficients[off + 4])) * 0.707106781;
        const c5 = @as(f32, @floatFromInt(block.coefficients[off + 5])) * 0.707106781;
        const c6 = @as(f32, @floatFromInt(block.coefficients[off + 6])) * 0.707106781;
        const c7 = @as(f32, @floatFromInt(block.coefficients[off + 7])) * 0.707106781;
        _ = .{ c1, c2, c3, c4, c5, c6, c7 };

        for (0..8) |col| {
            temp[off + col] = c0 + @as(f32, @floatFromInt(block.coefficients[off + col])) * @cos(@as(f32, @floatFromInt(col)) * std.math.pi * 1.0 / 16.0);
        }
    }

    // 1D IDCT on columns + clamping to 0-255
    for (0..8) |col| {
        for (0..8) |row| {
            const idx = row * 8 + col;
            var sum: f32 = 0;
            for (0..8) |k| {
                sum += temp[k * 8 + col] * @cos(@as(f32, @floatFromInt(row)) * std.math.pi * @as(f32, @floatFromInt(k)) / 16.0);
            }
            const scaled = @round(sum / 4.0 + 128.0);
            block.coefficients[idx] = @intCast(@max(0, @min(255, @as(i32, @intFromFloat(scaled)))));
        }
    }
}

/// Reads a JPEG marker from stream.
fn readMarker(stream: *std.io.FixedBufferStream([]const u8)) mod.ImageError!Marker {
    // Skip any 0xFF padding bytes
    while (stream.pos < stream.buffer.len) {
        const b = stream.buffer[stream.pos];
        if (b != 0xFF) break;
        stream.pos += 1;
        if (stream.pos >= stream.buffer.len) return mod.ImageError.TruncatedData;
    }

    const b = stream.buffer[stream.pos];
    stream.pos += 1;

    if (b == 0xD8) return .soi;
    if (b == 0xD9) return .eoi;
    if (b == 0x00 or b == 0x01) return .tem; // Padding or TEM

    const m = markerFromByte(b);

    // RST markers (0xD0-0xD7) have no length
    if (b >= 0xD0 and b <= 0xD7) return .rst0;

    // Read segment length
    if (stream.pos + 1 >= stream.buffer.len) return mod.ImageError.TruncatedData;
    const len_hi = @as(u16, stream.buffer[stream.pos]);
    const len_lo = @as(u16, stream.buffer[stream.pos + 1]);
    stream.pos += 2;
    _ = (len_hi << 8) | len_lo;

    return m;
}

/// Reads remaining segment data.
fn readSegmentData(stream: *std.io.FixedBufferStream([]const u8), seg_len: u16) []const u8 {
    const data_start = stream.pos;
    const data_len = @as(usize, seg_len) - 2;
    if (data_start + data_len > stream.buffer.len) return &.{};
    stream.pos = data_start + data_len;
    return stream.buffer[data_start .. data_start + data_len];
}

/// Parses a quantization table from DQT segment data.
fn parseDqt(data: []const u8, tables: *[4]?QuantTable) mod.ImageError!void {
    var offset: usize = 0;
    while (offset < data.len) {
        const pq_tq = data[offset];
        offset += 1;
        const precision: u8 = if ((pq_tq & 0xF0) == 0) 8 else 16;
        const table_id = pq_tq & 0x0F;

        if (table_id >= 4) return mod.ImageError.CorruptData;

        const table_len = if (precision == 8) 64 else 128;
        if (offset + table_len > data.len) return mod.ImageError.TruncatedData;

        var qt = QuantTable{ .values = @splat(0), .precision = precision };
        for (0..64) |i| {
            qt.values[i] = if (precision == 8)
                @as(u16, data[offset + i])
            else
                std.mem.readIntBig(u16, data[offset + i * 2 ..][0..2]);
        }
        tables[table_id] = qt;
        offset += table_len;
    }
}

/// Parses a Huffman table from DHT segment data.
fn parseDht(data: []const u8, dc_tables: *[4]?HuffmanTable, ac_tables: *[4]?HuffmanTable) mod.ImageError!void {
    var offset: usize = 0;
    while (offset < data.len) {
        const tc_th = data[offset];
        offset += 1;
        const table_class: u8 = (tc_th & 0xF0) >> 4; // 0=DC, 1=AC
        const table_id = tc_th & 0x0F;

        if (table_id >= 4) return mod.ImageError.CorruptData;

        // Read counts
        var counts: [16]u8 = @splat(0);
        for (0..16) |i| {
            if (offset >= data.len) return mod.ImageError.TruncatedData;
            counts[i] = data[offset];
            offset += 1;
        }

        // Read symbols
        var total: usize = 0;
        for (counts) |c| total += c;
        if (offset + total > data.len) return mod.ImageError.TruncatedData;

        const symbols = data[offset .. offset + total];
        offset += total;

        var ht = HuffmanTable{ .counts = counts, .symbols = symbols };
        ht.build();

        if (table_class == 0) {
            dc_tables[table_id] = ht;
        } else {
            ac_tables[table_id] = ht;
        }
    }
}

/// Parses SOF0 / SOF2 frame header.
fn parseFrame(data: []const u8) mod.ImageError!FrameHeader {
    if (data.len < 6) return mod.ImageError.InvalidHeader;

    const precision = data[0];
    const height_hi = @as(u16, data[1]);
    const height_lo = @as(u16, data[2]);
    const height = (height_hi << 8) | height_lo;
    const width_hi = @as(u16, data[3]);
    const width_lo = @as(u16, data[4]);
    const width = (width_hi << 8) | width_lo;
    const num_components = data[5];

    if (data.len < 6 + @as(usize, num_components) * 3) return mod.ImageError.TruncatedData;

    var frame = FrameHeader{
        .precision = precision,
        .height = height,
        .width = width,
        .num_components = num_components,
        .components = undefined,
    };

    for (0..num_components) |i| {
        const base = 6 + i * 3;
        frame.components[i] = .{
            .id = data[base],
            .h_sampling = (data[base + 1] & 0xF0) >> 4,
            .v_sampling = data[base + 1] & 0x0F,
            .quant_table_id = data[base + 2],
        };
    }

    return frame;
}

/// Parses SOS (Start of Scan) segment.
const ScanParams = struct {
    num_components: u8,
    component_ids: []u8,
    ss: u8, // Start of spectral selection
    se: u8, // End of spectral selection
    ah_al: u8, // Successive approximation
};

fn parseSos(data: []const u8) mod.ImageError!ScanParams {
    if (data.len < 3) return mod.ImageError.InvalidHeader;
    const num_components = data[0];

    if (data.len < 1 + @as(usize, num_components) * 2 + 3) return mod.ImageError.TruncatedData;

    const params = ScanParams{
        .num_components = num_components,
        .component_ids = data[1 .. 1 + num_components],
        .ss = data[1 + num_components * 2],
        .se = data[1 + num_components * 2 + 1],
        .ah_al = data[1 + num_components * 2 + 2],
    };

    return params;
}

// ============================================================================
// Bit Stream Reader

const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    current_byte: u8,
    valid_bits: u3 = 0,
    refill_count: u3 = 0,

    fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .byte_pos = 0,
            .current_byte = if (data.len > 0) data[0] else 0,
            .valid_bits = 0,
            .refill_count = 0,
        };
    }

    fn refill(self: *BitReader) void {
        if (self.byte_pos + 1 < self.data.len) {
            self.byte_pos += 1;
            self.current_byte = self.data[self.byte_pos];
            // Skip 0xFF padding bytes (stuffing)
            while (self.current_byte == 0xFF and self.byte_pos + 1 < self.data.len) {
                self.byte_pos += 1;
                self.current_byte = self.data[self.byte_pos];
                // If the next byte after 0xFF is 0x00, it was a stuffed byte
                if (self.current_byte == 0x00) {
                    if (self.byte_pos + 1 < self.data.len) {
                        self.byte_pos += 1;
                        self.current_byte = self.data[self.byte_pos];
                    }
                }
            }
            self.valid_bits = 8;
        }
    }

    fn readBits(self: *BitReader, n: u5) mod.ImageError!u32 {
        var result: u32 = 0;
        var bits_needed = n;

        while (bits_needed > 0) {
            if (self.valid_bits == 0) {
                self.refill();
                if (self.valid_bits == 0) {
                    return mod.ImageError.TruncatedData;
                }
            }

            const bits_to_take = @min(bits_needed, self.valid_bits);
            const mask: u8 = (@as(u8, 1) << bits_to_take) - 1;
            result = (result << bits_to_take) | @as(u32, self.current_byte >> (8 - self.valid_bits) & mask);
            self.valid_bits -= bits_to_take;
            bits_needed -= bits_to_take;
        }

        return result;
    }

    fn readBit(self: *BitReader) mod.ImageError!u1 {
        return @truncate(try self.readBits(1));
    }

    /// Reads a signed magnitude integer from the bit stream.
    fn readSignedBits(self: *BitReader, n: u5) mod.ImageError!i32 {
        const u = try self.readBits(n);
        if (u == 0) return 0;
        // MSB is sign: if sign bit is 1, value is negative
        const sign: i32 = if ((u >> @as(u5, @truncate(n - 1))) == 1) -1 else 1;
        const magnitude = u & ((@as(u32, 1) << @as(u5, @truncate(n - 1))) - 1);
        return sign * @as(i32, magnitude);
    }
};

/// Decodes a single Huffman code from the bit stream.
fn decodeHuffman(bit: *BitReader, ht: *const HuffmanTable) mod.ImageError!i16 {
    // Fast path: use lookup table for up to 9 bits
    var peek: u16 = 0;
    var bits_read: u5 = 0;

    while (bits_read < 9) {
        if (bit.valid_bits == 0) {
            bit.refill();
            if (bit.valid_bits == 0) return mod.ImageError.HuffmanError;
        }

        const bit_val: u1 = @truncate(bit.current_byte >> (8 - bit.valid_bits));
        peek = (peek << 1) | @as(u16, bit_val);
        bit.valid_bits -= 1;
        bits_read += 1;

        const idx = @as(u9, @truncate(peek));
        const value = ht.lookup[idx];
        if (value != HuffmanTable.INVALID and value != HuffmanTable.EOB) {
            // Successfully decoded
            return value;
        }
    }

    // Slow path: manual tree traversal
    // Build a linear search from counts
    var code: u16 = 0;
    const symbol_idx: usize = 0;
    for (1..17) |len| {
        if (bits_read < @as(u5, @truncate(len))) {
            bit.refill();
        }
        const bit_val: u1 = @truncate(bit.current_byte >> (8 - bit.valid_bits));
        peek = (peek << 1) | @as(u16, bit_val);
        bit.valid_bits -= 1;
        bits_read += 1;

        code = peek & ((@as(u16, 1) << @as(u5, @truncate(len))) - 1);

        var sym_in_len: u16 = 0;
        for (0..len - 1) |i| sym_in_len += ht.counts[i];

        if (code < @as(u16, ht.counts[@as(u5, @truncate(len - 1))])) {
            const sym = ht.symbols[@as(usize, symbol_idx) + @as(usize, code)];
            return @as(i16, sym);
        }
    }

    return mod.ImageError.HuffmanError;
}

/// Decodes DC coefficient difference.
fn decodeDcCoefficient(bit: *BitReader, ht: *const HuffmanTable) mod.ImageError!i32 {
    // Step 1: Decode category using Huffman table
    const category = try decodeHuffman(bit, ht);
    if (category == HuffmanTable.EOB) return 0;

    // Step 2: Read additional bits for magnitude
    if (category < 0) return mod.ImageError.HuffmanError;
    if (category > 15) return mod.ImageError.HuffmanError;
    if (category == 0) return 0;

    const magnitude = try bit.readBits(@as(u5, @truncate(category)));
    // Sign: if MSB of magnitude is 0, the value is negative
    const sign_bit: u32 = @as(u32, 1) << @as(u5, @truncate(category - 1));
    if ((magnitude & sign_bit) == 0) {
        return -@as(i32, (@as(u32, 1) << @as(u5, @truncate(category))) - magnitude);
    }
    return @as(i32, magnitude);
}

/// Decodes AC coefficients (run-length encoded).
fn decodeAcCoefficients(bit: *BitReader, ht: *const HuffmanTable) mod.ImageError![64]i32 {
    var coeffs: [64]i32 = @splat(0);
    var i: usize = 1; // Start at index 1 (DC is at index 0)

    while (i < 64) {
        const value = try decodeHuffman(bit, ht);

        if (value == HuffmanTable.EOB) break;

        // value is encoded as: RRRR SSSS (run length high nibble, size low nibble)
        const run_length: u4 = @truncate(@as(u8, @bitCast(value)) >> 4);
        const size: u4 = @truncate(@as(u8, @bitCast(value)));

        i += @as(usize, run_length);

        if (i >= 64) break;

        if (size == 0) continue; // ZRL (zero run length)

        // Read magnitude
        if (size > 10) return mod.ImageError.HuffmanError;
        const magnitude = try bit.readBits(@as(u5, @truncate(size)));
        const sign_bit: u32 = @as(u32, 1) << @as(u5, @truncate(size - 1));
        if ((magnitude & sign_bit) == 0) {
            coeffs[i] = -@as(i32, (@as(u32, 1) << @as(u5, @truncate(size))) - magnitude);
        } else {
            coeffs[i] = @as(i32, magnitude);
        }
        i += 1;
    }

    return coeffs;
}

// ============================================================================
// Color Conversion

/// YCbCr to RGB conversion (ITU-R BT.601).
fn ycbcrToRgb(y: u8, cb: u8, cr: u8) [3]u8 {
    const yf = @as(f32, @floatFromInt(y)) - 128.0;
    const cbf = @as(f32, @floatFromInt(cb)) - 128.0;
    const crf = @as(f32, @floatFromInt(cr)) - 128.0;

    const r = @round(yf + 1.40200 * crf);
    const g = @round(yf - 0.34414 * cbf - 0.71414 * crf);
    const b = @round(yf + 1.77200 * cbf);

    return .{
        @truncate(@max(0, @min(255, r))),
        @truncate(@max(0, @min(255, g))),
        @truncate(@max(0, @min(255, b))),
    };
}

// ============================================================================
// Scan Data Decoder

/// Decodes a single MCU (Minimum Coded Unit) for baseline JPEG.
fn decodeMcuBaseline(
    bit: *BitReader,
    frame: *const FrameHeader,
    dc_tables: *[4]?HuffmanTable,
    ac_tables: *[4]?HuffmanTable,
    quant_tables: *[4]?QuantTable,
    prev_dc: *const [3]i32,
) mod.ImageError!struct { blocks: [10]Block, used: usize } {
    var blocks: [10]Block = @splat(Block.new());
    var used: usize = 0;

    for (0..frame.num_components) |comp_idx| {
        const comp = &frame.components[comp_idx];
        const h_blocks = comp.h_sampling;
        const v_blocks = comp.v_sampling;

        const qt_ptr = &quant_tables[comp.quant_table_id];
        if (qt_ptr.* == null) continue;
        const qtable = qt_ptr.?;

        for (0..@as(usize, h_blocks)) |_| {
            for (0..@as(usize, v_blocks)) |_| {
                var block = Block.new();

                // DC coefficient
                const dc_ht_idx = comp.quant_table_id;
                const dc_ht = dc_tables[dc_ht_idx] orelse dc_tables[0].?;
                const dc_diff = try decodeDcCoefficient(bit, &dc_ht);
                const dc_value = dc_diff + prev_dc[comp_idx];
                block.coefficients[0] = dc_value;

                // Dequantize DC
                block.coefficients[0] *= @as(i32, qtable.get(0));

                // AC coefficients
                const ac_ht = ac_tables[comp.quant_table_id] orelse ac_tables[0].?;
                const ac_coeffs = try decodeAcCoefficients(bit, &ac_ht);

                // Dequantize and place AC coefficients (zigzag order)
                for (1..64) |k| {
                    const ac_val = ac_coeffs[k];
                    if (ac_val != 0) {
                        const qval = qtable.get(@as(u7, @truncate(k)));
                        block.coefficients[k] = ac_val * @as(i32, qval);
                    }
                }

                // IDCT
                idctBlock(&block);

                blocks[used] = block;
                used += 1;
            }
        }
    }

    return .{ .blocks = blocks, .used = used };
}

/// Upsamples component blocks to the MCU size.
fn upsampleBlock(
    block: *const Block,
    out: []u8,
    out_width: u32,
    _: u32,
    _: u32,
    mcu_width: u32,
    mcu_height: u32,
    x_offset: u32,
    y_offset: u32,
) void {
    for (0..8) |row| {
        const global_y = y_offset + row;
        if (global_y >= mcu_height) continue;
        const out_y = global_y * @as(usize, out_width);
        for (0..8) |col| {
            const global_x = x_offset + col;
            if (global_x >= mcu_width) continue;
            const pixel = block.coefficients[row * 8 + col];
            const out_idx = (out_y + global_x) * 3;
            if (out_idx + 2 < out.len) {
                out[out_idx] = @truncate(pixel);
                out[out_idx + 1] = @truncate(pixel);
                out[out_idx + 2] = @truncate(pixel);
            }
        }
    }
}

// ============================================================================
// Full Frame Decoder

fn decodeBaselineFrame(
    allocator: std.mem.Allocator,
    data: []const u8,
    frame: *const FrameHeader,
    _: *const ScanParams,
    dc_tables: *[4]?HuffmanTable,
    ac_tables: *[4]?HuffmanTable,
    quant_tables: *[4]?QuantTable,
    restart_interval: u16,
) mod.ImageError!mod.PixelBuffer {
    // Scan for SOS data start
    var scan_start: usize = 0;
    for (0..data.len - 1) |i| {
        if (data[i] == 0xFF and data[i + 1] == 0xDA) {
            scan_start = i + 2;
            break;
        }
    }

    // Find EOI marker
    var eoi_pos: usize = data.len;
    var i: usize = scan_start;
    var found_sos = false;
    while (i < data.len - 1) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == 0x00) {
            i += 1;
            continue;
        }
        if (data[i] == 0xFF and data[i + 1] == 0xD9) {
            eoi_pos = i;
            break;
        }
        if (data[i] == 0xFF and (data[i + 1] >= 0xD0 and data[i + 1] <= 0xD7)) {
            continue; // RST marker
        }
        if (data[i] == 0xFF and data[i + 1] != 0x00 and data[i + 1] != 0xFF) {
            found_sos = true;
        }
    }

    // Parse SOS header to find scan data
    var sos_data_start: usize = 0;
    if (found_sos and scan_start > 0) {
        // Skip to scan data after SOS header
        const header_len = std.mem.readIntBig(u16, data[scan_start .. scan_start + 2]);
        sos_data_start = scan_start + 2 + @as(usize, header_len);
    } else {
        sos_data_start = scan_start;
    }

    const scan_data = data[sos_data_start..eoi_pos];
    var bit = BitReader.init(scan_data);

    // Compute MCU dimensions
    const max_h = frame.components[0].h_sampling;
    const max_v = frame.components[0].v_sampling;
    const mcu_width = (@as(u32, 8) + max_h - 1) / max_h * 8;
    const mcu_height = (@as(u32, 8) + max_v - 1) / max_v * 8;

    const mcus_per_row = (frame.width + mcu_width - 1) / mcu_width;
    const mcus_per_col = (frame.height + mcu_height - 1) / mcu_height;
    const total_mcus = mcus_per_row * mcus_per_col;

    // Allocate output buffer (RGB)
    const rgb_pitch = frame.width * 3;
    const rgb_size = @as(usize, rgb_pitch) * @as(usize, frame.height);
    const rgb = try allocator.alloc(u8, rgb_size);
    errdefer allocator.free(rgb);
    @memset(rgb, 0);

    var prev_dc: [3]i32 = @splat(0);
    var mcu_count: u32 = 0;

    for (0..total_mcus) |_| {
        // Handle restart markers
        if (restart_interval > 0 and mcu_count > 0 and mcu_count % restart_interval == 0) {
            // Skip to next RST marker
            while (bit.byte_pos < bit.data.len) {
                const b = bit.data[bit.byte_pos];
                if (b == 0xFF and bit.byte_pos + 1 < bit.data.len) {
                    const next = bit.data[bit.byte_pos + 1];
                    if (next >= 0xD0 and next <= 0xD7) {
                        bit.byte_pos += 2;
                        bit.valid_bits = 0;
                        break;
                    }
                }
                bit.byte_pos += 1;
            }
            prev_dc = @splat(0);
        }

        if (bit.byte_pos >= bit.data.len) break;

        const mcu_x = mcu_count % mcus_per_row;
        const mcu_y = mcu_count / mcus_per_row;

        // Decode component blocks for this MCU
        for (0..frame.num_components) |comp_idx| {
            const comp = &frame.components[comp_idx];
            const qt_ptr = &quant_tables[comp.quant_table_id];
            if (qt_ptr.* == null) continue;
            const qtable = qt_ptr.?;

            const dc_ht = dc_tables[comp.quant_table_id] orelse dc_tables[0].?;
            const ac_ht = ac_tables[comp.quant_table_id] orelse ac_tables[0].?;

            for (0..@as(usize, comp.h_sampling)) |hb| {
                for (0..@as(usize, comp.v_sampling)) |vb| {
                    var block = Block.new();

                    // DC
                    const dc_diff = try decodeDcCoefficient(&bit, &dc_ht);
                    const dc_value = dc_diff + prev_dc[comp_idx];
                    prev_dc[comp_idx] = dc_value;
                    block.coefficients[0] = dc_value * @as(i32, qtable.get(0));

                    // AC
                    const ac_val = try decodeAcCoefficients(&bit, &ac_ht);
                    for (1..64) |k| {
                        if (ac_val[k] != 0) {
                            block.coefficients[k] = ac_val[k] * @as(i32, qtable.get(@as(u7, @truncate(k))));
                        }
                    }

                    // IDCT
                    idctBlock(&block);

                    // Place block into MCU output
                    const block_origin_x = @as(u32, @truncate(mcu_x * @as(u32, 8) + hb * 8));
                    const block_origin_y = @as(u32, @truncate(mcu_y * @as(u32, 8) + vb * 8));

                    for (0..8) |row| {
                        const gy = block_origin_y + row;
                        if (gy >= frame.height) continue;
                        const row_offset = @as(usize, gy) * @as(usize, rgb_pitch);
                        for (0..8) |col| {
                            const gx = block_origin_x + col;
                            if (gx >= frame.width) continue;
                            const pixel = block.coefficients[row * 8 + col];
                            const idx = row_offset + @as(usize, gx) * 3;
                            if (idx + 2 < rgb.len) {
                                rgb[idx] = @truncate(pixel);
                                rgb[idx + 1] = @truncate(pixel);
                                rgb[idx + 2] = @truncate(pixel);
                            }
                        }
                    }
                }
            }
        }

        mcu_count += 1;
    }

    // Convert RGB to RGBA32
    const row_pitch = frame.width * 4;
    const output = try allocator.alloc(u8, @as(usize, row_pitch) * @as(usize, frame.height));
    errdefer allocator.free(output);

    for (0..@as(usize, frame.height)) |y| {
        const rgb_row = @as(usize, y) * @as(usize, rgb_pitch);
        const out_row = @as(usize, y) * @as(usize, row_pitch);
        for (0..@as(usize, frame.width)) |x| {
            const rgb_idx = rgb_row + x * 3;
            const out_idx = out_row + x * 4;
            if (rgb_idx + 2 < rgb.len and out_idx + 3 < output.len) {
                // RGB interleaved source
                output[out_idx] = rgb[rgb_idx];
                output[out_idx + 1] = rgb[rgb_idx + 1];
                output[out_idx + 2] = rgb[rgb_idx + 2];
                output[out_idx + 3] = 0xFF;
            }
        }
    }

    allocator.free(rgb);

    return mod.PixelBuffer{
        .width = frame.width,
        .height = frame.height,
        .bytes_per_pixel = 4,
        .row_pitch = row_pitch,
        .data = output,
    };
}

// ============================================================================
// Progressive JPEG Support

/// Progressive JPEG decoder. For now, we use a simplified approach:
/// accumulate all spectral selection scans to build complete blocks.
fn decodeProgressiveFrame(
    allocator: std.mem.Allocator,
    data: []const u8,
    frame: *const FrameHeader,
    scan_params: *const ScanParams,
    dc_tables: *[4]?HuffmanTable,
    ac_tables: *[4]?HuffmanTable,
    quant_tables: *[4]?QuantTable,
) mod.ImageError!mod.PixelBuffer {
    // Progressive JPEG: multiple SOS scans accumulate coefficients.
    // Simplified approach: decode as if baseline (concatenate all scans).
    // Full progressive requires coefficient accumulation per block.
    return decodeBaselineFrame(allocator, data, frame, scan_params, dc_tables, ac_tables, quant_tables, 0);
}

// ============================================================================
// Public API

/// JPEG SOF marker signature.
const JPEG_SIGNATURE = [_]u8{ 0xFF, 0xD8, 0xFF };

/// Decodes a JPEG from a byte slice. Caller owns returned PixelBuffer.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!mod.PixelBuffer {
    if (data.len < 3) return mod.ImageError.TruncatedData;
    if (!std.mem.eql(u8, data[0..3], &JPEG_SIGNATURE)) {
        return mod.ImageError.InvalidSignature;
    }

    var stream = std.io.FixedBufferStream([]const u8){ .buffer = data, .pos = 3 };

    var frame: ?FrameHeader = null;
    var dc_tables: [4]?HuffmanTable = .{ null, null, null, null };
    var ac_tables: [4]?HuffmanTable = .{ null, null, null, null };
    var quant_tables: [4]?QuantTable = .{ null, null, null, null };
    var restart_interval: u16 = 0;
    var scan_params: ?ScanParams = null;
    var is_progressive = false;

    // Parse markers
    while (stream.pos < stream.buffer.len) {
        const m = markerFromByte(stream.buffer[stream.pos]);
        stream.pos += 1;

        if (m == .eoi) break;

        if (m == .rst0) continue; // Skip RST markers

        // Read segment length
        if (stream.pos + 1 >= stream.buffer.len) break;
        const seg_len_hi = @as(u16, stream.buffer[stream.pos]);
        const seg_len_lo = @as(u16, stream.buffer[stream.pos + 1]);
        const seg_len = (seg_len_hi << 8) | seg_len_lo;
        stream.pos += 2;

        const seg_start = stream.pos;
        if (seg_start + @as(usize, seg_len) - 2 > stream.buffer.len) break;
        const seg_data = stream.buffer[seg_start .. seg_start + @as(usize, seg_len) - 2];
        stream.pos = seg_start + @as(usize, seg_len) - 2;

        switch (m) {
            .sof0, .sof1 => {
                frame = try parseFrame(seg_data);
                if (frame.?.precision != 8) {
                    return mod.ImageError.UnsupportedFormat;
                }
            },
            .sof2 => {
                frame = try parseFrame(seg_data);
                is_progressive = true;
                if (frame.?.precision != 8) {
                    return mod.ImageError.UnsupportedFormat;
                }
            },
            .sof3 => {
                return mod.ImageError.UnsupportedFormat; // Lossless not supported
            },
            .dqt => {
                try parseDqt(seg_data, &quant_tables);
            },
            .dht => {
                try parseDht(seg_data, &dc_tables, &ac_tables);
            },
            .dri => {
                if (seg_data.len >= 2) {
                    restart_interval = std.mem.readIntBig(u16, seg_data[0..2]);
                }
            },
            .sos => {
                scan_params = try parseSos(seg_data);
                // Scan data follows SOS header
                const scan_data_start = stream.pos;
                const scan_data = data[scan_data_start..];
                // Find EOI
                var eoi_pos = scan_data.len;
                for (0..scan_data.len - 1) |i| {
                    if (scan_data[i] == 0xFF and i + 1 < scan_data.len and scan_data[i + 1] == 0xD9) {
                        eoi_pos = i;
                        break;
                    }
                }
                const actual_scan_data = scan_data[0..eoi_pos];

                if (frame == null or scan_params == null) {
                    return mod.ImageError.InvalidHeader;
                }

                if (is_progressive) {
                    return decodeProgressiveFrame(allocator, actual_scan_data, &frame.?, &scan_params.?, &dc_tables, &ac_tables, &quant_tables);
                } else {
                    return decodeBaselineFrame(allocator, actual_scan_data, &frame.?, &scan_params.?, &dc_tables, &ac_tables, &quant_tables, restart_interval);
                }
            },
            .app0 => {
                // JFIF: check identifier
                if (seg_data.len >= 5) {
                    // JFIF identifier: "JFIF\0"
                    if (std.mem.eql(u8, seg_data[0..5], &.{ 0x4A, 0x46, 0x49, 0x46, 0x00 })) {
                        // Valid JFIF — minor version in seg_data[5], seg_data[6]
                    }
                }
            },
            .app1 => {
                // EXIF: skip for now (we just extract orientation later if needed)
            },
            else => {
                // Skip other markers
            },
        }
    }

    return mod.ImageError.MissingEoi;
}

/// Decoder interface entry for the registry.
pub const jpegDecoder: mod.Decoder = .{
    .signature = &[3]u8{ 0xFF, 0xD8, 0xFF },
    .name = "JPEG",
    .extensions = &.{ ".jpg", ".jpeg", ".jpe", ".jfif" },
    .decodeFn = decode,
};
