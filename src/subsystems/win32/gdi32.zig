//! gdi32 - Win32 Graphics Device Interface API Subset
//! Phase 10: Device contexts, drawing primitives, brushes, pens,
//! fonts, bitmaps, and text rendering for framebuffer GUI.

const klog = @import("../../rtl/klog.zig");
const kernel32 = @import("../../libs/kernel32.zig");
const user32 = @import("user32.zig");

pub const BOOL = kernel32.BOOL;
pub const TRUE = kernel32.TRUE;
pub const FALSE = kernel32.FALSE;
pub const DWORD = kernel32.DWORD;
pub const WORD = kernel32.WORD;

pub const HDC = u64;
pub const HBITMAP = u64;
pub const HBRUSH = u64;
pub const HPEN = u64;
pub const HFONT = u64;
pub const HRGN = u64;
pub const HPALETTE = u64;
pub const HGDIOBJ = u64;
pub const COLORREF = u32;

// ── Stock Objects ──

pub const WHITE_BRUSH: u32 = 0;
pub const LTGRAY_BRUSH: u32 = 1;
pub const GRAY_BRUSH: u32 = 2;
pub const DKGRAY_BRUSH: u32 = 3;
pub const BLACK_BRUSH: u32 = 4;
pub const NULL_BRUSH: u32 = 5;
pub const HOLLOW_BRUSH: u32 = 5;

pub const WHITE_PEN: u32 = 6;
pub const BLACK_PEN: u32 = 7;
pub const NULL_PEN: u32 = 8;

pub const SYSTEM_FONT: u32 = 13;
pub const DEFAULT_GUI_FONT: u32 = 17;
pub const SYSTEM_FIXED_FONT: u32 = 16;
pub const OEM_FIXED_FONT: u32 = 10;

// ── Pen Styles ──

pub const PS_SOLID: u32 = 0;
pub const PS_DASH: u32 = 1;
pub const PS_DOT: u32 = 2;
pub const PS_DASHDOT: u32 = 3;
pub const PS_NULL: u32 = 5;

// ── Brush Styles ──

pub const BS_SOLID: u32 = 0;
pub const BS_NULL: u32 = 1;
pub const BS_HOLLOW: u32 = 1;
pub const BS_HATCHED: u32 = 2;
pub const BS_PATTERN: u32 = 3;

// ── Raster Operations ──

pub const SRCCOPY: DWORD = 0x00CC0020;
pub const SRCPAINT: DWORD = 0x00EE0086;
pub const SRCAND: DWORD = 0x008800C6;
pub const SRCINVERT: DWORD = 0x00660046;
pub const BLACKNESS: DWORD = 0x00000042;
pub const WHITENESS: DWORD = 0x00FF0062;
pub const PATCOPY: DWORD = 0x00F00021;
pub const PATPAINT: DWORD = 0x00FB0A09;
pub const PATINVERT: DWORD = 0x005A0049;

// ── Background Modes ──

pub const TRANSPARENT: u32 = 1;
pub const OPAQUE: u32 = 2;

// ── Text Alignment ──

pub const TA_LEFT: u32 = 0;
pub const TA_RIGHT: u32 = 2;
pub const TA_CENTER: u32 = 6;
pub const TA_TOP: u32 = 0;
pub const TA_BOTTOM: u32 = 8;
pub const TA_BASELINE: u32 = 24;

// ── Font Weights ──

pub const FW_THIN: u32 = 100;
pub const FW_NORMAL: u32 = 400;
pub const FW_MEDIUM: u32 = 500;
pub const FW_SEMIBOLD: u32 = 600;
pub const FW_BOLD: u32 = 700;
pub const FW_EXTRABOLD: u32 = 800;

// ── Charsets ──

pub const ANSI_CHARSET: u32 = 0;
pub const DEFAULT_CHARSET: u32 = 1;
pub const OEM_CHARSET: u32 = 255;

// ── Color Macros ──

