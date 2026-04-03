// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/apc.zig
// Purpose: 内核 / 用户 APC 队列最小实现；与 `ke/wait.zig` 的 `alertable` 及 syscall 返回路径交付内核 APC 配合。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/introduction-to-asynchronous-procedure-calls

const scheduler = @import("scheduler.zig");
const irql = @import("irql.zig");
const KeApc = @import("apc_object.zig").KeApc;

pub const KeApcNode = KeApc;

pub fn init() void {}

/// 头插内核 APC（DISPATCH_LEVEL 以下由 `deliverKernelApcsForCurrentThread` 排空）。
pub fn queueKernelApc(thread: *scheduler.Thread, apc: *KeApc) void {
    apc.is_user_apc = false;
    apc.next = thread.kernel_apc_head;
    thread.kernel_apc_head = apc;
}

/// 头插用户 APC（`alertable` 等待可见；完整用户态例程交付为后续里程碑）。
pub fn queueUserApc(thread: *scheduler.Thread, apc: *KeApc) void {
    apc.is_user_apc = true;
    apc.next = thread.user_apc_head;
    thread.user_apc_head = apc;
}

pub fn hasPendingUserApcForCurrentThread() bool {
    const t = scheduler.getCurrentThread() orelse return false;
    return t.user_apc_head != null;
}

/// 在 **PASSIVE_LEVEL** 排空当前线程内核 APC（syscall 返用户前；与 DISPATCH 路径分离）。
pub fn deliverKernelApcsForCurrentThread() void {
    if (irql.getCurrentIrql() != irql.PASSIVE_LEVEL) return;
    const t = scheduler.getCurrentThread() orelse return;
    while (t.kernel_apc_head) |a| {
        t.kernel_apc_head = a.next;
        a.next = null;
        if (a.kernel_routine) |f| f(a.ctx);
    }
}
