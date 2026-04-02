// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/irql.zig
// Purpose: 软件 IRQL 占位（K1.2 / K4.4）；供分页池分配断言与 DPC 文档对照。
//
// This is an independent clean-room implementation.
// Ref: WDK — IRQL 与池类型的公开行为描述 (learn.microsoft.com)

/// PASSIVE_LEVEL（简化：引导与用户态 syscall 路径默认为 0）。
pub const PASSIVE_LEVEL: u8 = 0;
/// DISPATCH_LEVEL（DPC）；完整 APIC TPR/CR8 模型为长期项。
pub const DISPATCH_LEVEL: u8 = 2;

var g_current_irql: u8 = PASSIVE_LEVEL;

pub fn getCurrentIrql() u8 {
    return g_current_irql;
}

/// 单元测试 / 将来 ISR 入口可调用；当前内核主体恒为 PASSIVE。
pub fn setCurrentIrqlForTest(irql: u8) void {
    g_current_irql = irql;
}

pub fn resetIrqlForTest() void {
    g_current_irql = PASSIVE_LEVEL;
}

/// 供 `ex_pool.setPagedPoolIrqlGuard` 注册；`ExAllocatePool(PagedPool)` 在 DISPATCH+ 非法（WDK 公开语义）。
pub fn assertBelowDispatchForPagedPool() void {
    if (getCurrentIrql() >= DISPATCH_LEVEL) {
        @panic("ExAllocatePool: PagedPool at IRQL >= DISPATCH_LEVEL");
    }
}
