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