pub fn RGB(r: u8, g: u8, b: u8) COLORREF {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

pub fn GetRValue(color: COLORREF) u8 {
    return @intCast(color & 0xFF);
}

pub fn GetGValue(color: COLORREF) u8 {
    return @intCast((color >> 8) & 0xFF);
}

pub fn GetBValue(color: COLORREF) u8 {
    return @intCast((color >> 16) & 0xFF);
}

// ── Structures ──

pub const LOGFONTA = struct {
    height: i32 = -12,
    width: i32 = 0,
    escapement: i32 = 0,
    orientation: i32 = 0,
    weight: u32 = FW_NORMAL,
    italic: u8 = 0,
    underline: u8 = 0,
    strikeout: u8 = 0,
    charset: u32 = DEFAULT_CHARSET,
    out_precision: u32 = 0,
    clip_precision: u32 = 0,
    quality: u32 = 0,
    pitch_and_family: u32 = 0,
    face_name: [32]u8 = [_]u8{0} ** 32,
    face_name_len: usize = 0,
};

pub const TEXTMETRICA = struct {
    height: i32 = 16,
    ascent: i32 = 12,
    descent: i32 = 4,
    internal_leading: i32 = 2,
    external_leading: i32 = 0,
    ave_char_width: i32 = 8,
    max_char_width: i32 = 8,
    weight: u32 = FW_NORMAL,
    overhang: i32 = 0,
    digitized_aspect_x: i32 = 96,
    digitized_aspect_y: i32 = 96,
    first_char: u8 = 32,
    last_char: u8 = 126,
    default_char: u8 = '?',
    break_char: u8 = ' ',
    italic: u8 = 0,
    underlined: u8 = 0,
    struck_out: u8 = 0,
    pitch_and_family: u8 = 0,
    charset: u8 = 0,
};

pub const LOGBRUSH = struct {
    style: u32 = BS_SOLID,
    color: COLORREF = 0,
    hatch: u64 = 0,
};

pub const BITMAPINFOHEADER = struct {
    size: DWORD = @sizeOf(BITMAPINFOHEADER),
    width: i32 = 0,
    height: i32 = 0,
    planes: WORD = 1,
    bit_count: WORD = 32,
    compression: DWORD = 0,
    size_image: DWORD = 0,
    x_pels_per_meter: i32 = 0,
    y_pels_per_meter: i32 = 0,
    clr_used: DWORD = 0,
    clr_important: DWORD = 0,
};

// ── Internal Device Context ──

const MAX_DCS: usize = 32;
const MAX_GDI_OBJECTS: usize = 128;

const GdiObjType = enum(u8) {
    none = 0,
    pen = 1,
    brush = 2,
    font = 3,
    bitmap = 4,
    region = 5,
    palette = 6,
};

const GdiObject = struct {
    obj_type: GdiObjType = .none,
    is_valid: bool = false,
    is_stock: bool = false,
    handle: HGDIOBJ = 0,
    color: COLORREF = 0,
    style: u32 = 0,
    width: i32 = 1,
    weight: u32 = FW_NORMAL,
    height: i32 = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
};

const DeviceContext = struct {
    handle: HDC = 0,
    is_valid: bool = false,
    hwnd: u64 = 0,
    text_color: COLORREF = 0x000000,
    bg_color: COLORREF = 0,
    bg_mode: u32 = 0,
    text_align: u32 = 0,
    current_pen: HGDIOBJ = 0,
    current_brush: HGDIOBJ = 0,
    current_font: HGDIOBJ = 0,
    current_bitmap: HGDIOBJ = 0,
    pen_pos_x: i32 = 0,
    pen_pos_y: i32 = 0,
    rop2: u32 = 0,
    map_mode: u32 = 0,
    viewport_org_x: i32 = 0,
    viewport_org_y: i32 = 0,
    window_org_x: i32 = 0,
    window_org_y: i32 = 0,
    clip_left: i32 = 0,
    clip_top: i32 = 0,
    clip_right: i32 = 0,
    clip_bottom: i32 = 0,
};

var device_contexts: [MAX_DCS]DeviceContext = [_]DeviceContext{.{}} ** MAX_DCS;
var dc_count: usize = 0;
var next_dc_handle: HDC = 0x20000;

var gdi_objects: [MAX_GDI_OBJECTS]GdiObject = [_]GdiObject{.{}} ** MAX_GDI_OBJECTS;
var gdi_obj_count: usize = 0;
var next_gdi_handle: HGDIOBJ = 0x30000;

var gdi_initialized: bool = false;
var total_draw_calls: u64 = 0;
var total_gdi_objects_created: u64 = 0;

// ── Device Context APIs ──

pub fn CreateCompatibleDC(hdc: HDC) HDC {
    _ = hdc;
    if (dc_count >= MAX_DCS) return 0;

    var dc = &device_contexts[dc_count];
    dc.* = .{};
    dc.handle = next_dc_handle;
    dc.is_valid = true;
    dc.bg_color = 0xFFFFFF;
    dc.bg_mode = OPAQUE;
    dc.text_align = TA_LEFT | TA_TOP;
    dc.rop2 = 13;
    dc.map_mode = 1;
    dc.clip_right = 800;
    dc.clip_bottom = 600;
    next_dc_handle += 1;
    dc_count += 1;
    return dc.handle;
}

pub fn DeleteDC(hdc: HDC) BOOL {
    const dc = findDC(hdc) orelse return FALSE;
    dc.is_valid = false;
    return TRUE;
}

pub fn SaveDC(hdc: HDC) i32 {
    _ = hdc;
    return 1;
}

pub fn RestoreDC(hdc: HDC, _: i32) BOOL {
    _ = hdc;
    return TRUE;
}

// ── Object Selection ──

pub fn SelectObject(hdc: HDC, obj: HGDIOBJ) HGDIOBJ {
    const dc = findDC(hdc) orelse return 0;
    const gdi = findGdiObj(obj) orelse return 0;

    return switch (gdi.obj_type) {
        .pen => blk: {
            const old = dc.current_pen;
            dc.current_pen = obj;
            break :blk old;
        },
        .brush => blk: {
            const old = dc.current_brush;
            dc.current_brush = obj;
            break :blk old;
        },
        .font => blk: {
            const old = dc.current_font;
            dc.current_font = obj;
            break :blk old;
        },
        .bitmap => blk: {
            const old = dc.current_bitmap;
            dc.current_bitmap = obj;
            break :blk old;
        },
        else => 0,
    };
}

pub fn GetStockObject(index: u32) HGDIOBJ {
    for (gdi_objects[0..gdi_obj_count]) |*obj| {
        if (obj.is_stock and obj.style == index) return obj.handle;
    }
    return 0;
}

pub fn DeleteObject(obj: HGDIOBJ) BOOL {
    const gdi = findGdiObj(obj) orelse return FALSE;
    if (gdi.is_stock) return FALSE;
    gdi.is_valid = false;
    return TRUE;
}

pub fn GetObjectType(obj: HGDIOBJ) u32 {
    const gdi = findGdiObj(obj) orelse return 0;
    return @intFromEnum(gdi.obj_type);
}

// ── Pen/Brush/Font Creation ──

pub fn CreatePen(style: u32, width: i32, color: COLORREF) HPEN {
    return createGdiObj(.pen, style, width, color, 0, "");
}

pub fn CreateSolidBrush(color: COLORREF) HBRUSH {
    return createGdiObj(.brush, BS_SOLID, 0, color, 0, "");
}

pub fn CreateHatchBrush(hatch: u32, color: COLORREF) HBRUSH {
    return createGdiObj(.brush, BS_HATCHED, 0, color, hatch, "");
}

pub fn CreateFontA(
    height: i32,
    _: i32,
    _: i32,
    _: i32,
    weight: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    _: u32,
    face_name: []const u8,
) HFONT {
    _ = height;
    return createGdiObj(.font, 0, 0, 0, weight, face_name);
}

pub fn CreateFontIndirectA(lf: *const LOGFONTA) HFONT {
    return CreateFontA(
        lf.height, lf.width, lf.escapement, lf.orientation,
        lf.weight, lf.italic, lf.underline, lf.strikeout,
        lf.charset, lf.out_precision, lf.clip_precision,
        lf.quality, lf.pitch_and_family,
        lf.face_name[0..lf.face_name_len],
    );
}

// ── Color APIs ──

pub fn SetTextColor(hdc: HDC, color: COLORREF) COLORREF {
    const dc = findDC(hdc) orelse return 0;
    const old = dc.text_color;
    dc.text_color = color;
    return old;
}

pub fn GetTextColor(hdc: HDC) COLORREF {
    const dc = findDC(hdc) orelse return 0;
    return dc.text_color;
}

pub fn SetBkColor(hdc: HDC, color: COLORREF) COLORREF {
    const dc = findDC(hdc) orelse return 0;
    const old = dc.bg_color;
    dc.bg_color = color;
    return old;
}

pub fn GetBkColor(hdc: HDC) COLORREF {
    const dc = findDC(hdc) orelse return 0;
    return dc.bg_color;
}

pub fn SetBkMode(hdc: HDC, mode: u32) u32 {
    const dc = findDC(hdc) orelse return 0;
    const old = dc.bg_mode;
    dc.bg_mode = mode;
    return old;
}

pub fn SetTextAlign(hdc: HDC, align_flags: u32) u32 {
    const dc = findDC(hdc) orelse return 0;
    const old = dc.text_align;
    dc.text_align = align_flags;
    return old;
}

// ── Drawing Primitives ──

pub fn SetPixel(hdc: HDC, x: i32, y: i32, color: COLORREF) COLORREF {
    _ = hdc;
    _ = x;
    _ = y;
    total_draw_calls += 1;
    return color;
}

pub fn GetPixel(hdc: HDC, _: i32, _: i32) COLORREF {
    _ = hdc;
    return 0;
}

pub fn MoveToEx(hdc: HDC, x: i32, y: i32, old_point: ?*user32.POINT) BOOL {
    const dc = findDC(hdc) orelse return FALSE;
    if (old_point) |pt| {
        pt.x = dc.pen_pos_x;
        pt.y = dc.pen_pos_y;
    }
    dc.pen_pos_x = x;
    dc.pen_pos_y = y;
    return TRUE;
}

pub fn LineTo(hdc: HDC, x: i32, y: i32) BOOL {
    const dc = findDC(hdc) orelse return FALSE;
    dc.pen_pos_x = x;
    dc.pen_pos_y = y;
    total_draw_calls += 1;
    return TRUE;
}

pub fn Rectangle(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32) BOOL {
    _ = hdc;
    _ = left;
    _ = top;
    _ = right;
    _ = bottom;
    total_draw_calls += 1;
    return TRUE;
}

pub fn Ellipse(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32) BOOL {
    _ = hdc;
    _ = left;
    _ = top;
    _ = right;
    _ = bottom;
    total_draw_calls += 1;
    return TRUE;
}

pub fn FillRect(hdc: HDC, rect: *const user32.RECT, brush: HBRUSH) i32 {
    _ = hdc;
    _ = rect;
    _ = brush;
    total_draw_calls += 1;
    return 1;
}

pub fn FrameRect(hdc: HDC, rect: *const user32.RECT, brush: HBRUSH) i32 {
    _ = hdc;
    _ = rect;
    _ = brush;
    total_draw_calls += 1;
    return 1;
}

pub fn InvertRect(hdc: HDC, rect: *const user32.RECT) BOOL {
    _ = hdc;
    _ = rect;
    total_draw_calls += 1;
    return TRUE;
}

pub fn RoundRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32, _: i32, _: i32) BOOL {
    return Rectangle(hdc, left, top, right, bottom);
}

