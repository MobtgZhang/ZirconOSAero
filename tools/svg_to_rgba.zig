//! SPDX-License-Identifier: MIT OR Apache-2.0
//! ZirconOSAero — SVG to RGBA bitmap converter (Zig version)
//!
//! Replaces the Python svg_to_rgba.py, uses rsvg-convert as subprocess
//! and the built-in PNG decoder to produce RGBA files and manifest.zig.
//! Requires `librsvg` (rsvg-convert) installed on the build host.

const std = @import("std");
const png = @import("png");

const FileEntry = struct {
    name: []const u8,
    path: []const u8,
    size: u32,
};

const ICONS = [_]FileEntry{
    .{ .name = "ic_01_computer", .path = "src/desktop/aero/resources/icons/computer.svg", .size = 64 },
    .{ .name = "ic_02_documents", .path = "src/desktop/aero/resources/icons/documents.svg", .size = 64 },
    .{ .name = "ic_03_recycle_bin", .path = "src/desktop/aero/resources/icons/recycle_bin.svg", .size = 64 },
    .{ .name = "ic_04_terminal", .path = "src/desktop/aero/resources/icons/terminal.svg", .size = 64 },
    .{ .name = "ic_05_network", .path = "src/desktop/aero/resources/icons/network.svg", .size = 64 },
    .{ .name = "ic_06_browser", .path = "src/desktop/aero/resources/icons/browser.svg", .size = 64 },
    .{ .name = "ic_07_settings", .path = "src/desktop/aero/resources/icons/settings.svg", .size = 64 },
    .{ .name = "ic_08_calculator", .path = "src/desktop/aero/resources/icons/calculator.svg", .size = 64 },
    .{ .name = "ic_09_text_editor", .path = "src/desktop/aero/resources/icons/text_editor.svg", .size = 64 },
    .{ .name = "ic_10_pictures", .path = "src/desktop/aero/resources/icons/pictures.svg", .size = 64 },
    .{ .name = "ic_11_music", .path = "src/desktop/aero/resources/icons/music.svg", .size = 64 },
    .{ .name = "ic_12_folder", .path = "src/desktop/aero/resources/icons/folder.svg", .size = 64 },
    .{ .name = "ic_13_control_panel", .path = "src/desktop/aero/resources/icons/control_panel.svg", .size = 64 },
    .{ .name = "ic_14_file", .path = "src/desktop/aero/resources/icons/file.svg", .size = 64 },
    .{ .name = "ic_15_user", .path = "src/desktop/aero/resources/icons/user.svg", .size = 64 },
    .{ .name = "ic_16_lock", .path = "src/desktop/aero/resources/icons/lock.svg", .size = 64 },
    .{ .name = "ic_17_shutdown", .path = "src/desktop/aero/resources/icons/shutdown.svg", .size = 64 },
    .{ .name = "ic_18_recycle_bin_full", .path = "src/desktop/aero/resources/icons/recycle_bin_full.svg", .size = 64 },
    .{ .name = "ic_19_drive_fixed", .path = "src/desktop/aero/resources/icons/drive_fixed.svg", .size = 64 },
    .{ .name = "ic_20_drive_removable", .path = "src/desktop/aero/resources/icons/drive_removable.svg", .size = 64 },
    .{ .name = "ic_21_drive_optical", .path = "src/desktop/aero/resources/icons/drive_optical.svg", .size = 64 },
    .{ .name = "ic_22_printer", .path = "src/desktop/aero/resources/icons/printer.svg", .size = 64 },
    .{ .name = "ic_23_info", .path = "src/desktop/aero/resources/icons/info.svg", .size = 64 },
    .{ .name = "ic_24_warning", .path = "src/desktop/aero/resources/icons/warning.svg", .size = 64 },
    .{ .name = "ic_25_err", .path = "src/desktop/aero/resources/icons/error.svg", .size = 64 },
    .{ .name = "ic_26_favorites", .path = "src/desktop/aero/resources/icons/favorites.svg", .size = 64 },
    .{ .name = "ic_27_shell_desktop", .path = "src/desktop/aero/resources/icons/shell_desktop.svg", .size = 64 },
    .{ .name = "ic_28_downloads", .path = "src/desktop/aero/resources/icons/downloads.svg", .size = 64 },
    .{ .name = "ic_29_recent_places", .path = "src/desktop/aero/resources/icons/recent_places.svg", .size = 64 },
    .{ .name = "ic_30_library_root", .path = "src/desktop/aero/resources/icons/library_root.svg", .size = 64 },
    .{ .name = "ic_31_videos", .path = "src/desktop/aero/resources/icons/videos.svg", .size = 64 },
    .{ .name = "ic_32_homegroup", .path = "src/desktop/aero/resources/icons/homegroup.svg", .size = 64 },
};

