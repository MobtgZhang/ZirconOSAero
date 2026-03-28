// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/aero/src/pe_icon_loader.zig
// Purpose: Placeholder for future user-mode PE icon extraction (LoadImage / RT_ICON); kernel keeps SVG + embedded bitmaps.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/menurc/resource-types (RT_ICON)
// Doc: docs/cn/NT61_ShellIcons.md (Win32 compatibility + zircon_shell32_res.dll).

const builtin = @import("builtin");
const std = @import("std");
const icon_resource_ids = @import("icon_resource_ids.zig");
const pe_icon_resource = @import("pe_icon_resource.zig");
const shell_icons_manifest = @import("shell_icons_manifest.zig");

/// Opaque handle for a decoded icon surface (future: DIB/RGBA / PNG decode).
pub const DecodedIcon = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// True when `RT_GROUP_ICON` resource bytes were located (decode to pixels not implemented).
    ready: bool = false,
};

fn loadIconFromPeBytes(pe: []const u8, resource_id: icon_resource_ids.PeIconId) ?DecodedIcon {
    const id_u: u32 = @intFromEnum(resource_id);
    const blob = pe_icon_resource.resourceDataById(pe, pe_icon_resource.rt_group_icon, id_u) orelse return null;
    if (blob.len < 14) return null;
    return .{
        .width = 0,
        .height = 0,
        .ready = true,
    };
}

/// Load metadata by locating `RT_GROUP_ICON` for `resource_id` in a PE file (host / user-mode).
/// Returns null on freestanding, I/O failure, or invalid PE. Does not call Win32 APIs.
pub fn loadIconResource(path: []const u8, resource_id: icon_resource_ids.PeIconId) ?DecodedIcon {
    switch (builtin.os.tag) {
        .freestanding, .wasi => return null,
        else => {},
    }
    var file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const max_read: usize = 16 * 1024 * 1024;
    const buf = std.heap.page_allocator.alloc(u8, max_read) catch return null;
    defer std.heap.page_allocator.free(buf);
    const n = file.readAll(buf) catch return null;
    return loadIconFromPeBytes(buf[0..n], resource_id);
}

fn loadPeDllFromDir(dir: *std.fs.Dir, resource_id: icon_resource_ids.PeIconId) ?DecodedIcon {
    var file = dir.openFile("zircon_shell32_res.dll", .{}) catch return null;
    defer file.close();
    const max_read: usize = 16 * 1024 * 1024;
    const buf = std.heap.page_allocator.alloc(u8, max_read) catch return null;
    defer std.heap.page_allocator.free(buf);
    const n = file.readAll(buf) catch return null;
    return loadIconFromPeBytes(buf[0..n], resource_id);
}

fn loadIcoFromDir(dir: *std.fs.Dir, resource_id: icon_resource_ids.PeIconId) ?DecodedIcon {
    const base = icon_resource_ids.icoBasenameForPeId(resource_id);
    var name_buf: [96]u8 = undefined;
    const ico_name = std.fmt.bufPrint(&name_buf, "{s}.ico", .{base}) catch return null;
    var f = dir.openFile(ico_name, .{}) catch return null;
    defer f.close();
    const sz = f.getEndPos() catch return null;
    if (sz < 6) return null;
    return .{
        .width = 0,
        .height = 0,
        .ready = true,
    };
}

/// Resolve icon using `zircon_shell32_res.manifest.json` when present under `system32_dir` (LoongArch bundle layout).
/// `binary_form: ico_bundle` loads sibling `.ico`; `pe_rsrc` / unknown tries `zircon_shell32_res.dll` then ICO.
/// Integration: compositor may pass `zig-out/.../loongarch64/win/System32` here; see `resource_loader.zig` module doc.
pub fn loadIconFromShellSystem32Dir(system32_dir: []const u8, resource_id: icon_resource_ids.PeIconId) ?DecodedIcon {
    switch (builtin.os.tag) {
        .freestanding, .wasi => return null,
        else => {},
    }
    var dir = std.fs.cwd().openDir(system32_dir, .{}) catch return null;
    const manifest_file = dir.openFile("zircon_shell32_res.manifest.json", .{}) catch {
        if (loadPeDllFromDir(&dir, resource_id)) |x| return x;
        return loadIcoFromDir(&dir, resource_id);
    };
    defer manifest_file.close();
    const max_m: usize = 256 * 1024;
    const mdata = manifest_file.readToEndAlloc(std.heap.page_allocator, max_m) catch return null;
    defer std.heap.page_allocator.free(mdata);
    switch (shell_icons_manifest.parseBinaryForm(mdata)) {
        .ico_bundle => return loadIcoFromDir(&dir, resource_id) orelse loadPeDllFromDir(&dir, resource_id),
        .pe_rsrc => return loadPeDllFromDir(&dir, resource_id) orelse loadIcoFromDir(&dir, resource_id),
        .unknown => return loadPeDllFromDir(&dir, resource_id) orelse loadIcoFromDir(&dir, resource_id),
    }
}

/// Parse `path,-123` style shell references; negative id is resource index convention on Windows — here we only accept explicit positive PE ids in 101–125.
pub fn loadIconFromShellReference(path: []const u8, negative_id: i32) ?DecodedIcon {
    _ = path;
    _ = negative_id;
    return null;
}
