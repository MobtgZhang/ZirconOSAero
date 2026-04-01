// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/ap_entry.zig
// Purpose: AP（应用处理器）入口占位与 INIT-SIPI-SIPI 跳板挂钩点（低 1MB 实模式代码为后续里程碑）。
//
// This is an independent clean-room implementation.
// Reference: Intel MP spec / ACPI MADT startup sequence (behavioral only).

const klog = @import("../../rtl/klog.zig");

/// BSP 在唤醒 AP 后跳转的 C 约定入口（当前为停机占位）。
/// 后续：在此核上初始化 `IA32_KERNEL_GS_BASE`、进入 `scheduler` 每 CPU 空闲循环前须完成 TLB/ICR 握手（见 `tlb_broadcast.zig`）。
pub export fn apKernelEntry(cpu_index: u32) callconv(.c) noreturn {
    klog.info("SMP: AP cpu_index=%u entered (stub idle)", .{cpu_index});
    while (true) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}
