//! Theme Configuration Loader
//! Parses .theme INI-format files and maps them to internal ColorScheme values.
//! Compatible with NT6.1-style theme definitions used by ZirconOS Aero DWM.
//!
//! The loader reads theme file content (provided as a byte slice) and extracts
//! DWM glass parameters, colorization settings, and wallpaper paths. This allows
//! the shell to apply user-selected themes at runtime without recompilation.

const theme = @import("theme.zig");

pub const ThemeConfig = struct {
    display_name: [128]u8 = [_]u8{0} ** 128,
    display_name_len: u8 = 0,
    theme_id: [64]u8 = [_]u8{0} ** 64,
    theme_id_len: u8 = 0,
    wallpaper: [128]u8 = [_]u8{0} ** 128,
    wallpaper_len: u8 = 0,
    color_scheme: theme.ColorScheme = .zircon_blue,

    glass_blur_radius: u8 = 12,
    glass_tint_opacity: u8 = 45,
    glass_opacity: u8 = 180,
    glass_reflection: u8 = 20,
    taskbar_height: i32 = 40,
    titlebar_height: i32 = 30,

    colorization_color: u32 = 0x7830A0E0,
    tint_r: u8 = 24,
    tint_g: u8 = 80,
    tint_b: u8 = 160,

    valid: bool = false,
};

const MAX_THEMES: usize = 16;
var loaded_themes: [MAX_THEMES]ThemeConfig = [_]ThemeConfig{.{}} ** MAX_THEMES;
var theme_count: usize = 0;

pub fn getLoadedThemes() []const ThemeConfig {
    return loaded_themes[0..theme_count];
}

pub fn getThemeCount() usize {
    return theme_count;
}

pub fn getThemeByIndex(index: usize) ?*const ThemeConfig {
    if (index < theme_count) return &loaded_themes[index];
    return null;
}

pub fn findThemeById(id: []const u8) ?*const ThemeConfig {
    for (loaded_themes[0..theme_count]) |*tc| {
        const stored_id = tc.theme_id[0..tc.theme_id_len];
        if (stored_id.len == id.len) {
            var match = true;
            for (0..stored_id.len) |i| {
                if (stored_id[i] != id[i]) {
                    match = false;
                    break;
                }
            }
            if (match) return tc;
        }
    }
    return null;
}

fn setField(dest: []u8, src: []const u8) u8 {
    const len = @min(src.len, dest.len);
    for (0..len) |i| {
        dest[i] = src[i];
    }
    return @intCast(len);
}

fn trimValue(line: []const u8) []const u8 {
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) {
        start += 1;
    }
    var end = line.len;
    while (end > start and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r' or line[end - 1] == '\n')) {
        end -= 1;
    }
    return line[start..end];
}

fn findEquals(line: []const u8) ?usize {
    for (0..line.len) |i| {
        if (line[i] == '=') return i;
    }
    return null;
}

