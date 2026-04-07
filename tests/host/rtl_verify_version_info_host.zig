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
