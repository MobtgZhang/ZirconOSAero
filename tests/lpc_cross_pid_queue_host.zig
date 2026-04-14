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
