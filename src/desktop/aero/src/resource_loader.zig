//! Resource Loader — ZirconOS Aero Desktop
//! Scans and catalogues graphical assets from the resources/ directory tree:
//!   resources/wallpapers/    — SVG wallpaper backgrounds per theme
//!   resources/icons/         — Application and system icons (SVG)
//!   resources/cursors/       — Animated cursor sprites (SVG)
//!   resources/themes/        — .theme configuration files
//!   resources/sounds/        — Event sound schemes
//!
//! At init time, the loader registers known built-in resource entries
//! so the compositor and shell can reference them by path or ID.

pub const MAX_WALLPAPERS: usize = 16;
pub const MAX_ICONS: usize = 64;
pub const MAX_CURSORS: usize = 16;
pub const MAX_THEME_FILES: usize = 16;
pub const PATH_MAX: usize = 128;

pub const ResourceEntry = struct {
    path: [PATH_MAX]u8 = [_]u8{0} ** PATH_MAX,
    path_len: u8 = 0,
    loaded: bool = false,
    id: u16 = 0,
};

var wallpapers: [MAX_WALLPAPERS]ResourceEntry = [_]ResourceEntry{.{}} ** MAX_WALLPAPERS;
var wallpaper_count: usize = 0;

var icons: [MAX_ICONS]ResourceEntry = [_]ResourceEntry{.{}} ** MAX_ICONS;
var icon_count: usize = 0;

var cursors: [MAX_CURSORS]ResourceEntry = [_]ResourceEntry{.{}} ** MAX_CURSORS;
var cursor_count: usize = 0;

var theme_files: [MAX_THEME_FILES]ResourceEntry = [_]ResourceEntry{.{}} ** MAX_THEME_FILES;
var theme_file_count: usize = 0;

var initialized: bool = false;

fn setPath(dest: *[PATH_MAX]u8, src: []const u8) u8 {
    const len = @min(src.len, PATH_MAX);
    for (0..len) |i| {
        dest[i] = src[i];
    }
    return @intCast(len);
}

fn addWallpaper(path: []const u8, id: u16) void {
    if (wallpaper_count >= MAX_WALLPAPERS) return;
    var e = &wallpapers[wallpaper_count];
    e.path_len = setPath(&e.path, path);
    e.id = id;
    e.loaded = true;
    wallpaper_count += 1;
}

fn addIcon(path: []const u8, id: u16) void {
    if (icon_count >= MAX_ICONS) return;
    var e = &icons[icon_count];
    e.path_len = setPath(&e.path, path);
    e.id = id;
    e.loaded = true;
    icon_count += 1;
}

fn addCursor(path: []const u8, id: u16) void {
    if (cursor_count >= MAX_CURSORS) return;
    var e = &cursors[cursor_count];
    e.path_len = setPath(&e.path, path);
    e.id = id;
    e.loaded = true;
    cursor_count += 1;
}

fn addThemeFile(path: []const u8, id: u16) void {
    if (theme_file_count >= MAX_THEME_FILES) return;
    var e = &theme_files[theme_file_count];
    e.path_len = setPath(&e.path, path);
    e.id = id;
    e.loaded = true;
    theme_file_count += 1;
}

pub fn init() void {
    if (initialized) return;

    wallpaper_count = 0;
    icon_count = 0;
    cursor_count = 0;
    theme_file_count = 0;

    registerBuiltinWallpapers();
    registerBuiltinIcons();
    registerBuiltinCursors();
    registerBuiltinThemeFiles();

    initialized = true;
}

fn registerBuiltinWallpapers() void {
    addWallpaper("resources/wallpapers/zircon_default.svg", 1);
    addWallpaper("resources/wallpapers/zircon_harmony_win7.svg", 9);
    addWallpaper("resources/wallpapers/zircon_crystal.svg", 2);
    addWallpaper("resources/wallpapers/zircon_aurora.svg", 3);
    addWallpaper("resources/wallpapers/zircon_characters.svg", 4);
    addWallpaper("resources/wallpapers/zircon_nature.svg", 5);
    addWallpaper("resources/wallpapers/zircon_scenes.svg", 6);
    addWallpaper("resources/wallpapers/zircon_landscapes.svg", 7);
    addWallpaper("resources/wallpapers/zircon_architecture.svg", 8);
}

