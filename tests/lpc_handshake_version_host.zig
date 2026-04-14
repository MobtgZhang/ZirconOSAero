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
// Module: tests/lpc_handshake_version_host.zig
// Purpose: 固定 `Port.handshake_version` 与 [LPC_NT61_HANDSHAKE.md](../docs/cn/LPC_NT61_HANDSHAKE.md)；改 `src/lpc/port.zig` 时须同步。
//
// This is an independent clean-room implementation.

const std = @import("std");

/// 须与 `src/lpc/port.zig` `Port.init` / 默认 `handshake_version` 一致。
pub const lpc_handshake_version_expected: u8 = 2;

test "LPC handshake version matches port.zig" {
    try std.testing.expectEqual(@as(u8, 2), lpc_handshake_version_expected);
}
