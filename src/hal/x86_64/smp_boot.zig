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
const lapic_smp = @import("lapic_smp.zig");

/// BSP 侧：多核时 **INIT IPI**，随后在 `0x8000` 安装实模式自旋跳板并 **SIPI×2**（K2.4）；AP 进入长模式与 per-CPU `scheduler.tick` 仍为后续里程碑（见 `ap_entry.zig`）。
pub fn tryStartApplicationProcessorsStub() void {
    const n = madt.logical_cpu_count;
    if (n <= 1) return;
    lapic_smp.broadcastInitAndSipiSequenceExcludingSelf();
    klog.info("SMP: logical_cpus=%u — INIT+SIPI×2 done; trampoline phys=0x%x (real-mode spin); long-mode AP entry deferred (K2.4/K2.6)", .{
        n, lapic_smp.ap_trampoline_page_phys,
    });
}
