//! SPDX-License-Identifier: MIT OR Apache-2.0
//!
//! ZirconOSAero — host-only build tool
//! Purpose: resolution sync + wallpaper asset management
//!

const std = @import("std");
const Build = std.Build;

pub const PreferredFbDims = struct {
    w: u32,
    h: u32,
};

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

pub fn parseResolutionFromBuildConfText(text: []const u8) !PreferredFbDims {
    var iter = std.mem.splitAny(u8, text, "x\n \t");
    const w_str = iter.next() orelse return error.InvalidResolution;
    const h_str = iter.next() orelse return error.InvalidResolution;
    const w = try std.fmt.parseInt(u32, w_str, 10);
    const h = try std.fmt.parseInt(u32, h_str, 10);
    return .{ .w = w, .h = h };
}

pub fn tryReadPreferredFbFromBuildConf(b: *Build) ?PreferredFbDims {
    var conf_dir = std.fs.cwd().openDir("src/config", .{ .iterate = true }) catch return null;
    defer conf_dir.close();

    var iter = conf_dir.iterate();
    while (iter.next() catch return null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".conf")) continue;

        const content = conf_dir.readFileAlloc(b.allocator, entry.name, 1 << 16) catch continue;
        defer b.allocator.free(content);

        var lines = std.mem.splitAny(u8, content, "\r\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "ZIRCON_RESOLUTION")) {
                const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"'");
                return parseResolutionFromBuildConfText(value) catch continue;
            }
        }
    }
    return null;
}

pub fn readPreferredFbFromSyncArtifact(b: *Build) ?PreferredFbDims {
    const content = std.fs.cwd().readFileAlloc(b.allocator, "build/tmp/kernel_pref_fb_wh.txt", 1 << 12) catch return null;
    defer b.allocator.free(content);
    return parseResolutionFromBuildConfText(content) catch return null;
}

pub fn ensureWallpaperPngAssetsPresent(b: *Build) void {
    for (wallpaper_png_inputs) |path| {
        std.fs.cwd().access(path, .{}) catch {
            std.debug.print("Missing wallpaper asset: {s}\nRunning placeholder generator...\n", .{path});
            const run_gen = b.addSystemCommand(&.{ "python3", "scripts/fetch/gen_wallpaper_placeholders.py" });
            run_gen.step.name = "generate wallpaper placeholders";
            b.getInstallStep().dependOn(&run_gen.step);
            return;
        };
    }
}
