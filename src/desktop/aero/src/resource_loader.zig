//! Resource Loader — ZirconOS Aero Desktop
//! Scans and catalogues graphical assets from the resources/ directory tree:
//!   resources/wallpapers/    — SVG wallpaper backgrounds per theme
//!   resources/icons/         — Application and system icons (SVG)
//!   resources/cursors/       — Animated cursor sprites (SVG)
//!   resources/themes/        — .theme configuration files
//!   resources/sounds/        — Event sound schemes（当前仅元数据路径登记，无播放栈）
//!   resources/logo.svg       — 品牌标识（登记路径；内核任务栏为过程绘制）
//!   resources/start_orb.svg  — Start 球矢量（登记路径）
//!
//! At init time, the loader registers known built-in resource entries
//! so the compositor and shell can reference them by path or ID.

pub const MAX_WALLPAPERS: usize = 24;
pub const MAX_ICONS: usize = 64;
pub const MAX_CURSORS: usize = 24;
pub const MAX_THEME_FILES: usize = 16;
pub const MAX_SOUND_SCHEMES: usize = 24;
pub const MAX_BRAND_ASSETS: usize = 8;
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

var sound_schemes: [MAX_SOUND_SCHEMES]ResourceEntry = [_]ResourceEntry{.{}} ** MAX_SOUND_SCHEMES;
var sound_scheme_count: usize = 0;

var brand_assets: [MAX_BRAND_ASSETS]ResourceEntry = [_]ResourceEntry{.{}} ** MAX_BRAND_ASSETS;
var brand_asset_count: usize = 0;

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

fn addSoundScheme(path: []const u8, id: u16) void {
    if (sound_scheme_count >= MAX_SOUND_SCHEMES) return;
    var e = &sound_schemes[sound_scheme_count];
    e.path_len = setPath(&e.path, path);
    e.id = id;
    e.loaded = true;
    sound_scheme_count += 1;
}

fn addBrandAsset(path: []const u8, id: u16) void {
    if (brand_asset_count >= MAX_BRAND_ASSETS) return;
    var e = &brand_assets[brand_asset_count];
    e.path_len = setPath(&e.path, path);
    e.id = id;
    e.loaded = true;
    brand_asset_count += 1;
}

pub fn init() void {
    if (initialized) return;

    wallpaper_count = 0;
    icon_count = 0;
    cursor_count = 0;
    theme_file_count = 0;
    sound_scheme_count = 0;
    brand_asset_count = 0;

    registerBuiltinWallpapers();
    registerBuiltinIcons();
    registerBuiltinCursors();
    registerBuiltinThemeFiles();
    registerBuiltinSoundSchemes();
    registerBuiltinBrandAssets();

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
    addWallpaper("resources/wallpapers/zircon_ocean.svg", 10);
    addWallpaper("resources/wallpapers/zircon_nebula.svg", 11);
    addWallpaper("resources/wallpapers/zircon_landscape.svg", 12);
}

fn registerBuiltinIcons() void {
    // ID 与 desktop.zig / shell 一致；路径须与 resources/icons/*.svg 文件名一致
    addIcon("resources/icons/computer.svg", 1);
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
    addIcon("resources/icons/file.svg", 14);
    addIcon("resources/icons/user.svg", 15);
    addIcon("resources/icons/lock.svg", 16);
    addIcon("resources/icons/shutdown.svg", 17);
}

fn registerBuiltinCursors() void {
    addCursor("resources/cursors/zircon_arrow.svg", 1);
    addCursor("resources/cursors/zircon_link.svg", 2);
    addCursor("resources/cursors/zircon_text.svg", 3);
    addCursor("resources/cursors/zircon_busy.svg", 4);
    addCursor("resources/cursors/zircon_nesw.svg", 5);
    addCursor("resources/cursors/zircon_ns.svg", 6);
    addCursor("resources/cursors/zircon_ew.svg", 7);
    addCursor("resources/cursors/zircon_move.svg", 8);
    addCursor("resources/cursors/zircon_pen.svg", 9);
    addCursor("resources/cursors/zircon_help.svg", 10);
    addCursor("resources/cursors/zircon_working.svg", 11);
    addCursor("resources/cursors/zircon_unavail.svg", 12);
    addCursor("resources/cursors/zircon_up.svg", 13);
    addCursor("resources/cursors/zircon_nwse.svg", 14);
}

fn registerBuiltinThemeFiles() void {
    addThemeFile("resources/themes/zircon-aero.theme", 1);
    addThemeFile("resources/themes/zircon-aero-blue.theme", 2);
    addThemeFile("resources/themes/zircon-aero-graphite.theme", 3);
    addThemeFile("resources/themes/characters.theme", 4);
    addThemeFile("resources/themes/nature.theme", 5);
    addThemeFile("resources/themes/scenes.theme", 6);
    addThemeFile("resources/themes/landscapes.theme", 7);
    addThemeFile("resources/themes/architecture.theme", 8);
}

/// 声音方案仅登记路径（内核暂无 WAV 播放器；供清单与后续音频栈对齐）。
fn registerBuiltinSoundSchemes() void {
    addSoundScheme("resources/sounds/sound_scheme.conf", 1);
    addSoundScheme("resources/sounds/Desktop.ini", 2);
    addSoundScheme("resources/sounds/README.md", 3);
    addSoundScheme("resources/sounds/Afternoon/Desktop.ini", 4);
    addSoundScheme("resources/sounds/Calligraphy/Desktop.ini", 5);
    addSoundScheme("resources/sounds/Characters/Desktop.ini", 6);
    addSoundScheme("resources/sounds/Cityscape/Desktop.ini", 7);
    addSoundScheme("resources/sounds/Delta/Desktop.ini", 8);
    addSoundScheme("resources/sounds/Festival/Desktop.ini", 9);
    addSoundScheme("resources/sounds/Garden/Desktop.ini", 10);
    addSoundScheme("resources/sounds/Heritage/Desktop.ini", 11);
    addSoundScheme("resources/sounds/Landscape/Desktop.ini", 12);
    addSoundScheme("resources/sounds/Quirky/Desktop.ini", 13);
    addSoundScheme("resources/sounds/Raga/Desktop.ini", 14);
    addSoundScheme("resources/sounds/Savanna/Desktop.ini", 15);
    addSoundScheme("resources/sounds/Sonata/Desktop.ini", 16);
}

/// Shell 品牌图（内核帧缓冲任务栏仍为过程绘制；此处供清单与宿主工具引用路径）。
fn registerBuiltinBrandAssets() void {
    addBrandAsset("resources/logo.svg", 1);
    addBrandAsset("resources/start_orb.svg", 2);
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

pub fn getSoundSchemeCount() usize {
    return sound_scheme_count;
}

pub fn getBrandAssetCount() usize {
    return brand_asset_count;
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

pub fn getSoundSchemes() []const ResourceEntry {
    return sound_schemes[0..sound_scheme_count];
}

pub fn getBrandAssets() []const ResourceEntry {
    return brand_assets[0..brand_asset_count];
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

pub fn findSoundSchemeById(id: u16) ?*const ResourceEntry {
    for (sound_schemes[0..sound_scheme_count]) |*e| {
        if (e.id == id) return e;
    }
    return null;
}

pub fn findBrandAssetById(id: u16) ?*const ResourceEntry {
    for (brand_assets[0..brand_asset_count]) |*e| {
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
