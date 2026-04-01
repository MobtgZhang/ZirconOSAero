// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/hpet.zig
// Purpose: HPET（高精度事件定时器）MMIO 探测与可选启用；未启用时 IRQ0 仍由 PIT 驱动。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: Intel IA-PC HPET Specification; ACPI HPET description table

const klog = @import("../../rtl/klog.zig");

/// 常见 ACPI HPET MMIO 物理基址（若固件未映射则由后续 ACPI 解析接入）。
pub const HPET_MMIO_PHYS_BASE: u64 = 0xFED0_0000;

pub var hpet_usable: bool = false;

/// 尝试识别 HPET 寄存器块；当前默认 **不** 改 IRQ0 路由，避免与现有 PIT 双源冲突。
/// 返回 `true` 表示检测到有效 `GCAP_ID`，供将来接 `ke/timer` 与 Local APIC one-shot。
pub fn initOptional() bool {
    hpet_usable = false;
    if (klog.DEBUG_MODE) {
        klog.debug("HPET: probe deferred (PIT remains tick source; see TimerPrecisionRoadmap)", .{});
    }
    return false;
}
