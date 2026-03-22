//! Desktop icons — Windows 7 Aero（`src/desktop/aero/resources/icons/`）

const fb = @import("framebuffer.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return b | (g << 8) | (r << 16);
}

pub const IconId = enum(u8) {
    computer = 0,
    documents = 1,
    network = 2,
    recycle_bin = 3,
    browser = 4,
    settings = 5,
    terminal = 6,
    folder = 7,
};

pub const ThemeStyle = enum(u8) {
    aero = 0,
};

pub const ICON_PX_SIZE: u32 = 16;

pub const SvgIconPaths = struct {
    computer: []const u8,
    documents: []const u8,
    network: []const u8,
    recycle_bin: []const u8,
    browser: []const u8,
    settings: []const u8,
    terminal: []const u8,
    folder: []const u8,
};

pub fn getSvgPaths(style: ThemeStyle) SvgIconPaths {
    _ = style;
    return .{
        .computer = "src/desktop/aero/resources/icons/computer.svg",
        .documents = "src/desktop/aero/resources/icons/documents.svg",
        .network = "src/desktop/aero/resources/icons/network.svg",
        .recycle_bin = "src/desktop/aero/resources/icons/recycle_bin.svg",
        .browser = "src/desktop/aero/resources/icons/browser.svg",
        .settings = "src/desktop/aero/resources/icons/settings.svg",
        .terminal = "src/desktop/aero/resources/icons/terminal.svg",
        .folder = "src/desktop/aero/resources/icons/folder.svg",
    };
}

pub fn drawIcon(id: IconId, screen_x: i32, screen_y: i32, scale: u32) void {
    drawThemedIcon(id, screen_x, screen_y, scale, .aero);
}

pub fn drawThemedIcon(id: IconId, screen_x: i32, screen_y: i32, scale: u32, _: ThemeStyle) void {
    drawAeroIcon(id, screen_x, screen_y, scale);
}

pub fn getIconTotalSize(scale: u32) i32 {
    return @intCast(ICON_PX_SIZE * (if (scale < 1) 1 else scale));
}

// ═══════════════════════════════════════════════════════════
//  Per-Theme Embedded Bitmap Fallback Icons (16×16 @ 4bpp)
//  Each theme has DISTINCT pixel designs and palettes.
// ═══════════════════════════════════════════════════════════

const IconPixels = [16][16]u4;
const IconPalette = [9]u32;

// ── Helper: draw any 16×16 indexed-color icon ──

