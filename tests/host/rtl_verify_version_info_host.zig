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
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/host/rtl_verify_version_info_host.zig
// Purpose: 主机验证 `config/os_version.zig` 中 `verSetConditionMask` / `rtlVerifyVersionInfo`。
//
// Ref: https://learn.microsoft.com/windows/win32/devnotes/rtlverifyversioninfo

const std = @import("std");
const osv = @import("config/os_version.zig");

const STATUS_NOT_EQUAL: i32 = @bitCast(@as(u32, 0xC0000159));

test "rtlVerifyVersionInfo: major/minor equal to os_version defaults" {
    var cond: u64 = 0;
    cond = osv.verSetConditionMask(cond, osv.VER_MAJORVERSION, osv.VER_EQUAL);
    cond = osv.verSetConditionMask(cond, osv.VER_MINORVERSION, osv.VER_EQUAL);
    const st = osv.rtlVerifyVersionInfo(
        osv.major(),
        osv.minor(),
        0,
        osv.platformId(),
        osv.servicePackMajor(),
        osv.productType(),
        osv.VER_MAJORVERSION | osv.VER_MINORVERSION,
        cond,
    );
    try std.testing.expectEqual(@as(i32, 0), st);
}

test "rtlVerifyVersionInfo: not equal when required major differs" {
    var cond: u64 = 0;
    cond = osv.verSetConditionMask(cond, osv.VER_MAJORVERSION, osv.VER_EQUAL);
    const st = osv.rtlVerifyVersionInfo(
        osv.major() + 1,
        osv.minor(),
        osv.buildNumber(),
        osv.platformId(),
        osv.servicePackMajor(),
        osv.productType(),
        osv.VER_MAJORVERSION,
        cond,
    );
    try std.testing.expectEqual(STATUS_NOT_EQUAL, st);
}

test "rtlVerifyVersionInfo: build greater_equal" {
    var cond: u64 = 0;
    cond = osv.verSetConditionMask(cond, osv.VER_BUILDNUMBER, osv.VER_GREATER_EQUAL);
    const st = osv.rtlVerifyVersionInfo(
        0,
        0,
        osv.buildNumber() -| 1,
        0,
        0,
        0,
        osv.VER_BUILDNUMBER,
        cond,
    );
    try std.testing.expectEqual(@as(i32, 0), st);
}