const CURSORS = [_]FileEntry{
    .{ .name = "cur_01_arrow", .path = "src/desktop/aero/resources/cursors/zircon_arrow.svg", .size = 64 },
    .{ .name = "cur_02_link", .path = "src/desktop/aero/resources/cursors/zircon_link.svg", .size = 64 },
    .{ .name = "cur_03_text", .path = "src/desktop/aero/resources/cursors/zircon_text.svg", .size = 64 },
    .{ .name = "cur_04_busy", .path = "src/desktop/aero/resources/cursors/zircon_busy.svg", .size = 64 },
    .{ .name = "cur_05_nesw", .path = "src/desktop/aero/resources/cursors/zircon_nesw.svg", .size = 64 },
    .{ .name = "cur_06_ns", .path = "src/desktop/aero/resources/cursors/zircon_ns.svg", .size = 64 },
    .{ .name = "cur_07_ew", .path = "src/desktop/aero/resources/cursors/zircon_ew.svg", .size = 64 },
    .{ .name = "cur_08_move", .path = "src/desktop/aero/resources/cursors/zircon_move.svg", .size = 64 },
    .{ .name = "cur_09_pen", .path = "src/desktop/aero/resources/cursors/zircon_pen.svg", .size = 64 },
    .{ .name = "cur_10_help", .path = "src/desktop/aero/resources/cursors/zircon_help.svg", .size = 64 },
    .{ .name = "cur_11_working", .path = "src/desktop/aero/resources/cursors/zircon_working.svg", .size = 64 },
    .{ .name = "cur_12_unavail", .path = "src/desktop/aero/resources/cursors/zircon_unavail.svg", .size = 64 },
    .{ .name = "cur_13_up", .path = "src/desktop/aero/resources/cursors/zircon_up.svg", .size = 64 },
    .{ .name = "cur_14_nwse", .path = "src/desktop/aero/resources/cursors/zircon_nwse.svg", .size = 64 },
};

const LOGO = FileEntry{ .name = "logo", .path = "src/desktop/aero/resources/logo.svg", .size = 64 };
const START_ORB = FileEntry{ .name = "start_orb", .path = "src/desktop/aero/resources/start_orb.svg", .size = 64 };

fn convertSvgToRgba(allocator: std.mem.Allocator, svg_path: []const u8, size: u32) ![]u8 {
    // Run rsvg-convert to get PNG data
    const width_str = try std.fmt.allocPrint(allocator, "{d}", .{size});
    defer allocator.free(width_str);
    const height_str = try std.fmt.allocPrint(allocator, "{d}", .{size});
    defer allocator.free(height_str);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "rsvg-convert",
            "-w",
            width_str,
            "-h",
            height_str,
            "-f",
            "png",
            svg_path,
        },
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("找不到 'rsvg-convert' 命令，请先安装：sudo apt install librsvg2-bin", .{});
        }
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.log.err("rsvg-convert failed for {s}: {s}", .{ svg_path, result.stderr });
        return error.RsvgConvertFailed;
    }

    // Decode PNG to RGBA
    const rgba = try png.decodePixels(allocator, result.stdout);
    return rgba;
}

fn processFile(allocator: std.mem.Allocator, output_dir: []const u8, entry: FileEntry) !void {
    std.debug.print("Processing {s}: {s}\n", .{ entry.name, entry.path });

    // Check if SVG exists
    if (!std.fs.path.isAbsolute(entry.path)) {
        // Check relative to CWD
        const cwd = std.fs.cwd();
        _ = cwd.statFile(entry.path) catch |err| {
            std.log.err("SVG file not found: {s} ({})", .{ entry.path, err });
            return err;
        };
    }

    const rgba = try convertSvgToRgba(allocator, entry.path, entry.size);
    defer allocator.free(rgba);

    // Write RGBA file
    const filename = try std.fmt.allocPrint(allocator, "{s}.rgba", .{entry.name});
    defer allocator.free(filename);
    const output_path = try std.fs.path.join(allocator, &.{ output_dir, filename });
    defer allocator.free(output_path);

    var file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(rgba);
}

