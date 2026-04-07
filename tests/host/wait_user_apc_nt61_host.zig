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
const wait = @import("ke/wait.zig");
const apc = @import("ke/apc.zig");
const sched = @import("ke/scheduler.zig");
const ob = @import("ob/object.zig");
const KeApc = @import("ke/apc_object.zig").KeApc;

test "alertable keWaitForSingleObject returns STATUS_USER_APC when user APC pending" {
    sched.init();

    var ev: ob.ObjectHeader = .{ .obj_type = .event, .signal_state = false };
    var node: KeApc = .{ .is_user_apc = true };

    const t = sched.getCurrentThread() orelse return error.NoThread;
    apc.queueUserApc(t, &node);

    const st = wait.keWaitForSingleObject(&ev, true, sched.getTicks() + 1000);
    try std.testing.expectEqual(wait.STATUS_USER_APC, st);
}
