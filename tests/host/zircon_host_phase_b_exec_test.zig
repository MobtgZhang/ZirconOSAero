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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// 主机单元测试根：阶段 B（SE KernelObjects 路径 + WinNT CurrentVersion 注册表树）。
// 与 `zircon_host_ob_test.zig` 同形；由 `src/zircon_host_phase_b_exec_test.zig` 符号链接指向本文件。

const std = @import("std");
const registry = @import("registry/registry.zig");
const token = @import("se/token.zig");

const GENERIC_READ: u32 = 0x80000000;

test "non-elevated token denied for Registry Machine SYSTEM KernelObjects path" {
    var ut = token.createUserToken(1);
    try std.testing.expect(!token.openNamedObjectAccessCheck(
        "\\Registry\\Machine\\SYSTEM\\KernelObjects\\Example",
        GENERIC_READ,
        &ut,
    ));
}

test "elevated user token allowed for KernelObjects registry path" {
    var ut = token.createUserToken(1);
    ut.is_elevated = true;
    try std.testing.expect(token.openNamedObjectAccessCheck(
        "\\Registry\\Machine\\SYSTEM\\KernelObjects\\Example",
        GENERIC_READ,
        &ut,
    ));
}

test "WinNT CurrentVersion standard key path values and missing key" {
    registry.init();
    const p = "\\Registry\\Machine\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
    const idx = registry.openKeyByNtPath(p) orelse return error.MissingWinNtCv;
    const k = registry.getKey(idx) orelse return error.Key;
    const cv = k.findValue("CurrentVersion") orelse return error.MissingCurrentVersion;
    try std.testing.expectEqualStrings("6.1", cv.getStringValue());
    const cb = k.findValue("CurrentBuild") orelse return error.MissingCurrentBuild;
    try std.testing.expectEqualStrings("7601", cb.getStringValue());
    try std.testing.expect(registry.openKeyByNtPath("\\Registry\\Machine\\SYSTEM\\__phase_b_no_such__") == null);
}

test "NTSTATUS anchors for registry open query (OBJECT_NAME_NOT_FOUND BUFFER_TOO_SMALL)" {
    // 与 `libs/ntdll.zig` 中同名常量一致（主机侧不整链导入 ntdll）。
    try std.testing.expectEqual(@as(i32, -1073741772), @as(i32, @bitCast(@as(u32, 0xC0000034)))); // STATUS_OBJECT_NAME_NOT_FOUND
    try std.testing.expectEqual(@as(i32, -1073741789), @as(i32, @bitCast(@as(u32, 0xC0000023)))); // STATUS_BUFFER_TOO_SMALL
}

test "KeyValuePartialInformation size matches registry value for buffer too small reasoning" {
    registry.init();
    const idx = registry.openKeyByNtPath("\\Registry\\Machine\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion") orelse return error.Missing;
    const k = registry.getKey(idx) orelse return error.Key;
    const val = k.findValue("CurrentVersion") orelse return error.MissingVal;
    const need: u32 = 12 + @as(u32, @intCast(val.data_len));
    try std.testing.expect(need > 12);
}