fn registerBuiltinIcons() void {
    addIcon("resources/icons/this_pc.svg", 1);
    addIcon("resources/icons/documents.svg", 2);
    addIcon("resources/icons/recycle_bin.svg", 3);
    addIcon("resources/icons/terminal.svg", 4);
    addIcon("resources/icons/network.svg", 5);
    addIcon("resources/icons/browser.svg", 6);
    addIcon("resources/icons/settings.svg", 7);
    addIcon("resources/icons/calculator.svg", 8);
    addIcon("resources/icons/text_editor.svg", 9);
    addIcon("resources/icons/pictures.svg", 10);
    addIcon("resources/icons/music.svg", 11);
    addIcon("resources/icons/folder.svg", 12);
    addIcon("resources/icons/control_panel.svg", 13);
}

fn registerBuiltinCursors() void {
    addCursor("resources/cursors/zircon_arrow.svg", 1);
    addCursor("resources/cursors/zircon_hand.svg", 2);
    addCursor("resources/cursors/zircon_ibeam.svg", 3);
    addCursor("resources/cursors/zircon_wait.svg", 4);
    addCursor("resources/cursors/zircon_crosshair.svg", 5);
    addCursor("resources/cursors/zircon_size_ns.svg", 6);
    addCursor("resources/cursors/zircon_size_ew.svg", 7);
    addCursor("resources/cursors/zircon_move.svg", 8);
}

fn registerBuiltinThemeFiles() void {
    addThemeFile("resources/themes/zircon_aero.theme", 1);
    addThemeFile("resources/themes/zircon_aero_blue.theme", 2);
    addThemeFile("resources/themes/aero_graphite.theme", 3);
    addThemeFile("resources/themes/zircon_aero_characters.theme", 4);
    addThemeFile("resources/themes/zircon_aero_nature.theme", 5);
    addThemeFile("resources/themes/zircon_aero_scenes.theme", 6);
    addThemeFile("resources/themes/zircon_aero_landscapes.theme", 7);
    addThemeFile("resources/themes/zircon_aero_architecture.theme", 8);
}

// ── Public query API ──

pub fn getWallpaperCount() usize {
    return wallpaper_count;
}

pub fn getIconCount() usize {
    return icon_count;
}

pub fn getCursorCount() usize {
    return cursor_count;
}

pub fn getThemeFileCount() usize {
    return theme_file_count;
}

pub fn getWallpapers() []const ResourceEntry {
    return wallpapers[0..wallpaper_count];
}

pub fn getLoadedIcons() []const ResourceEntry {
    return icons[0..icon_count];
}

pub fn getCursors() []const ResourceEntry {
    return cursors[0..cursor_count];
}

pub fn getThemeFiles() []const ResourceEntry {
    return theme_files[0..theme_file_count];
}

pub fn findWallpaperById(id: u16) ?*const ResourceEntry {
    for (wallpapers[0..wallpaper_count]) |*e| {
        if (e.id == id) return e;
    }
    return null;
}

pub fn findIconById(id: u16) ?*const ResourceEntry {
    for (icons[0..icon_count]) |*e| {
        if (e.id == id) return e;
    }
    return null;
}

pub fn findCursorById(id: u16) ?*const ResourceEntry {
    for (cursors[0..cursor_count]) |*e| {
        if (e.id == id) return e;
    }
    return null;
}

// ── ICO-compatible embedded 16x16 bitmap fallback icons ──
// When SVG cannot be rendered in framebuffer mode, use these embedded bitmaps.
// Format: Windows ICO-style BITMAPINFOHEADER + 4bpp indexed color data.
// Each icon is stored as a 16x16 pixel grid with a 16-color palette.

pub const IcoHeader = extern struct {
    reserved: u16 = 0,
    image_type: u16 = 1, // 1 = ICO
    image_count: u16 = 1,
};

pub const IcoDirEntry = extern struct {
    width: u8 = 16,
    height: u8 = 16,
    color_count: u8 = 16,
    reserved: u8 = 0,
    planes: u16 = 1,
    bits_per_pixel: u16 = 4,
    size: u32 = 0,
    offset: u32 = 0,
};

pub const EmbeddedIcon = struct {
    id: u16,
    name: []const u8,
    svg_path: []const u8,
    palette: [16]u32, // RGB colors for 4bpp indexed
    pixels: [16][16]u4, // 16x16 @ 4bpp
};

