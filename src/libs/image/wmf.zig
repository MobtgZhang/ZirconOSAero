//! SPDX-License-Identifier: MIT OR Apache-2.0
//!
//! ZirconOSAero — WMF (Windows Metafile) Decoder
//!
//! Independent WMF decoder. WMF is a 16-bit vector graphics format.
//! Supports Aldus Placeable Metafiles and basic GDI record types.
//!
//! Reference:
//!   - Windows Metafile Format (MS-WMF)
//!   - Aldus Placeable Metafiles
//!
//! Supported GDI record types:
//!   META_HEADER (0x0001)
//!   SetWindowOrg (0x020B), SetWindowExt (0x020C)
//!   SetMapMode (0x0103), SetViewportOrg (0x0211), SetViewportExt (0x0212)
//!   Polyline (0x0325), Polygon (0x0324), Rectangle (0x0412)
//!   Ellipse (0x0418), Arc (0x0417), Chord (0x0430), Pie (0x0431)
//!   LineTo (0x0213), MoveTo (0x0214), SetPixel (0x041F)
//!   StretchBlt (0x0B41)
//!   SetBkMode (0x0102), SetBkColor (0x0201)
//!   SetTextColor (0x0209), SetTextAlign (0x012E)
//!   TextOut (0x0521), ExtTextOut (0x0A32)
//!   CreateBrush (0x02FA), CreatePen (0x02FA)
//!   SelectObject (0x012D), DeleteObject (0x01D0)
//!   SaveDC (0x001E), RestoreDC (0x0127)
//!   Escape (0x0626)

const std = @import("std");
const mod = @import("mod.zig");

// ============================================================================
// Structures

/// Aldus Placeable Metafile header (12 bytes at the start).
const PlaceableWmfHeader = struct {
    key: u32, // 0x9AC6CDD7
    hot_spot_x: i16,
    hot_spot_y: i16,
    bbox_left: i16,
    bbox_top: i16,
    bbox_right: i16,
    bbox_bottom: i16,
    inch: u16,
    reserved: u32,
    checksum: u16,

    fn isPlaceable(self: *const PlaceableWmfHeader) bool {
        return self.key == 0x9AC6CDD7;
    }
};

/// WMF record header.
const WmfRecord = struct {
    record_function: u16,
    record_size: u16,
    params: []const u8,

    fn parse(data: []const u8, pos: usize) ?WmfRecord {
        if (pos + 4 > data.len) return null;
        const func = std.mem.readIntLittle(u16, data[pos .. pos + 2]);
        const size = std.mem.readIntLittle(u16, data[pos + 2 .. pos + 4]);
        if (pos + @as(usize, size) * 2 > data.len) return null;
        return WmfRecord{
            .record_function = func,
            .record_size = size,
            .params = data[pos + 4 .. pos + @as(usize, size) * 2],
        };
    }
};

