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

//! Explorer 地址栏 / 盘符文案（`verbose` vs `pe_compact`），与 `desktop.conf` + `shell_mui` 对齐。

const std = @import("std");
const config = @import("../../../config/config.zig");
const explorer_vol_snap = @import("../../../fs/explorer_volume_snapshot.zig");
const shell_mui = @import("../strings/shell_mui.zig");

fn upperLetter(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

/// 侧栏/树中磁盘行：`C:` 或 `Local Disk (C:)` / 中文「本地磁盘 (C:)」
pub fn formatDriveNavLabel(buf: []u8, letter: u8) []const u8 {
    const L = upperLetter(letter);
    if (config.isExplorerDriveLabelPeCompact()) {
        return std.fmt.bufPrint(buf, "{c}:", .{L}) catch "C:";
    }
    if (shell_mui.active_lang == .zh_cn) {
        return std.fmt.bufPrint(buf, "本地磁盘 ({c}:)", .{L}) catch "C:";
    }
    return std.fmt.bufPrint(buf, "Local Disk ({c}:)", .{L}) catch "Local Disk (C:)";
}

/// 主区大图标下第二行：固定/可移动盘与侧栏策略一致；光驱用 DVD 描述。
pub fn formatDriveTileSubtitle(buf: []u8, letter: u8, kind: explorer_vol_snap.ExplorerVolKind) []const u8 {
    const L = upperLetter(letter);
    switch (kind) {
        .optical => {
            if (shell_mui.active_lang == .zh_cn) {
                return std.fmt.bufPrint(buf, "DVD RW 驱动器 ({c}:)", .{L}) catch "DVD";
            }
            return std.fmt.bufPrint(buf, "DVD RW Drive ({c}:)", .{L}) catch "DVD";
        },
        else => return formatDriveNavLabel(buf, letter),
    }
}

/// NT 路径前缀 `C:\`（大写盘符）
pub fn formatDriveRootPath(buf: []u8, letter: u8) []const u8 {
    const L = upperLetter(letter);
    return std.fmt.bufPrint(buf, "{c}:\\", .{L}) catch "C:\\";
}

/// 格式化带子目录的路径
pub fn formatSubdirectoryPath(buf: []u8, letter: u8, subpath: []const u8) []const u8 {
    const L = upperLetter(letter);
    return std.fmt.bufPrint(buf, "{c}:\\{s}\\", .{ L, subpath }) catch formatDriveRootPath(buf, letter);
}

pub const AddressBarKind = enum { libraries, computer, drive };

var addr_scratch: [256]u8 = undefined;

/// 地址栏文本（客户区坐标系内绘制用，写入 `buf`）
/// 支持子目录路径
pub fn formatAddressBar(buf: []u8, kind: AddressBarKind, drive_letter: u8) []const u8 {
    return formatAddressBarWithSubpath(buf, kind, drive_letter, null);
}

/// 地址栏文本（支持子目录路径）
pub fn formatAddressBarWithSubpath(buf: []u8, kind: AddressBarKind, drive_letter: u8, subpath: ?[]const u8) []const u8 {
    switch (kind) {
        .libraries => {
            const t = shell_mui.loadString(.ex_lib_title, &addr_scratch);
            if (t.len <= buf.len) {
                @memcpy(buf[0..t.len], t);
                return buf[0..t.len];
            }
            return t;
        },
        .computer => {
            const comp = shell_mui.loadString(.ex_addr_computer, &addr_scratch);
            if (comp.len <= buf.len) {
                @memcpy(buf[0..comp.len], comp);
                return buf[0..comp.len];
            }
            return comp;
        },
        .drive => {
            if (subpath) |sp| {
                // 显示带子目录的完整路径
                var path_buf: [256]u8 = undefined;
                const full_path = formatSubdirectoryPath(&path_buf, drive_letter, sp);
                const comp = shell_mui.loadString(.ex_addr_computer, &addr_scratch);
                return std.fmt.bufPrint(buf, "{s} ▸ {s}", .{ comp, full_path }) catch full_path;
            } else {
                var path_buf: [8]u8 = undefined;
                const path = formatDriveRootPath(&path_buf, drive_letter);
                const comp = shell_mui.loadString(.ex_addr_computer, &addr_scratch);
                return std.fmt.bufPrint(buf, "{s} ▸ {s}", .{ comp, path }) catch path;
            }
        },
    }
}

/// 用量条旁「38 GB free of 100 GB」类文案；`space_known == false` 时返回占位「—」。
pub fn formatVolumeFreeCaption(buf: []u8, free_mb: u32, total_mb: u32, space_known: bool) []const u8 {
    if (!space_known) {
        var scratch: [96]u8 = undefined;
        const u = shell_mui.loadString(.ex_space_unknown, &scratch);
        if (u.len <= buf.len) {
            @memcpy(buf[0..u.len], u);
            return buf[0..u.len];
        }
        return u;
    }
    const fgb = free_mb / 1024;
    const tgb = @max(total_mb / 1024, 1);
    if (shell_mui.active_lang == .zh_cn) {
        return std.fmt.bufPrint(buf, "可用 {d} GB，共 {d} GB", .{ fgb, tgb }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d} GB free of {d} GB", .{ fgb, tgb }) catch "";
}