pub fn Polyline(_: HDC, _: []const user32.POINT) BOOL {
    total_draw_calls += 1;
    return TRUE;
}

pub fn Polygon(_: HDC, _: []const user32.POINT) BOOL {
    total_draw_calls += 1;
    return TRUE;
}

// ── Text APIs ──

pub fn TextOutA(hdc: HDC, _: i32, _: i32, text: []const u8) BOOL {
    _ = hdc;
    _ = text;
    total_draw_calls += 1;
    return TRUE;
}

pub fn DrawTextA(hdc: HDC, text: []const u8, rect: *user32.RECT, _: u32) i32 {
    _ = hdc;
    _ = text;
    _ = rect;
    total_draw_calls += 1;
    return 16;
}

pub fn GetTextExtentPoint32A(hdc: HDC, text: []const u8, size: *user32.SIZE) BOOL {
    _ = hdc;
    size.cx = @intCast(text.len * 8);
    size.cy = 16;
    return TRUE;
}

pub fn GetTextMetricsA(hdc: HDC, tm: *TEXTMETRICA) BOOL {
    _ = hdc;
    tm.* = .{};
    return TRUE;
}

// ── Bitmap APIs ──

pub fn CreateCompatibleBitmap(hdc: HDC, width: i32, height: i32) HBITMAP {
    _ = hdc;
    _ = width;
    _ = height;
    return createGdiObj(.bitmap, 0, 0, 0, 0, "");
}