/// Metafile record function constants.
const RecordType = enum(u16) {
    META_HEADER = 0x0001,
    META_EOF = 0x0003,
    META_POLYLINE = 0x0325,
    META_POLYGON = 0x0324,
    META_RECTANGLE = 0x0412,
    META_ELLIPSE = 0x0418,
    META_ARC = 0x0417,
    META_CHORD = 0x0430,
    META_PIE = 0x0431,
    META_LINETO = 0x0213,
    META_MOVETO = 0x0214,
    META_SETPIXEL = 0x041F,
    META_STRETCHBLT = 0x0B41,
    META_SETBKMODE = 0x0102,
    META_SETBKCOLOR = 0x0201,
    META_SETTEXTCOLOR = 0x0209,
    META_SETTEXTALIGN = 0x012E,
    META_TEXTOut = 0x0521,
    META_EXTTEXTOUT = 0x0A32,
    META_CREATEBRUSH = 0x02FA,
    META_CREATEPEN = 0x02FE,
    META_SELECTOBJECT = 0x012D,
    META_DELETEOBJECT = 0x01D0,
    META_SAVEDC = 0x001E,
    META_RESTOREDC = 0x0127,
    META_SETWINDOWORG = 0x020B,
    META_SETWINDOWEXT = 0x020C,
    META_SETVIEWPORTORG = 0x0211,
    META_SETVIEWPORTEXT = 0x0212,
    META_ESCAPE = 0x0626,
    META_DRAWTEXT = 0x062F,
    META_SETROP2 = 0x0104,
    META_SETRELABS = 0x0105,
    META_SETPOLYFILLMODE = 0x0106,
    META_SETSTRETCHBLTMODE = 0x0107,
    META_EXCLUDECLIPRECT = 0x0415,
    META_INTERSECTCLIPRECT = 0x0416,
    META_SCALEWINDOWEXT = 0x0410,
    META_SCALEVIEWPORTEXT = 0x0412,
    META_EXCLUDECLIPRGN = 0x0428,
    META_OFFSETCLIPRGN = 0x0220,
    META_FILLREGION = 0x0228,
    META_SETCLIPRGN = 0x0215,
    META_CREATEREGION = 0x06FF,
    META_CREATEDIBPATTERNBRUSH = 0x0142,
    META_CREATEMETAPILE = 0x000D,
    META_SETMAPPERFLAGS = 0x0231,
    META_SETMETARGN = 0x012C,
    META_DELETEMETAFILE = 0x0140,
    META_PLAYMTF = 0x003D,
    META_FRAMEREGION = 0x0429,
    META_INVERTREGION = 0x012A,
    META_PAINTREGION = 0x012B,
    META_SELECTCLIPREGION = 0x012C,
    META_OFFSETWINDOWORG = 0x020F,
    META_OFFSETVIEWPORTORG = 0x0211,
    META_ROP2 = 0x0104,
    META_SETMAPMODE = 0x0103,
    META_SETDCBRUSH = 0x0141,
    META_SETDCPEN = 0x0142,
    META_FLOODFILL = 0x0419,
    META_FILLRECT = 0x041B,
    META_FRAMERECT = 0x0431,
    META_SETLAYOUT = 0x0149,
    META_RESETDC = 0x014C,
    META_STARTDOC = 0x014D,
    META_ENDDOC = 0x004E,
    META_NEWFRAME = 0x0141,
    META_DIBSTRETCHBLT = 0x0B41,
    META_DIBBITBLT = 0x0941,
    META_STRETCHDIB = 0x0B53,
    UNKNOWN = 0,
};

fn recordTypeFromU16(t: u16) RecordType {
    return @as(RecordType, @enumFromInt(t));
}

/// Metafile playback context.
pub const WmfPlayback = struct {
    records: []WmfRecord,
    bounds: struct {
        left: i16,
        top: i16,
        right: i16,
        bottom: i16,
    },
    window_ext: struct { cx: i16, cy: i16 },
    viewport_ext: struct { cx: i16, cy: i16 },
    map_mode: u16,
    is_placeable: bool,
};

/// WMF object types.
pub const WmfObjectType = enum(u8) {
    brush = 0,
    pen = 1,
    font = 2,
    region = 3,
    palette = 4,
    null_brush = 5,
    null_pen = 6,
    maximal_brush = 7,
    maximal_pen = 8,
    OEM_brush = 9,
    OEM_pen = 10,
    extend_brush = 11,
    extend_pen = 12,
};

/// GDI object for playback state.
const GdiObject = struct {
    object_type: WmfObjectType,
    data: []u8,
};

/// Checksum calculation for Aldus placeable metafile.
fn calculatePlaceableChecksum(header: *const PlaceableWmfHeader) u16 {
    const words = @as(*const [6]u16, @ptrCast(&header.key));
    var sum: u16 = 0;
    for (0..6) |i| {
        sum ^= words[i];
    }
    return sum;
}

// ============================================================================
// Parsing

