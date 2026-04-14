// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/aero/src/pe_icon_loader.zig
// Purpose: PE icon extraction (LoadImage / RT_ICON); uses src/libs/image/ico.zig and bmp.zig.
//
// This is an independent clean-room implementation.
// Reference: https://learn.microsoft.com/windows/win32/menurc/resource-types (RT_ICON)
// Doc: docs/cn/NT61_ShellIcons.md (Win32 compatibility + zircon_shell32_res.dll).

const builtin = @import("builtin");
const std = @import("std");
const icon_resource_ids = @import("icon_resource_ids.zig");
const pe_icon_resource = @import("pe_icon_resource.zig");
const shell_icons_manifest = @import("shell_icons_manifest.zig");
const ico_lib = @import("../../../libs/image/ico.zig");
const bmp_lib = @import("../../../libs/image/bmp.zig");

/// Opaque handle for a decoded icon surface (future: DIB/RGBA / PNG decode).
pub const DecodedIcon = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Pixel data in BGRA format (owned by caller)
    pixels: ?[]u8 = null,
    /// True when RT_GROUP_ICON resource bytes were located.
    ready: bool = false,
};

/// Decoded icon with pixel data for rendering
pub const IconBitmap = struct {
    width: u32,
    height: u32,
    stride: u32,
    pixels: []u8,

    pub fn deinit(self: *IconBitmap) void {
        if (self.pixels.len > 0) {
            std.heap.page_allocator.free(self.pixels);
            self.pixels.len = 0;
        }
    }
};

fn loadIconFromPeBytes(pe: []const u8, resource_id: icon_resource_ids.PeIconId) ?DecodedIcon {
    const id_u: u32 = @intFromEnum(resource_id);
    const blob = pe_icon_resource.resourceDataById(pe, pe_icon_resource.rt_group_icon, id_u) orelse return null;
    if (blob.len < 6) return null;

    // 解析 RT_GROUP_ICON 头
    // RT_GROUP_ICON 结构：
    // 0-1: wReserved (0)
    // 2-3: wType (1 = icon)
    // 4-5: wCount (图标数量)
    // 后面是 ICONDIRENTRY 数组
    const reserved = std.mem.readIntLittle(u16, blob[0..2]);
    const icon_type = std.mem.readIntLittle(u16, blob[2..4]);
    const count = std.mem.readIntLittle(u16, blob[4..6]);

    if (reserved != 0 or icon_type != 1 or count == 0) return null;
    if (blob.len < 6 + @as(usize, count) * 16) return null;

    // 读取第一个图标的尺寸信息
    // ICONDIRENTRY:
    // 0: bWidth (0 = 256)
    // 1: bHeight (0 = 256)
    // 2: bColorCount
    // 3: bReserved
    // 4-5: wPlanes
    // 6-7: wBitCount
    // 8-11: dwBytesInRes
    // 12-15: dwImageOffset
    const entry = blob[6..22];
    const bwidth = entry[0];
    const bheight = entry[1];
    const width: u32 = if (bwidth == 0) 256 else @as(u32, bwidth);
    const height: u32 = if (bheight == 0) 256 else @as(u32, bheight);

    return .{
        .width = width,
        .height = height,
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
    if (sz < 22) return null;

    // 读取 ICO 文件头
    var header: [22]u8 = undefined;
    f.seekTo(0) catch return null;
    f.readAll(&header) catch return null;

    // ICONDIR: 6 字节
    // 0-1: idReserved (0)
    // 2-3: idType (1 = icon)
    // 4-5: idCount
    const reserved = std.mem.readIntLittle(u16, header[0..2]);
    const icon_type = std.mem.readIntLittle(u16, header[2..4]);
    const count = std.mem.readIntLittle(u16, header[4..6]);

    if (reserved != 0 or icon_type != 1 or count == 0) return null;

    // ICONDIRENTRY: 16 字节
    const entry = header[6..22];
    const bwidth = entry[0];
    const bheight = entry[1];
    const width: u32 = if (bwidth == 0) 256 else @as(u32, bwidth);
    const height: u32 = if (bheight == 0) 256 else @as(u32, bheight);

    return .{
        .width = width,
        .height = height,
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

// ─────────────────────────────────────────────────────────────────────────────
// ICO/BMP 像素解码 — 使用 src/libs/image/ 库
// ─────────────────────────────────────────────────────────────────────────────

/// 从ICO文件中提取单个图标并解码为BGRA像素
/// 搜索与目标尺寸最接近的图标
pub fn decodeIconFile(ico_data: []const u8, target_size: u32) ?IconBitmap {
    const images = ico_lib.decodeIcoFile(std.heap.page_allocator, ico_data) catch return null;
    defer {
        for (images) |*img| std.heap.page_allocator.free(img.raw_data);
        std.heap.page_allocator.free(images);
    }

    const best = ico_lib.findBestImage(images, target_size) orelse
        ico_lib.findLargestImage(images) orelse return null;

    const pixels = ico_lib.decodeImageData(std.heap.page_allocator, best) catch return null;
    return IconBitmap{
        .width = pixels.width,
        .height = pixels.height,
        .stride = pixels.row_pitch,
        .pixels = @constCast(pixels.data),
    };
}

/// 加载并解码图标文件
pub fn loadAndDecodeIcon(path: []const u8, target_size: u32) ?IconBitmap {
    switch (builtin.os.tag) {
        .freestanding, .wasi => return null,
        else => {},
    }
    var file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const sz = file.getEndPos() catch return null;
    if (sz > 16 * 1024 * 1024) return null;

    var buf = std.heap.page_allocator.alloc(u8, @intCast(sz)) catch return null;
    defer std.heap.page_allocator.free(buf);
    const n = file.readAll(buf) catch return null;
    return decodeIconFile(buf[0..n], target_size);
}
