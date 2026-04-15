// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/lapic_timer_tick.zig
// Purpose: LAPIC LVT **周期**定时器可选接管内核 tick（`-Dlapic_periodic_tick`）；默认仍为 PIC IRQ0 + PIT。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM Vol.3 — APIC Timer, LVT; mask 8259 IRQ0 后再改 tick 源。

const builtin = @import("builtin");
const build_options = @import("build_options");
const madt = @import("madt.zig");
const lapic_smp = @import("lapic_smp.zig");
const pic = @import("pic.zig");
const kpcr = @import("../../ke/kpcr.zig");

// klog 在 freestanding 模式下需要，用于日志输出
// 在 host 测试模式下使用 no-op 日志
const KlogStub = struct {
    pub const DEBUG_MODE = false;
    pub fn info(comptime _: []const u8, _: anytype) void { _ = KlogStub; }
    pub fn debug(comptime _: []const u8, _: anytype) void { _ = KlogStub; }
};
const klog = if (builtin.os.tag == .freestanding)
    @import("../../rtl/klog.zig")
else
    KlogStub;

/// LVT Timer（Intel SDM Table 10-8）；bit 17 = Periodic。
const REG_LVT_TIMER: u32 = 0x320;
const REG_TIMER_DIV: u32 = 0x3E0;
const REG_TICR: u32 = 0x380;

/// 与 `interrupt_x86` 中 IRQ0 → 向量 **0x30（48）** 一致（PIC 主片 ICW2）。
const timer_vector: u32 = 0x30;

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

    programPeriodicTickRegisters();
    g_lapic_periodic_tick = true;
    klog.info("Timer: LAPIC LVT periodic (vector %u, PIC IRQ0 masked; -Dlapic_periodic_tick)", .{timer_vector});
}

fn programPeriodicTickRegisters() void {
    lapicW(REG_TIMER_DIV, 3);
    lapicW(REG_TICR, 0x20000);
    lapicW(REG_LVT_TIMER, timer_vector | 0x20000);
}

/// J10a：AP 在线后编程本核 LAPIC LVT 周期定时器（与 BSP 相同计数值）；**不**重复 mask 8259（仅 BSP 在 Phase3 执行）。
pub fn attachPeriodicOnApplicationProcessor() void {
    if (!build_options.lapic_periodic_tick) return;
    if (madt.local_apic_mmio_phys == 0) return;
    lapic_smp.ensureLocalApicSoftwareEnabled();
    programPeriodicTickRegisters();
    g_lapic_periodic_tick = true;
    klog.info("Timer: LAPIC LVT periodic on AP cpu_index=%u", .{kpcr.currentProcessorNumber()});
}

/// 仍由 `arch.initTimer` / `ke/timer.init` 调用：使能 SVR；若未开 `lapic_periodic_tick` 则 tick 仍为 PIC+PIT。
pub fn initDeferredSingleTickSource() void {
    lapic_smp.ensureLocalApicSoftwareEnabled();
    if (klog.DEBUG_MODE and !build_options.lapic_periodic_tick) {
        klog.debug("Timer: LAPIC SVR enable; tick source = PIC IRQ0 + PIT (set -Dlapic_periodic_tick for LVT)", .{});
    }
}
