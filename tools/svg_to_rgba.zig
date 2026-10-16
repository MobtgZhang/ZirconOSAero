// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! SPDX-License-Identifier: MIT OR Apache-2.0
//! ZirconOSAero — SVG to RGBA bitmap converter (Zig version)
//!
//! Replaces the Python svg_to_rgba.py, uses rsvg-convert or Inkscape as a subprocess
//! and the built-in PNG decoder to produce RGBA files and manifest.zig.
//! Requires `librsvg` (rsvg-convert) or Inkscape installed on the build host.

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

fn convertSvgToRgbaWith(io: std.Io, allocator: std.mem.Allocator, renderer_path: []const u8, svg_path: []const u8, size: u32) !png.PixelBuffer {
    const width_str = try std.fmt.allocPrint(allocator, "{d}", .{size});
    defer allocator.free(width_str);
    const height_str = try std.fmt.allocPrint(allocator, "{d}", .{size});
    defer allocator.free(height_str);

    if (std.mem.eql(u8, renderer_path, "inkscape")) {
        var random_bytes: [4]u8 = undefined;
        io.random(&random_bytes);
        const random_id = std.mem.readInt(u32, &random_bytes, .little);
        const png_filename = try std.fmt.allocPrint(allocator, "zircon-svg-{d}.png", .{random_id});
        defer allocator.free(png_filename);
        const png_path = try std.fs.path.join(allocator, &.{ "/tmp", png_filename });
        defer allocator.free(png_path);

        const result = try std.process.run(allocator, io, .{
            .argv = &.{ renderer_path, "--export-type=png", "--export-width", width_str, "--export-height", height_str, "--export-filename", png_path, svg_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited != 0) {
            std.log.err("{s} failed for {s}: {s}", .{ renderer_path, svg_path, result.stderr });
            return error.SvgRenderFailed;
        }

        const png_data = try std.Io.Dir.cwd().readFileAlloc(io, png_path, allocator, .limited(512 * 1024 * 1024));
        defer allocator.free(png_data);
        return png.decode(allocator, png_data);
    }

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ renderer_path, "-w", width_str, "-h", height_str, "-f", "png", svg_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited != 0) {
        std.log.err("{s} failed for {s}: {s}", .{ renderer_path, svg_path, result.stderr });
        return error.SvgRenderFailed;
    }

    return png.decode(allocator, result.stdout);
}

fn convertSvgToRgba(io: std.Io, allocator: std.mem.Allocator, svg_path: []const u8, size: u32) !png.PixelBuffer {
    if (convertSvgToRgbaWith(io, allocator, "rsvg-convert", svg_path, size)) |rgba| {
        return rgba;
    } else |err| {
        if (err != error.FileNotFound) return err;
        return convertSvgToRgbaWith(io, allocator, "inkscape", svg_path, size);
    }
}

fn processFile(io: std.Io, allocator: std.mem.Allocator, output_dir: []const u8, entry: FileEntry) !void {
    std.debug.print("Processing {s}: {s}\n", .{ entry.name, entry.path });

    // Check if SVG exists
    if (!std.fs.path.isAbsolute(entry.path)) {
        // Check relative to CWD
        _ = std.Io.Dir.cwd().statFile(io, entry.path, .{}) catch |err| {
            std.log.err("SVG file not found: {s} ({})", .{ entry.path, err });
            return err;
        };
    }

    const rgba = try convertSvgToRgba(io, allocator, entry.path, entry.size);
    defer rgba.free(allocator);

    // Write RGBA file
    const filename = try std.fmt.allocPrint(allocator, "{s}.rgba", .{entry.name});
    defer allocator.free(filename);
    const output_path = try std.fs.path.join(allocator, &.{ output_dir, filename });
    defer allocator.free(output_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = rgba.data });
}

fn generateManifest(io: std.Io, allocator: std.mem.Allocator, output_dir: []const u8) !void {
    // Write manifest file directly to avoid writer API issues
    const manifest_path = try std.fs.path.join(allocator, &.{ output_dir, "svg_embed_manifest.zig" });
    defer allocator.free(manifest_path);

    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(allocator);
    const w = &manifest;

    try w.print(allocator, "// SPDX-License-Identifier: MIT OR Apache-2.0\n", .{});
    try w.print(allocator, "//! AUTO-GENERATED by tools/svg_to_rgba.zig — do not edit manually.\n", .{});
    try w.print(allocator, "//! This file contains pre-rasterized RGBA bitmaps for all SVG icons/logo/start_orb.\n\n", .{});

    try w.print(allocator, "pub const icon_count = {d};\n", .{ICONS.len});
    try w.print(allocator, "pub const cursor_count = {d};\n\n", .{CURSORS.len});

    try w.print(allocator, "pub const logo_w: u32 = {d};\n", .{LOGO.size});
    try w.print(allocator, "pub const logo_h: u32 = {d};\n", .{LOGO.size});
    try w.print(allocator, "pub const logo = @embedFile(\"logo.rgba\");\n\n", .{});

    try w.print(allocator, "pub const start_orb_w: u32 = {d};\n", .{START_ORB.size});
    try w.print(allocator, "pub const start_orb_h: u32 = {d};\n", .{START_ORB.size});
    try w.print(allocator, "pub const start_orb = @embedFile(\"start_orb.rgba\");\n\n", .{});

    // Write icons
    for (ICONS) |icon| {
        try w.print(allocator, "pub const {s}_w: u32 = {d};\n", .{ icon.name, icon.size });
        try w.print(allocator, "pub const {s}_h: u32 = {d};\n", .{ icon.name, icon.size });
        try w.print(allocator, "pub const {s} = @embedFile(\"{s}.rgba\");\n\n", .{ icon.name, icon.name });
    }

    // Write cursors
    for (CURSORS) |cursor| {
        try w.print(allocator, "pub const {s}_w: u32 = {d};\n", .{ cursor.name, cursor.size });
        try w.print(allocator, "pub const {s}_h: u32 = {d};\n", .{ cursor.name, cursor.size });
        try w.print(allocator, "pub const {s} = @embedFile(\"{s}.rgba\");\n\n", .{ cursor.name, cursor.name });
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest.items });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <output_directory>\n", .{args[0]});
        std.process.exit(1);
    }

    const output_dir = args[1];

    // Create output directory if it doesn't exist
    try std.Io.Dir.cwd().createDirPath(io, output_dir);

    // Process logo
    try processFile(io, allocator, output_dir, LOGO);

    // Process start orb
    try processFile(io, allocator, output_dir, START_ORB);

    // Process all icons
    for (ICONS) |icon| {
        try processFile(io, allocator, output_dir, icon);
    }

    // Process all cursors
    for (CURSORS) |cursor| {
        try processFile(io, allocator, output_dir, cursor);
    }

    // Generate manifest
    try generateManifest(io, allocator, output_dir);

    std.debug.print("\nDone! Output written to: {s}\n", .{output_dir});
    std.debug.print("  Logo: logo.rgba ({}x{})\n", .{ LOGO.size, LOGO.size });
    std.debug.print("  Start Orb: start_orb.rgba ({}x{})\n", .{ START_ORB.size, START_ORB.size });
    std.debug.print("  Icons: {} items\n", .{ICONS.len});
    std.debug.print("  Cursors: {} items\n", .{CURSORS.len});
}
