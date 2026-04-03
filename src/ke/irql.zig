// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/irql.zig
// Purpose: 软件 IRQL；**每逻辑 CPU 槽位** 存储（与 `scheduler` 的 `MAX_SCHED_CPUS=8` 对齐）；当前运行期默认槽 0（BSP）。
//
// This is an independent clean-room implementation.
// Ref: WDK — IRQL 与池类型的公开行为描述 (learn.microsoft.com)

/// 与 `ke/scheduler.zig` 中 `MAX_SCHED_CPUS` 保持一致（单核近似时仅槽 0 有效）。
pub const MAX_IRQL_CPUS: usize = 8;

/// PASSIVE_LEVEL（简化：引导与用户态 syscall 路径默认为 0）。
pub const PASSIVE_LEVEL: u8 = 0;
/// APC_LEVEL（用户 / 内核 APC 交付与可告警等待的文档分界；软件模拟）。
pub const APC_LEVEL: u8 = 1;
/// DISPATCH_LEVEL（DPC）；完整 APIC TPR/CR8 模型为长期项。
pub const DISPATCH_LEVEL: u8 = 2;
/// 设备 IRQL 占位下界（PIC/IOAPIC 向量层；与真实 3–26 向量未一一对应）。
pub const DEVICE_IRQL_LOW: u8 = 3;

var g_irql_per_cpu: [MAX_IRQL_CPUS]u8 = @splat(PASSIVE_LEVEL);

/// 单元测试可覆盖当前 CPU 槽；`null` 表示使用默认（BSP=0）。AP 长模式入口后应设为 APIC ID 映射槽（里程碑）。
var g_cpu_slot_override: ?usize = null;

fn cpuSlotBounded() usize {
    if (g_cpu_slot_override) |s| return @min(s, MAX_IRQL_CPUS - 1);
    return 0;
}

/// 供 DPC/将来 AP 入口使用。
pub fn currentCpuSlot() usize {
    return cpuSlotBounded();
}

pub fn getCurrentIrql() u8 {
    return g_irql_per_cpu[cpuSlotBounded()];
}

/// 提升软件 IRQL；返回**原** IRQL，须配对 `lowerIrql`。（对照 WDK `KeRaiseIrql`。）
pub fn raiseIrql(new_irql: u8) u8 {
    const slot = cpuSlotBounded();
    const old = g_irql_per_cpu[slot];
    if (new_irql < old) {
        @panic("raiseIrql: new IRQL lower than current");
    }
    g_irql_per_cpu[slot] = new_irql;
    return old;
}

/// 恢复到 `raiseIrql` 返回的旧值。（对照 `KeLowerIrql`。）
pub fn lowerIrql(old_irql: u8) void {
    g_irql_per_cpu[cpuSlotBounded()] = old_irql;
}

/// 仅**降低**到 `new_irql`（ISR 尾从 DIRQL 降到 DISPATCH 以排空 DPC，再 `lowerIrql` 回到入口前）。
pub fn lowerIrqlTo(new_irql: u8) void {
    const slot = cpuSlotBounded();
    if (new_irql > g_irql_per_cpu[slot]) {
        @panic("lowerIrqlTo: new IRQL higher than current");
    }
    g_irql_per_cpu[slot] = new_irql;
}

/// 单元测试 / 将来 AP 入口可调用；`slot=null` 恢复默认 BSP 槽。
pub fn setCpuSlotOverrideForTest(slot: ?usize) void {
    g_cpu_slot_override = slot;
}

/// 单元测试 / 单核近似：所有槽写同一 IRQL。
pub fn setCurrentIrqlForTest(irql: u8) void {
    for (&g_irql_per_cpu) |*s| s.* = irql;
}

pub fn resetIrqlForTest() void {
    @memset(&g_irql_per_cpu, PASSIVE_LEVEL);
    g_cpu_slot_override = null;
}

/// 供 `ex_pool.setPagedPoolIrqlGuard` 注册；`ExAllocatePool(PagedPool)` 在 DISPATCH+ 非法（WDK 公开语义）。
pub fn assertBelowDispatchForPagedPool() void {
    if (getCurrentIrql() >= DISPATCH_LEVEL) {
        @panic("ExAllocatePool: PagedPool at IRQL >= DISPATCH_LEVEL");
    }
}

test "assertBelowDispatchForPagedPool ok at PASSIVE" {
    resetIrqlForTest();
    assertBelowDispatchForPagedPool();
}

test "assertBelowDispatchForPagedPool ok at APC_LEVEL" {
    resetIrqlForTest();
    _ = raiseIrql(APC_LEVEL);
    defer lowerIrql(PASSIVE_LEVEL);
    assertBelowDispatchForPagedPool();
}