fn matchesThemeId(id: []const u8) theme.ColorScheme {
    const ids = [_]struct { name: []const u8, cs: theme.ColorScheme }{
        .{ .name = "zircon_aero_blue", .cs = .zircon_blue },
        .{ .name = "aero-graphite", .cs = .zircon_graphite },
        .{ .name = "zircon_aero", .cs = .zircon_blue },
        .{ .name = "aero", .cs = .zircon_blue },
        .{ .name = "zircon_aero_characters", .cs = .zircon_characters },
        .{ .name = "zircon_aero_nature", .cs = .zircon_nature },
        .{ .name = "zircon_aero_scenes", .cs = .zircon_scenes },
        .{ .name = "zircon_aero_landscapes", .cs = .zircon_landscapes },
        .{ .name = "zircon_aero_architecture", .cs = .zircon_architecture },
    };

    for (ids) |entry| {
        if (entry.name.len == id.len) {
            var ok = true;
            for (0..entry.name.len) |i| {
                if (entry.name[i] != id[i]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return entry.cs;
        }
    }
    return .zircon_blue;
}

fn parseU8(val: []const u8) u8 {
    var result: u16 = 0;
    for (val) |c| {
        if (c >= '0' and c <= '9') {
            result = result * 10 + (c - '0');
            if (result > 255) return 255;
        }
    }
    return @intCast(@min(result, 255));
}

fn parseI32(val: []const u8) i32 {
    var result: i32 = 0;
    var negative = false;
    var started = false;
    for (val) |c| {
        if (c == '-' and !started) {
            negative = true;
            started = true;
        } else if (c >= '0' and c <= '9') {
            result = result * 10 + @as(i32, c - '0');
            started = true;
        }
    }
    return if (negative) -result else result;
}

pub fn loadTheme(data: []const u8) ?*const ThemeConfig {
    if (theme_count >= MAX_THEMES) return null;

    var tc = &loaded_themes[theme_count];
    tc.* = .{};

    var pos: usize = 0;
    while (pos < data.len) {
        var line_end = pos;
        while (line_end < data.len and data[line_end] != '\n') {
            line_end += 1;
        }
        const raw_line = data[pos..line_end];
        pos = if (line_end < data.len) line_end + 1 else line_end;

        const line = trimValue(raw_line);
        if (line.len == 0) continue;
        if (line[0] == ';') continue;
        if (line[0] == '[') continue;

        if (findEquals(line)) |eq_pos| {
            const key = trimValue(line[0..eq_pos]);
            const val = trimValue(line[eq_pos + 1 ..]);

            if (eqlStr(key, "DisplayName")) {
                tc.display_name_len = setField(&tc.display_name, val);
            } else if (eqlStr(key, "ThemeId")) {
                tc.theme_id_len = setField(&tc.theme_id, val);
                tc.color_scheme = matchesThemeId(val);
            } else if (eqlStr(key, "Wallpaper")) {
                tc.wallpaper_len = setField(&tc.wallpaper, val);
            } else if (eqlStr(key, "BlurRadius")) {
                tc.glass_blur_radius = parseU8(val);
            } else if (eqlStr(key, "TintOpacity")) {
                tc.glass_tint_opacity = parseU8(val);
            } else if (eqlStr(key, "GlassOpacity")) {
                tc.glass_opacity = parseU8(val);
            } else if (eqlStr(key, "ReflectionIntensity")) {
                tc.glass_reflection = parseU8(val);
            } else if (eqlStr(key, "Height")) {
                tc.taskbar_height = parseI32(val);
            }
        }
    }

    tc.valid = tc.display_name_len > 0;
    if (tc.valid) {
        theme_count += 1;
        return tc;
    }
    return null;
}

fn eqlStr(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

pub fn registerBuiltinThemes() void {
    const builtins = [_]struct { name: []const u8, id: []const u8, cs: theme.ColorScheme }{
        .{ .name = "ZirconOS Aero", .id = "zircon_aero", .cs = .zircon_blue },
        .{ .name = "ZirconOS Aero Blue", .id = "zircon_aero_blue", .cs = .zircon_blue },
        .{ .name = "ZirconOS Aero Graphite", .id = "aero-graphite", .cs = .zircon_graphite },
        .{ .name = "ZirconOS Aero - Characters", .id = "zircon_aero_characters", .cs = .zircon_characters },
        .{ .name = "ZirconOS Aero - Nature", .id = "zircon_aero_nature", .cs = .zircon_nature },
        .{ .name = "ZirconOS Aero - Scenes", .id = "zircon_aero_scenes", .cs = .zircon_scenes },
        .{ .name = "ZirconOS Aero - Landscapes", .id = "zircon_aero_landscapes", .cs = .zircon_landscapes },
        .{ .name = "ZirconOS Aero - Architecture", .id = "zircon_aero_architecture", .cs = .zircon_architecture },
    };

    for (builtins) |b| {
        if (theme_count >= MAX_THEMES) break;
        var tc = &loaded_themes[theme_count];
        tc.* = .{};
        tc.display_name_len = setField(&tc.display_name, b.name);
        tc.theme_id_len = setField(&tc.theme_id, b.id);
        tc.color_scheme = b.cs;

        const sc = theme.getScheme(b.cs);
        tc.glass_opacity = sc.glass_opacity;
        tc.glass_tint_opacity = sc.glass_tint_opacity;
        tc.valid = true;
        theme_count += 1;
    }
}

pub fn applyThemeConfig(tc: *const ThemeConfig) void {
    theme.setActiveScheme(tc.color_scheme);
}