fn drawPixelIcon(
    id: IconId,
    screen_x: i32,
    screen_y: i32,
    scale: u32,
    palettes: *const [8]IconPalette,
    pixels: *const [8]IconPixels,
) void {
    const idx = @intFromEnum(id);
    if (idx >= 8) return;
    const data = &pixels[idx];
    const palette = &palettes[idx];
    const s: i32 = if (scale < 1) 1 else @intCast(scale);

    for (data, 0..) |row, dy| {
        for (row, 0..) |cidx, dx| {
            if (cidx == 0) continue;
            const color = palette[@intCast(cidx)];
            const px = screen_x + @as(i32, @intCast(dx)) * s;
            const py = screen_y + @as(i32, @intCast(dy)) * s;
            if (s == 1) {
                if (px >= 0 and py >= 0) fb.putPixel32(@intCast(px), @intCast(py), color);
            } else {
                fb.fillRect(px, py, s, s, color);
            }
        }
    }
}
const aero_desktop_icon_pixels = [8]IconPixels{
    // computer — flat monitor + base
    .{
        .{ 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0 },
        .{ 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0 },
        .{ 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0 },
        .{ 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0 },
        .{ 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0 },
        .{ 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0 },
        .{ 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0 },
        .{ 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0 },
        .{ 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0 },
        .{ 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
    // documents — flat folder
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
    // network — flat
    .{
        .{ 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
        .{ 0, 1, 3, 3, 3, 1, 0, 0, 0, 0, 1, 3, 3, 3, 1, 0 },
        .{ 0, 1, 3, 3, 3, 1, 0, 0, 0, 0, 1, 3, 3, 3, 1, 0 },
        .{ 0, 1, 3, 3, 3, 1, 0, 0, 0, 0, 1, 3, 3, 3, 1, 0 },
        .{ 0, 1, 3, 3, 3, 1, 0, 0, 0, 0, 1, 3, 3, 3, 1, 0 },
        .{ 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
        .{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0 },
        .{ 0, 1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 0, 0 },
        .{ 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
    // recycle_bin — flat
    .{
        .{ 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 3, 1, 3, 1, 3, 1, 3, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 3, 1, 3, 1, 3, 1, 3, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 3, 1, 3, 1, 3, 1, 3, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 3, 1, 3, 1, 3, 1, 3, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 3, 1, 3, 1, 3, 1, 3, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 3, 1, 3, 1, 3, 1, 3, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 3, 1, 3, 1, 3, 1, 3, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
    // browser — flat circle
    .{
        .{ 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 1, 1, 3, 3, 1, 3, 1, 3, 3, 1, 1, 0, 0, 0 },
        .{ 0, 1, 1, 3, 3, 3, 2, 3, 2, 3, 3, 3, 1, 1, 0, 0 },
        .{ 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 1, 1, 3, 3, 1, 3, 1, 3, 1, 3, 1, 3, 3, 1, 1, 0 },
        .{ 1, 2, 1, 1, 2, 1, 2, 1, 2, 1, 2, 1, 1, 2, 1, 0 },
        .{ 1, 1, 3, 3, 1, 3, 1, 3, 1, 3, 1, 3, 3, 1, 1, 0 },
        .{ 1, 2, 1, 1, 2, 1, 2, 1, 2, 1, 2, 1, 1, 2, 1, 0 },
        .{ 1, 1, 3, 3, 1, 3, 1, 3, 1, 3, 1, 3, 3, 1, 1, 0 },
        .{ 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 1, 3, 3, 3, 2, 3, 2, 3, 3, 3, 1, 1, 0, 0 },
        .{ 0, 0, 1, 1, 3, 3, 1, 3, 1, 3, 3, 1, 1, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
    // settings — flat gear
    .{
        .{ 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0 },
        .{ 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 3, 3, 3, 1, 1, 1, 0, 0, 0, 0 },
        .{ 1, 1, 0, 1, 1, 3, 0, 0, 0, 3, 1, 1, 0, 1, 1, 0 },
        .{ 1, 1, 1, 1, 1, 3, 0, 0, 0, 3, 1, 1, 1, 1, 1, 0 },
        .{ 1, 1, 0, 1, 1, 3, 0, 0, 0, 3, 1, 1, 0, 1, 1, 0 },
        .{ 0, 0, 0, 1, 1, 1, 3, 3, 3, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
        .{ 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 0 },
        .{ 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
    // terminal — flat
    .{
        .{ 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0 },
        .{ 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 2, 3, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 2, 2, 3, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 2, 3, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 3, 2, 2, 3, 3, 3, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0 },
        .{ 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
    // folder — flat
    .{
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    },
};

// ════════════════════════════════════════════════════════════
//  AERO theme — Glass/crystal style with reflection overlay
//  Uses Aero palette from src/desktop/aero/resources
// ════════════════════════════════════════════════════════════

const aero_palettes = [8]IconPalette{
    .{ 0, rgb(0x2B, 0x56, 0x7A), rgb(0x41, 0x80, 0xC8), rgb(0x6B, 0xA0, 0xD8), rgb(0xA0, 0xC0, 0xE8), rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC0, 0xC0), rgb(0x80, 0x80, 0x80), rgb(0x40, 0x40, 0x40) },
    .{ 0, rgb(0xC0, 0x90, 0x20), rgb(0xE0, 0xB8, 0x40), rgb(0xFF, 0xD8, 0x70), rgb(0xFF, 0xFF, 0xFF), rgb(0x1A, 0x1A, 0x1A), rgb(0x80, 0x80, 0x80), rgb(0xF0, 0xF0, 0xF0), rgb(0xA0, 0x70, 0x10) },
    .{ 0, rgb(0x41, 0x80, 0xC8), rgb(0x2B, 0x56, 0x7A), rgb(0x80, 0xC0, 0xFF), rgb(0xF0, 0xF0, 0xF0), rgb(0x33, 0x99, 0xFF), rgb(0x80, 0x80, 0x80), rgb(0xFF, 0xFF, 0xFF), rgb(0x40, 0x40, 0x40) },
    .{ 0, rgb(0x80, 0x80, 0x80), rgb(0xA0, 0xA0, 0xA0), rgb(0x60, 0x60, 0x60), rgb(0xD0, 0xD0, 0xD0), rgb(0x40, 0x40, 0x40), rgb(0xFF, 0xFF, 0xFF), rgb(0x00, 0x80, 0x40), rgb(0xC0, 0xC0, 0xC0) },
    .{ 0, rgb(0x20, 0x80, 0xC0), rgb(0x10, 0x60, 0x90), rgb(0x60, 0xC0, 0xF0), rgb(0xFF, 0xFF, 0xFF), rgb(0x1A, 0x8A, 0x8A), rgb(0x3F, 0xA3, 0xD8), rgb(0xE8, 0xF8, 0xF8), rgb(0x0A, 0x4A, 0x6A) },
    .{ 0, rgb(0x80, 0x90, 0xA0), rgb(0x60, 0x70, 0x80), rgb(0xA0, 0xB0, 0xC0), rgb(0xFF, 0xFF, 0xFF), rgb(0x40, 0x50, 0x60), rgb(0xC0, 0xC8, 0xD0), rgb(0xD0, 0xD8, 0xE0), rgb(0x41, 0x80, 0xC8) },
    .{ 0, rgb(0x10, 0x10, 0x10), rgb(0x2B, 0x56, 0x7A), rgb(0x00, 0xC0, 0x00), rgb(0x60, 0x70, 0x80), rgb(0xD0, 0xD0, 0xD0), rgb(0x00, 0x80, 0x00), rgb(0xFF, 0xFF, 0xFF), rgb(0x41, 0x80, 0xC8) },
    .{ 0, rgb(0xC0, 0x90, 0x20), rgb(0xA0, 0x70, 0x10), rgb(0xE0, 0xB8, 0x40), rgb(0x80, 0x60, 0x00), rgb(0x60, 0x60, 0x60), rgb(0xFF, 0xFF, 0xFF), rgb(0xF0, 0xF0, 0xF0), rgb(0x40, 0x40, 0x40) },
};

fn drawAeroIcon(id: IconId, screen_x: i32, screen_y: i32, scale: u32) void {
    const s: i32 = if (scale < 1) 1 else @intCast(scale);
    const sz: i32 = 16 * s;
    // Aero 玻璃「方块」底：圆角底板 + 顶缘高光 + 细描边，再叠嵌入位图图标。
    fb.fillRoundedRect(screen_x, screen_y, sz, sz, 3, rgb(0x28, 0x48, 0x68));
    fb.drawGradientV(screen_x + 1, screen_y + 1, sz - 2, @max(1, @divTrunc(sz, 3)), rgb(0x58, 0x78, 0x98), rgb(0x30, 0x50, 0x70));
    fb.drawRect(screen_x, screen_y, sz, sz, rgb(0x90, 0xB8, 0xE0));
    fb.drawHLine(screen_x + 1, screen_y + 1, sz - 2, rgb(0xC8, 0xE0, 0xF8));
    drawPixelIcon(id, screen_x, screen_y, scale, &aero_palettes, &aero_desktop_icon_pixels);
    const hi_h = @divTrunc(sz, 3);
    if (hi_h > 1) {
        fb.addSpecularBand(screen_x, screen_y, sz, hi_h, 24);
    }
}