fn parsePlaceableHeader(data: []const u8) mod.ImageError!PlaceableWmfHeader {
    if (data.len < 22) return mod.ImageError.TruncatedData;
    var h = PlaceableWmfHeader{
        .key = std.mem.readIntLittle(u32, data[0..4]),
        .hot_spot_x = std.mem.readIntLittle(i16, data[4..6]),
        .hot_spot_y = std.mem.readIntLittle(i16, data[6..8]),
        .bbox_left = std.mem.readIntLittle(i16, data[8..10]),
        .bbox_top = std.mem.readIntLittle(i16, data[10..12]),
        .bbox_right = std.mem.readIntLittle(i16, data[12..14]),
        .bbox_bottom = std.mem.readIntLittle(i16, data[14..16]),
        .inch = std.mem.readIntLittle(u16, data[16..18]),
        .reserved = std.mem.readIntLittle(u32, data[18..22]),
        .checksum = std.mem.readIntLittle(u16, data[22..24]),
    };
    _ = calculatePlaceableChecksum(&h);
    return h;
}

fn parseWmfMetaHeader(data: []const u8) mod.ImageError!struct {
    type: u16,
    header_size: u16,
    version: u16,
    size: u32,
    num_objects: u16,
    max_record: u32,
    params: u16,
} {
    if (data.len < 18) return mod.ImageError.TruncatedData;
    return .{
        .type = std.mem.readIntLittle(u16, data[0..2]),
        .header_size = std.mem.readIntLittle(u16, data[2..4]),
        .version = std.mem.readIntLittle(u16, data[4..6]),
        .size = std.mem.readIntLittle(u32, data[6..10]),
        .num_objects = std.mem.readIntLittle(u16, data[10..12]),
        .max_record = std.mem.readIntLittle(u32, data[12..16]),
        .params = std.mem.readIntLittle(u16, data[16..18]),
    };
}

// ============================================================================
// Public API

/// Decodes a WMF file. Returns playback context with parsed records.
/// Caller must free the records array.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) mod.ImageError!WmfPlayback {
    if (data.len < 4) return mod.ImageError.TruncatedData;

    var is_placeable = false;
    var metafile_start: usize = 0;
    var bounds: struct { left: i16, top: i16, right: i16, bottom: i16 } = .{ .left = 0, .top = 0, .right = 1000, .bottom = 1000 };

    // Check for Aldus placeable metafile
    if (data.len >= 22 and std.mem.readIntLittle(u32, data[0..4]) == 0x9AC6CDD7) {
        const ph = try parsePlaceableHeader(data);
        is_placeable = true;
        bounds = .{
            .left = ph.bbox_left,
            .top = ph.bbox_top,
            .right = ph.bbox_right,
            .bottom = ph.bbox_bottom,
        };
        metafile_start = 22;
    }

    // Parse WMF records
    var records = std.ArrayListUnmanaged(WmfRecord){};
    errdefer records.deinit(allocator);

    var pos = metafile_start;
    while (pos < data.len) {
        if (WmfRecord.parse(data, pos)) |rec| {
            try records.append(allocator, rec);
            pos += @as(usize, rec.record_size) * 2;
        } else {
            break;
        }
    }

    const recs = try records.toOwnedSlice(allocator);

    return WmfPlayback{
        .records = recs,
        .bounds = bounds,
        .window_ext = .{ .cx = bounds.right - bounds.left, .cy = bounds.bottom - bounds.top },
        .viewport_ext = .{ .cx = bounds.right - bounds.left, .cy = bounds.bottom - bounds.top },
        .map_mode = 8, // MM_TEXT
        .is_placeable = is_placeable,
    };
}

/// Returns bounding box from WMF playback context.
pub fn getBounds(playback: *const WmfPlayback) struct { i16, i16, i16, i16 } {
    return playback.bounds;
}

/// Decoder interface entry.
pub const wmfDecoder: mod.Decoder = .{
    .signature = &[2]u8{ 0x00, 0x00 },
    .name = "WMF",
    .extensions = &.{".wmf"},
    .decodeFn = struct {
        fn call(_: std.mem.Allocator, _: []const u8) mod.ImageError!mod.PixelBuffer {
            // WMF is a vector format — return a placeholder
            // Actual rendering requires a full GDI implementation
            return mod.ImageError.UnsupportedFormat;
        }
    }.call,
};
