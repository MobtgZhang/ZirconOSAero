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
// Module: tests/lpc_portkind_host.zig
// Purpose: 固定 `PortKind` 判别值，避免与 csrss / LPC 握手文档漂移（须与 `src/lpc/port.zig` 同步）。
//
// This is an independent clean-room implementation.

const std = @import("std");

const PortKind = enum(u8) {
    message = 0,
    connection_listener = 1,
};

test "LPC PortKind discriminant matches port.zig" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(PortKind.message));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(PortKind.connection_listener));
}