pub fn BitBlt(
    dest_dc: HDC,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    src_dc: HDC,
    _: i32,
    _: i32,
    rop: DWORD,
) BOOL {
    _ = dest_dc;
    _ = src_dc;
    _ = rop;
    total_draw_calls += 1;
    return TRUE;
}

pub fn StretchBlt(
    dest_dc: HDC,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    src_dc: HDC,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    rop: DWORD,
) BOOL {
    _ = dest_dc;
    _ = src_dc;
    _ = rop;
    total_draw_calls += 1;
    return TRUE;
}

pub fn PatBlt(hdc: HDC, _: i32, _: i32, _: i32, _: i32, rop: DWORD) BOOL {
    _ = hdc;
    _ = rop;
    total_draw_calls += 1;
    return TRUE;
}

// ── Region APIs ──

pub fn CreateRectRgn(left: i32, top: i32, right: i32, bottom: i32) HRGN {
    _ = left;
    _ = top;
    _ = right;
    _ = bottom;
    return createGdiObj(.region, 0, 0, 0, 0, "");
}

pub fn SelectClipRgn(hdc: HDC, rgn: HRGN) i32 {
    _ = hdc;
    _ = rgn;
    return 1;
}

pub fn GetClipBox(hdc: HDC, rect: *user32.RECT) i32 {
    const dc = findDC(hdc) orelse return 0;
    rect.left = dc.clip_left;
    rect.top = dc.clip_top;
    rect.right = dc.clip_right;
    rect.bottom = dc.clip_bottom;
    return 1;
}

