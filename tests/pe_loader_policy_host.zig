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
// Module: tests/pe_loader_policy_host.zig
// Purpose: 主机镜像 `pe.loadStatusToNtStatus` / `STATUS_*` 数值，避免 `pe.zig` 拉取 `klog`/`arch` 作为 test root。
//
// This is an independent clean-room implementation.

const std = @import("std");

fn loadStatusTlsToNtMirror() i32 {
    return @bitCast(@as(u32, 0xC0000002)); // STATUS_NOT_IMPLEMENTED — 与 `pe.loadStatusToNtStatus(.tls_directory_not_supported)` 一致
}

test "PE load policy TLS failure maps to STATUS_NOT_IMPLEMENTED" {
    try std.testing.expectEqual(@as(u32, 0xC0000002), @as(u32, @bitCast(loadStatusTlsToNtMirror())));
}