pub const aero_icons = [_]EmbeddedIcon{
    .{
        .id = 1,
        .name = "computer",
        .svg_path = "resources/icons/computer.svg",
        .palette = .{
            0x000000, 0x2B567A, 0x4180C8, 0x6BA0D8,
            0xA0C0E8, 0xFFFFFF, 0xC0C0C0, 0x808080,
            0x404040, 0x0050D0, 0x00A0FF, 0xFFD700,
            0xFF4040, 0x40C040, 0x8060A0, 0xF0F0F0,
        },
        .pixels = .{
            .{ 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
            .{ 0, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0, 0, 0 },
            .{ 0, 1, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 1, 0, 0 },
            .{ 0, 1, 2, 3, 4, 4, 4, 4, 4, 4, 4, 3, 2, 1, 0, 0 },
            .{ 0, 1, 2, 3, 4, 5, 5, 5, 5, 5, 4, 3, 2, 1, 0, 0 },
            .{ 0, 1, 2, 3, 4, 5, 5, 5, 5, 5, 4, 3, 2, 1, 0, 0 },
            .{ 0, 1, 2, 3, 4, 5, 5, 5, 5, 5, 4, 3, 2, 1, 0, 0 },
            .{ 0, 1, 2, 3, 4, 4, 4, 4, 4, 4, 4, 3, 2, 1, 0, 0 },
            .{ 0, 1, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 1, 0, 0 },
            .{ 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0 },
            .{ 0, 0, 0, 0, 0, 6, 6, 6, 6, 6, 0, 0, 0, 0, 0, 0 },
            .{ 0, 0, 0, 0, 0, 0, 6, 6, 6, 0, 0, 0, 0, 0, 0, 0 },
            .{ 0, 0, 0, 6, 6, 6, 6, 6, 6, 6, 6, 6, 0, 0, 0, 0 },
            .{ 0, 0, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 6, 0, 0, 0 },
            .{ 0, 0, 0, 6, 6, 6, 6, 6, 6, 6, 6, 6, 0, 0, 0, 0 },
            .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    },
    .{
        .id = 3,
        .name = "recycle_bin",
        .svg_path = "resources/icons/recycle_bin.svg",
        .palette = .{
            0x000000, 0x2B567A, 0x4180C8, 0x6BA0D8,
            0xA0C0E8, 0xFFFFFF, 0xC0C0C0, 0x808080,
            0x404040, 0x0050D0, 0x00A0FF, 0xFFD700,
            0xFF4040, 0x40C040, 0x8060A0, 0xF0F0F0,
        },
        .pixels = .{
            .{ 0, 0, 0, 0, 7, 7, 7, 7, 7, 7, 7, 0, 0, 0, 0, 0 },
            .{ 0, 0, 0, 7, 6, 6, 6, 6, 6, 6, 6, 7, 0, 0, 0, 0 },
            .{ 0, 0, 7, 8, 8, 8, 8, 8, 8, 8, 8, 8, 7, 0, 0, 0 },
            .{ 0, 0, 0, 7, 7, 7, 7, 7, 7, 7, 7, 7, 0, 0, 0, 0 },
            .{ 0, 0, 7, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0, 0, 0 },
            .{ 0, 0, 7, 6, 7, 6, 7, 6, 7, 6, 7, 6, 7, 0, 0, 0 },
            .{ 0, 0, 7, 6, 7, 6, 7, 6, 7, 6, 7, 6, 7, 0, 0, 0 },
            .{ 0, 0, 7, 6, 7, 6, 7, 6, 7, 6, 7, 6, 7, 0, 0, 0 },
            .{ 0, 0, 7, 6, 7, 6, 7, 6, 7, 6, 7, 6, 7, 0, 0, 0 },
            .{ 0, 0, 7, 6, 7, 6, 7, 6, 7, 6, 7, 6, 7, 0, 0, 0 },
            .{ 0, 0, 7, 6, 7, 6, 7, 6, 7, 6, 7, 6, 7, 0, 0, 0 },
            .{ 0, 0, 7, 6, 7, 6, 7, 6, 7, 6, 7, 6, 7, 0, 0, 0 },
            .{ 0, 0, 0, 7, 7, 7, 7, 7, 7, 7, 7, 7, 0, 0, 0, 0 },
            .{ 0, 0, 0, 0, 8, 8, 8, 8, 8, 8, 8, 0, 0, 0, 0, 0 },
            .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    },
};

pub fn getEmbeddedIcons() []const EmbeddedIcon {
    return &aero_icons;
}

pub fn findEmbeddedIconById(id: u16) ?*const EmbeddedIcon {
    for (&aero_icons) |*icon| {
        if (icon.id == id) return icon;
    }
    return null;
}

pub fn isInitialized() bool {
    return initialized;
}
