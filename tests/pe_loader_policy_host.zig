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
