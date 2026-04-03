// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/lapic_timer_tick.zig
// Purpose: LAPIC 定时器 / TSC-deadline 单一 tick 源迁移挂钩（T3）；当前仍由 PIC IRQ0 + PIT 驱动。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM Vol.3 — APIC Timer; [docs/cn/TimerPrecisionRoadmap.md](../../../docs/cn/TimerPrecisionRoadmap.md)

const klog = @import("../../rtl/klog.zig");

/// T3：在 LAPIC 已软件使能后，可改接 **per-CPU** periodic / one-shot；与 PIT **二选一** 前须 mask IRQ0 并文档化顺序。
pub fn initDeferredSingleTickSource() void {
    if (klog.DEBUG_MODE) {
        klog.debug("Timer: single tick source = PIC IRQ0 + PIT (LAPIC one-shot migration deferred, T3)", .{});
    }
}