// ── Coordinate APIs ──

pub fn SetViewportOrgEx(hdc: HDC, x: i32, y: i32, old: ?*user32.POINT) BOOL {
    const dc = findDC(hdc) orelse return FALSE;
    if (old) |pt| {
        pt.x = dc.viewport_org_x;
        pt.y = dc.viewport_org_y;
    }
    dc.viewport_org_x = x;
    dc.viewport_org_y = y;
    return TRUE;
}

pub fn SetWindowOrgEx(hdc: HDC, x: i32, y: i32, old: ?*user32.POINT) BOOL {
    const dc = findDC(hdc) orelse return FALSE;
    if (old) |pt| {
        pt.x = dc.window_org_x;
        pt.y = dc.window_org_y;
    }
    dc.window_org_x = x;
    dc.window_org_y = y;
    return TRUE;
}

// ── Helpers ──

fn findDC(hdc: HDC) ?*DeviceContext {
    for (device_contexts[0..dc_count]) |*dc| {
        if (dc.handle == hdc and dc.is_valid) return dc;
    }
    return null;
}

fn findGdiObj(handle: HGDIOBJ) ?*GdiObject {
    for (gdi_objects[0..gdi_obj_count]) |*obj| {
        if (obj.handle == handle and obj.is_valid) return obj;
    }
    return null;
}

fn createGdiObj(obj_type: GdiObjType, style: u32, width: i32, color: COLORREF, weight: u32, name: []const u8) HGDIOBJ {
    if (gdi_obj_count >= MAX_GDI_OBJECTS) return 0;

    var obj = &gdi_objects[gdi_obj_count];
    obj.* = .{};
    obj.obj_type = obj_type;
    obj.is_valid = true;
    obj.handle = next_gdi_handle;
    obj.color = color;
    obj.style = style;
    obj.width = width;
    obj.weight = weight;

    const n = @min(name.len, obj.name.len);
    if (n > 0) @memcpy(obj.name[0..n], name[0..n]);
    obj.name_len = n;

    next_gdi_handle += 1;
    gdi_obj_count += 1;
    total_gdi_objects_created += 1;
    return obj.handle;
}

fn createStockObject(obj_type: GdiObjType, stock_id: u32, color: COLORREF) void {
    if (gdi_obj_count >= MAX_GDI_OBJECTS) return;

    var obj = &gdi_objects[gdi_obj_count];
    obj.* = .{};
    obj.obj_type = obj_type;
    obj.is_valid = true;
    obj.is_stock = true;
    obj.handle = next_gdi_handle;
    obj.style = stock_id;
    obj.color = color;

    next_gdi_handle += 1;
    gdi_obj_count += 1;
}

// ── Statistics ──

