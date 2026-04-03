// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/lapic_timer_tick.zig
// Purpose: LAPIC LVT **周期**定时器可选接管内核 tick（`-Dlapic_periodic_tick`）；默认仍为 PIC IRQ0 + PIT。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM Vol.3 — APIC Timer, LVT; mask 8259 IRQ0 后再改 tick 源。

const klog = @import("../../rtl/klog.zig");
const build_options = @import("build_options");
const madt = @import("madt.zig");
const lapic_smp = @import("lapic_smp.zig");
const pic = @import("pic.zig");

/// LVT Timer（Intel SDM Table 10-8）；bit 17 = Periodic。
const REG_LVT_TIMER: u32 = 0x320;
const REG_TIMER_DIV: u32 = 0x3E0;
const REG_TICR: u32 = 0x380;

/// 与 `interrupt_x86` 中 IRQ0 → 向量 32 一致。
const timer_vector: u32 = 32;

var g_lapic_periodic_tick: bool = false;

pub fn irq0UsesLapicEoi() bool {
    return g_lapic_periodic_tick;
}

fn lapicW(off: u32, val: u32) void {
    const base: usize = @intCast(madt.local_apic_mmio_phys);
    const p: *volatile u32 = @ptrFromInt(base + @as(usize, @intCast(off)));
    p.* = val;
}

/// Phase 3 后调用：MADT 已解析且 LAPIC MMIO 已在恒等映射区内。
pub fn tryAttachPeriodicFromPhase3() void {
    if (!build_options.lapic_periodic_tick) return;
    if (madt.local_apic_mmio_phys == 0) return;

    lapic_smp.ensureLocalApicSoftwareEnabled();

    // 禁止 8259 IRQ0 与 PIT 边沿再触发向量 32（与 OSDev / ACPI 常见迁移顺序一致）。
    pic.maskIrq(0);

    // Divide = 16（TDCR 低 4 位 = 3）；Initial count 为经验值（QEMU 上约数百 Hz 量级，非精确 100Hz）。
    lapicW(REG_TIMER_DIV, 3);
    lapicW(REG_TICR, 0x20000);
    lapicW(REG_LVT_TIMER, timer_vector | 0x20000);

    g_lapic_periodic_tick = true;
    klog.info("Timer: LAPIC LVT periodic (vector %u, PIC IRQ0 masked; -Dlapic_periodic_tick)", .{timer_vector});
}

/// 仍由 `arch.initTimer` / `ke/timer.init` 调用：使能 SVR；若未开 `lapic_periodic_tick` 则 tick 仍为 PIC+PIT。
pub fn initDeferredSingleTickSource() void {
    lapic_smp.ensureLocalApicSoftwareEnabled();
    if (klog.DEBUG_MODE and !build_options.lapic_periodic_tick) {
        klog.debug("Timer: LAPIC SVR enable; tick source = PIC IRQ0 + PIT (set -Dlapic_periodic_tick for LVT)", .{});
    }
}
