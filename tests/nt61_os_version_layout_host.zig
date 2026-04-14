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
// Module: tests/nt61_os_version_layout_host.zig
// Purpose: `NtQuerySystemInformation(SystemVersionInformation)` 缓冲长度锚点（与 `src/config/os_version.zig` `rtl_osversioninfoexw_bytes` 同源）。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows/win32/api/sysinfoapi/ns-sysinfoapi-osversioninfoexw

const std = @import("std");

/// 须与 `src/config/os_version.zig` `rtl_osversioninfoexw_bytes` 保持相等。
pub const rtl_osversioninfoexw_bytes_expected: u32 = 284;

test "SystemVersionInformation buffer size matches os_version.zig" {
    try std.testing.expectEqual(@as(u32, 284), rtl_osversioninfoexw_bytes_expected);
}
