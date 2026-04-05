// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Host-only：镜像 `lpc/ipc.zig` 中 **PID→队列下标** 规则，防止跨进程 LPC 误用 0 或越界 PID。
// Ref: docs/cn/LPC_NT61_CALL_CHAIN.md

const std = @import("std");

fn pidToIndex(pid: u32) ?usize {
    const MAX_QUEUES: u32 = 64;
    if (pid == 0 or pid > MAX_QUEUES) return null;
    return pid - 1;
}

test "lpc queue index distinct for two processes" {
    const a = pidToIndex(2).?;
    const b = pidToIndex(3).?;
    try std.testing.expect(a != b);
}

test "lpc queue rejects pid 0 and overflow" {
    try std.testing.expect(pidToIndex(0) == null);
    try std.testing.expect(pidToIndex(65) == null);
}
