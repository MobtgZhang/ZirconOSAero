// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/ap_entry.zig
// Purpose: AP（应用处理器）入口占位与 INIT-SIPI-SIPI 跳板挂钩点（低 1MB 实模式代码为后续里程碑）。
//
// This is an independent clean-room implementation.
// Reference: Intel MP spec / ACPI MADT startup sequence (behavioral only).
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K2.4（INIT-SIPI-SIPI 与每核入口）。

const klog = @import("../../rtl/klog.zig");

/// BSP 在唤醒 AP 后跳转的 C 约定入口（当前为停机占位）。
///
/// **K2.4 后续接线（Intel SDM Vol.3 / ACPI MADT 行为描述，clean-room）**：
/// 1. BSP 在实模式/复位向量附近放置 4KiB 以内跳板（`startup_ipi` 目标物理页），含 `lgdt`/`ljmp` 入长模式。
/// 2. 写 `LAPIC_ICR`：Delivery Mode INIT → 目标 AP；再 SIPI 两次（10ms 级间隔），`Vector` 指向跳板页号。
/// 3. 每 AP 设置 `IA32_KERNEL_GS_BASE`、加载 `TSS.RSP0`、使能 `APIC` 软件启用位后进入 `scheduler` per-CPU 空闲。
/// 4. TLB 与 IPI：`tlb_broadcast.zig` 扩展为真正的 shootdown 向量。
///
/// TLB 一致性见 `tlb_broadcast.zig`。
pub export fn apKernelEntry(cpu_index: u32) callconv(.c) noreturn {
    klog.info("SMP: AP cpu_index=%u entered (stub idle)", .{cpu_index});
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