fn generateManifest(allocator: std.mem.Allocator, output_dir: []const u8) !void {
    // Write manifest file directly to avoid writer API issues
    const manifest_path = try std.fs.path.join(allocator, &.{ output_dir, "svg_embed_manifest.zig" });
    defer allocator.free(manifest_path);

    var file = try std.fs.cwd().createFile(manifest_path, .{});
    defer file.close();

    // Helper function to write formatted strings
    const writeFmt = struct {
        fn impl(f: std.fs.File, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
            const str = try std.fmt.allocPrint(alloc, fmt, args);
            defer alloc.free(str);
            _ = try f.write(str);
        }
    }.impl;

    try writeFmt(file, allocator, "// SPDX-License-Identifier: MIT OR Apache-2.0\n", .{});
    try writeFmt(file, allocator, "//! AUTO-GENERATED by tools/svg_to_rgba.zig — do not edit manually.\n", .{});
    try writeFmt(file, allocator, "//! This file contains pre-rasterized RGBA bitmaps for all SVG icons/logo/start_orb.\n\n", .{});

    try writeFmt(file, allocator, "pub const icon_count = {d};\n", .{ICONS.len});
    try writeFmt(file, allocator, "pub const cursor_count = {d};\n\n", .{CURSORS.len});

    try writeFmt(file, allocator, "pub const logo_w: u32 = {d};\n", .{LOGO.size});
    try writeFmt(file, allocator, "pub const logo_h: u32 = {d};\n", .{LOGO.size});
    try writeFmt(file, allocator, "pub const logo = @embedFile(\"logo.rgba\");\n\n", .{});

    try writeFmt(file, allocator, "pub const start_orb_w: u32 = {d};\n", .{START_ORB.size});
    try writeFmt(file, allocator, "pub const start_orb_h: u32 = {d};\n", .{START_ORB.size});
    try writeFmt(file, allocator, "pub const start_orb = @embedFile(\"start_orb.rgba\");\n\n", .{});

    // Write icons
    for (ICONS) |icon| {
        try writeFmt(file, allocator, "pub const {s}_w: u32 = {d};\n", .{ icon.name, icon.size });
        try writeFmt(file, allocator, "pub const {s}_h: u32 = {d};\n", .{ icon.name, icon.size });
        try writeFmt(file, allocator, "pub const {s} = @embedFile(\"{s}.rgba\");\n\n", .{ icon.name, icon.name });
    }

    // Write cursors
    for (CURSORS) |cursor| {
        try writeFmt(file, allocator, "pub const {s}_w: u32 = {d};\n", .{ cursor.name, cursor.size });
        try writeFmt(file, allocator, "pub const {s}_h: u32 = {d};\n", .{ cursor.name, cursor.size });
        try writeFmt(file, allocator, "pub const {s} = @embedFile(\"{s}.rgba\");\n\n", .{ cursor.name, cursor.name });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <output_directory>\n", .{args[0]});
        std.process.exit(1);
    }

    const output_dir = args[1];

    // Create output directory if it doesn't exist
    try std.fs.cwd().makePath(output_dir);

    // Process logo
    try processFile(allocator, output_dir, LOGO);

    // Process start orb
    try processFile(allocator, output_dir, START_ORB);

    // Process all icons
    for (ICONS) |icon| {
        try processFile(allocator, output_dir, icon);
    }

    // Process all cursors
    for (CURSORS) |cursor| {
        try processFile(allocator, output_dir, cursor);
    }

    // Generate manifest
    try generateManifest(allocator, output_dir);

    std.debug.print("\nDone! Output written to: {s}\n", .{output_dir});
    std.debug.print("  Logo: logo.rgba ({}x{})\n", .{ LOGO.size, LOGO.size });
    std.debug.print("  Start Orb: start_orb.rgba ({}x{})\n", .{ START_ORB.size, START_ORB.size });
    std.debug.print("  Icons: {} items\n", .{ICONS.len});
    std.debug.print("  Cursors: {} items\n", .{CURSORS.len});
}
