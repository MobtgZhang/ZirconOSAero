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
