//! Build-time helpers: wallpaper PNG list + preferred FB resolution (imported from `build.zig`).
const std = @import("std");

pub const PreferredFbDims = struct { w: u32, h: u32 };

pub const wallpaper_png_inputs = [_][]const u8{
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_harmony.png",
    "src/desktop/aero/resources/wallpapers/Nature/zircon_default.png",
    "src/desktop/aero/resources/wallpapers/Architecture/zircon_crystal.png",
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_aurora.png",
    "src/desktop/aero/resources/wallpapers/Characters/zircon_characters.png",
    "src/desktop/aero/resources/wallpapers/Nature/zircon_nature.png",
    "src/desktop/aero/resources/wallpapers/Scenes/zircon_scenes.png",
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_landscapes.png",
    "src/desktop/aero/resources/wallpapers/Architecture/zircon_architecture.png",
    "src/desktop/aero/resources/wallpapers/Nature/zircon_ocean.png",
    "src/desktop/aero/resources/wallpapers/Scenes/zircon_nebula.png",
    "src/desktop/aero/resources/wallpapers/Landscapes/zircon_landscape.png",
};

pub fn parseResolutionFromBuildConfText(content: []const u8) ?PreferredFbDims {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (!std.mem.startsWith(u8, trimmed, "RESOLUTION")) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        var val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (std.mem.indexOfScalar(u8, val, '#')) |hi| {
            val = std.mem.trim(u8, val[0..hi], " \t");
        }
        var parts = std.mem.splitScalar(u8, val, 'x');
        const ws = parts.next() orelse continue;
        const hs = parts.next() orelse continue;
        const w = std.fmt.parseUnsigned(u32, ws, 10) catch continue;
        const h = std.fmt.parseUnsigned(u32, hs, 10) catch continue;
        if (w == 0 or h == 0) continue;
        return .{ .w = w, .h = h };
    }
    return null;
}

pub fn readPreferredFbFromSyncArtifact(b: *std.Build) ?PreferredFbDims {
    const path = "build/tmp/kernel_pref_fb_wh.txt";
    const file = b.build_root.handle.openFile(path, .{}) catch return null;
    defer file.close();
    const max_bytes: usize = 128;
    const raw = file.readToEndAlloc(b.allocator, max_bytes) catch return null;
    defer b.allocator.free(raw);
    var iter = std.mem.splitScalar(u8, raw, '\n');
    const wline = std.mem.trim(u8, iter.next() orelse return null, " \t\r");
    const hline = std.mem.trim(u8, iter.next() orelse return null, " \t\r");
    if (wline.len == 0 or hline.len == 0) return null;
    const w = std.fmt.parseUnsigned(u32, wline, 10) catch return null;
    const h = std.fmt.parseUnsigned(u32, hline, 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

pub fn tryReadPreferredFbFromBuildConf(b: *std.Build) ?PreferredFbDims {
    const file = b.build_root.handle.openFile("build.conf", .{}) catch return null;
    defer file.close();
    const max_bytes: usize = 65536;
    const raw = file.readToEndAlloc(b.allocator, max_bytes) catch return null;
    defer b.allocator.free(raw);
    return parseResolutionFromBuildConfText(raw);
}

pub fn ensureWallpaperPngAssetsPresent(b: *std.Build) void {
    for (wallpaper_png_inputs) |rel| {
        b.build_root.handle.access(rel, .{}) catch {
            std.log.err("Missing wallpaper PNG: {s}\n  Add the file or generate placeholders: bash scripts/fetch-assets.sh\n", .{rel});
            std.process.exit(1);
        };
    }
}
