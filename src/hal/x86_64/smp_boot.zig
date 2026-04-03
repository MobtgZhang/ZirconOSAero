// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/smp_boot.zig
// Purpose: AP **INIT-SIPI-SIPI** 与每核调度入口挂钩（K2.4）；当前仅诊断，实路径见 `ap_entry.zig`。
//
// This is an independent clean-room implementation.
// Reference: Intel MP spec / ACPI MADT (behavioral); [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) K2.4, K2.6

const klog = @import("../../rtl/klog.zig");
const madt = @import("madt.zig");

/// BSP 侧占位：多核 QEMU 下仍仅 BSP 进入 `scheduler.tick`；AP 进入 `apKernelEntry` 停机桩前须完成本序列。
pub fn tryStartApplicationProcessorsStub() void {
    const n = madt.logical_cpu_count;
    if (n <= 1) return;
    klog.info("SMP: logical_cpus=%u — AP INIT-SIPI + per-CPU tick deferred (K2.4/K2.6); BSP scheduling only", .{n});
}
