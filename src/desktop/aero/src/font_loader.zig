//! Font Loader — ZirconOS Aero Desktop
//! Catalogues font files from src/fonts/ and provides
//! named accessors for the DWM compositor and text rendering subsystem.
//!
//! Font families are divided into:
//!   - Western: Segoe UI replacements (Lato, DejaVu Sans, Source Code Pro)
//!   - CJK: Chinese/Japanese/Korean glyphs (Noto Sans CJK, LXGW WenKai)
//!
//! The system font, mono font, and CJK fallback font are resolved at init
//! time and cached for the lifetime of the shell session.

pub const MAX_FONT_FAMILIES: usize = 32;
pub const PATH_MAX: usize = 160;
pub const NAME_MAX: usize = 64;

pub const FontCategory = enum(u8) {
    western = 0,
    cjk = 1,
    monospace = 2,
    display = 3,
};

pub const FontEntry = struct {
    name: [NAME_MAX]u8 = [_]u8{0} ** NAME_MAX,
    name_len: u8 = 0,
    path: [PATH_MAX]u8 = [_]u8{0} ** PATH_MAX,
    path_len: u8 = 0,
    category: FontCategory = .western,
    is_bold: bool = false,
    is_italic: bool = false,
    loaded: bool = false,
};

var fonts: [MAX_FONT_FAMILIES]FontEntry = [_]FontEntry{.{}} ** MAX_FONT_FAMILIES;
var font_count: usize = 0;
var initialized: bool = false;

var system_font_idx: usize = 0;
var mono_font_idx: usize = 0;
var cjk_font_idx: usize = 0;

fn setStr(dest: []u8, src: []const u8) u8 {
    const len = @min(src.len, dest.len);
    for (0..len) |i| {
        dest[i] = src[i];
    }
    return @intCast(len);
}

fn addFont(name: []const u8, path: []const u8, category: FontCategory) usize {
    if (font_count >= MAX_FONT_FAMILIES) return font_count;
    var e = &fonts[font_count];
    e.name_len = setStr(&e.name, name);
    e.path_len = setStr(&e.path, path);
    e.category = category;
    e.loaded = true;
    const idx = font_count;
    font_count += 1;
    return idx;
}

pub fn init() void {
    if (initialized) return;

    font_count = 0;
    registerBuiltinFonts();
    initialized = true;
}

fn registerBuiltinFonts() void {
    const F = "src/fonts";
    // Western UI fonts (Segoe UI replacements)
    system_font_idx = addFont(
        "Lato",
        F ++ "/western/Lato/Lato-Regular.ttf",
        .western,
    );
    _ = addFont(
        "Lato Bold",
        F ++ "/western/Lato/Lato-Bold.ttf",
        .western,
    );
    _ = addFont(
        "DejaVu Sans",
        F ++ "/western/NotoSans/NotoSans-Regular.ttf",
        .western,
    );
    _ = addFont(
        "DejaVu Sans Bold",
        F ++ "/western/NotoSans/NotoSans-Bold.ttf",
        .western,
    );

    // Monospace (terminal / code editors)
    mono_font_idx = addFont(
        "Source Code Pro",
        F ++ "/western/SourceCodePro/SourceCodePro-Regular.ttf",
        .monospace,
    );
    _ = addFont(
        "Source Code Pro Bold",
        F ++ "/western/SourceCodePro/SourceCodePro-Bold.ttf",
        .monospace,
    );
    _ = addFont(
        "DejaVu Sans Mono",
        F ++ "/western/DejaVu/DejaVuSansMono.ttf",
        .monospace,
    );

    // CJK fonts (Chinese/Japanese/Korean)
    cjk_font_idx = addFont(
        "Noto Sans CJK SC",
        F ++ "/cjk/NotoSansCJK-SC/NotoSansSC-Regular.otf",
        .cjk,
    );
    _ = addFont(
        "Noto Sans CJK SC Bold",
        F ++ "/cjk/NotoSansCJK-SC/NotoSansSC-Bold.otf",
        .cjk,
    );
    _ = addFont(
        "LXGW WenKai",
        F ++ "/cjk/LXGWWenKai/LXGWWenKai-Regular.ttf",
        .cjk,
    );
    _ = addFont(
        "LXGW WenKai Bold",
        F ++ "/cjk/LXGWWenKai/LXGWWenKai-Medium.ttf",
        .cjk,
    );
}

// ── Public query API ──

pub fn getSystemFontName() []const u8 {
    if (system_font_idx < font_count) {
        return fonts[system_font_idx].name[0..fonts[system_font_idx].name_len];
    }
    return "Lato";
}

pub fn getMonoFontName() []const u8 {
    if (mono_font_idx < font_count) {
        return fonts[mono_font_idx].name[0..fonts[mono_font_idx].name_len];
    }
    return "Source Code Pro";
}

pub fn getCjkFontName() []const u8 {
    if (cjk_font_idx < font_count) {
        return fonts[cjk_font_idx].name[0..fonts[cjk_font_idx].name_len];
    }
    return "Noto Sans CJK SC";
}

pub fn getSystemFontPath() []const u8 {
    if (system_font_idx < font_count) {
        return fonts[system_font_idx].path[0..fonts[system_font_idx].path_len];
    }
    return "";
}

pub fn getMonoFontPath() []const u8 {
    if (mono_font_idx < font_count) {
        return fonts[mono_font_idx].path[0..fonts[mono_font_idx].path_len];
    }
    return "";
}

pub fn getCjkFontPath() []const u8 {
    if (cjk_font_idx < font_count) {
        return fonts[cjk_font_idx].path[0..fonts[cjk_font_idx].path_len];
    }
    return "";
}

pub fn getWesternFontCount() usize {
    var count: usize = 0;
    for (fonts[0..font_count]) |e| {
        if (e.category == .western) count += 1;
    }
    return count;
}

pub fn getCjkFontCount() usize {
    var count: usize = 0;
    for (fonts[0..font_count]) |e| {
        if (e.category == .cjk) count += 1;
    }
    return count;
}

pub fn getMonoFontCount() usize {
    var count: usize = 0;
    for (fonts[0..font_count]) |e| {
        if (e.category == .monospace) count += 1;
    }
    return count;
}

pub fn getTotalFontCount() usize {
    return font_count;
}

pub fn getFonts() []const FontEntry {
    return fonts[0..font_count];
}

pub fn findFontByName(name: []const u8) ?*const FontEntry {
    for (fonts[0..font_count]) |*e| {
        const stored = e.name[0..e.name_len];
        if (stored.len == name.len) {
            var ok = true;
            for (0..stored.len) |i| {
                if (stored[i] != name[i]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return e;
        }
    }
    return null;
}

pub fn isInitialized() bool {
    return initialized;
}
