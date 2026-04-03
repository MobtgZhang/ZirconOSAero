// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/apc_object.zig
// Purpose: `KeApc` 链表节点类型（与 `scheduler.Thread` 解耦，避免 `apc` ↔ `scheduler` 类型环）。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/introduction-to-asynchronous-procedure-calls

/// 异步过程调用队列节点（最小子集：内核例程 + 用户 APC 占位）。
pub const KeApc = struct {
    next: ?*KeApc = null,
    kernel_routine: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    /// `true`：用户 APC（可告警等待路径可见；本阶段不模拟完整返用户交付）。
    is_user_apc: bool = false,
};
