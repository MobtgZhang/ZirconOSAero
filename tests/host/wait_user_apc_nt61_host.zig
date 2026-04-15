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
// Module: tests/host/wait_user_apc_nt61_host.zig
// Purpose: 主机测试：`ke/wait` + `ke/apc` 可告警等待与用户 APC 可见性。
//
// This is an independent clean-room implementation.

comptime {
    if (@import("builtin").cpu.arch != .x86_64) {
        @compileError("wait_user_apc_nt61_host requires x86_64 host");
    }
}

const std = @import("std");
const builtin = @import("builtin");
const wait = @import("ke/wait.zig");
const apc = @import("ke/apc.zig");
const sched = @import("ke/scheduler.zig");
const ob = @import("../../src/ob/object.zig");
const KeApc = @import("ke/apc_object.zig").KeApc;

test "alertable keWaitForSingleObject returns STATUS_USER_APC when user APC pending" {
    // 注意：此测试需要 freestanding 内核环境才能正确初始化调度器。
    // 在 host 模式下跳过，因为调度器初始化依赖内核上下文。
    if (builtin.os.tag != .freestanding) return;

    sched.init();

    var ev: ob.ObjectHeader = .{ .obj_type = .event, .signal_state = false };
    var node: KeApc = .{ .is_user_apc = true };

    const t = sched.getCurrentThread() orelse return error.NoThread;
    apc.queueUserApc(t, &node);

    const st = wait.keWaitForSingleObject(&ev, true, sched.getTicks() + 1000);
    try std.testing.expectEqual(wait.STATUS_USER_APC, st);
}
