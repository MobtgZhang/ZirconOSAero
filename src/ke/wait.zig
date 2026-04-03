// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/wait.zig
// Purpose: 可等待对象上的 `KeWait*` 子集（超时 tick、`alertable` 与用户 APC 可见性）。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/wait-synchronization

const scheduler = @import("scheduler.zig");
const ob = @import("../ob/object.zig");
const apc_mod = @import("apc.zig");

pub const STATUS_WAIT_0: i32 = 0;
pub const STATUS_TIMEOUT: i32 = 258;
/// `STATUS_USER_APC`（0xC0000012）
pub const STATUS_USER_APC: i32 = @bitCast(@as(u32, 0xC0000012));

/// 单对象等待：`deadline_ticks == null` 为无限等待；否则与 `scheduler.getTicks()` 比较。
pub fn keWaitForSingleObject(
    hdr: *ob.ObjectHeader,
    alertable: bool,
    deadline_ticks: ?u64,
) i32 {
    while (true) {
        if (hdr.signal_state) return STATUS_WAIT_0;
        if (alertable and apc_mod.hasPendingUserApcForCurrentThread()) return STATUS_USER_APC;
        if (deadline_ticks) |d| {
            if (scheduler.getTicks() >= d) return STATUS_TIMEOUT;
        }
        scheduler.yield();
    }
}

/// `WaitAny`：任一对象已 signal 则返回 `STATUS_WAIT_0 + i`（`i` 为 `hdrs` 下标）。
pub fn keWaitForMultipleObjectsWaitAny(
    hdrs: []const *ob.ObjectHeader,
    alertable: bool,
    deadline_ticks: ?u64,
) i32 {
    while (true) {
        for (hdrs, 0..) |h, i| {
            if (h.signal_state) return STATUS_WAIT_0 + @as(i32, @intCast(i));
        }
        if (alertable and apc_mod.hasPendingUserApcForCurrentThread()) return STATUS_USER_APC;
        if (deadline_ticks) |d| {
            if (scheduler.getTicks() >= d) return STATUS_TIMEOUT;
        }
        scheduler.yield();
    }
}