pub fn getDCCount() usize {
    var count: usize = 0;
    for (device_contexts[0..dc_count]) |*dc| {
        if (dc.is_valid) count += 1;
    }
    return count;
}

pub fn getGdiObjectCount() usize {
    return gdi_obj_count;
}

pub fn getTotalDrawCalls() u64 {
    return total_draw_calls;
}

pub fn getTotalObjectsCreated() u64 {
    return total_gdi_objects_created;
}

// ── Demo ──

pub fn runGdiDemo() void {
    klog.info("gdi32: --- GDI Demo ---", .{});

    const hdc = CreateCompatibleDC(0);
    klog.info("gdi32: CreateCompatibleDC -> hdc=0x%x", .{hdc});

    const red_pen = CreatePen(PS_SOLID, 1, RGB(255, 0, 0));
    const blue_brush = CreateSolidBrush(RGB(0, 0, 255));
    const font = CreateFontA(-16, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, 0, 0, "Consolas");

    _ = SelectObject(hdc, red_pen);
    _ = SelectObject(hdc, blue_brush);
    _ = SelectObject(hdc, font);

    _ = SetTextColor(hdc, RGB(255, 255, 255));
    _ = SetBkColor(hdc, RGB(0, 0, 128));
    _ = SetBkMode(hdc, TRANSPARENT);

    _ = Rectangle(hdc, 10, 10, 200, 100);
    _ = Ellipse(hdc, 50, 50, 150, 120);
    _ = MoveToEx(hdc, 0, 0, null);
    _ = LineTo(hdc, 100, 100);
    _ = TextOutA(hdc, 20, 20, "ZirconOS GDI");

    var size: user32.SIZE = .{};
    _ = GetTextExtentPoint32A(hdc, "Hello", &size);
    klog.info("gdi32: TextExtent 'Hello' = %dx%d", .{
        @as(u32, @intCast(size.cx)), @as(u32, @intCast(size.cy)),
    });

    const bmp = CreateCompatibleBitmap(hdc, 640, 480);
    _ = bmp;

    _ = BitBlt(hdc, 0, 0, 100, 100, hdc, 0, 0, SRCCOPY);

    _ = DeleteObject(red_pen);
    _ = DeleteObject(blue_brush);
    _ = DeleteObject(font);
    _ = DeleteDC(hdc);

    klog.info("gdi32: Demo complete: %u draw calls, %u objects created", .{
        getTotalDrawCalls(), getTotalObjectsCreated(),
    });
}

// ── Initialization ──

pub fn init() void {
    dc_count = 0;
    gdi_obj_count = 0;
    next_dc_handle = 0x20000;
    next_gdi_handle = 0x30000;
    total_draw_calls = 0;
    total_gdi_objects_created = 0;
    gdi_initialized = true;

    createStockObject(.brush, WHITE_BRUSH, RGB(255, 255, 255));
    createStockObject(.brush, LTGRAY_BRUSH, RGB(192, 192, 192));
    createStockObject(.brush, GRAY_BRUSH, RGB(128, 128, 128));
    createStockObject(.brush, DKGRAY_BRUSH, RGB(64, 64, 64));
    createStockObject(.brush, BLACK_BRUSH, RGB(0, 0, 0));
    createStockObject(.brush, NULL_BRUSH, 0);
    createStockObject(.pen, WHITE_PEN, RGB(255, 255, 255));
    createStockObject(.pen, BLACK_PEN, RGB(0, 0, 0));
    createStockObject(.pen, NULL_PEN, 0);
    createStockObject(.font, SYSTEM_FONT, 0);
    createStockObject(.font, DEFAULT_GUI_FONT, 0);
    createStockObject(.font, SYSTEM_FIXED_FONT, 0);

    klog.info("gdi32: Win32 GDI API initialized", .{});
    klog.info("gdi32: DC APIs: CreateCompatibleDC, SelectObject, DeleteDC", .{});
    klog.info("gdi32: Drawing: Rectangle, Ellipse, LineTo, FillRect, BitBlt", .{});
    klog.info("gdi32: Text: TextOutA, DrawTextA, GetTextExtentPoint32A", .{});
    klog.info("gdi32: Objects: CreatePen, CreateSolidBrush, CreateFont (%u stock objects)", .{gdi_obj_count});
}
