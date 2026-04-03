// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/hpet.zig
// Purpose: HPET（高精度事件定时器）MMIO 探测、主频推算与主计数器只读；**不**改 IRQ0 路由（仍由 PIT）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: Intel IA-PC HPET Specification — GCAP_ID, main counter offset 0xF0
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K2.3

const hpet_id = @import("hpet_id.zig");
const klog = @import("../../rtl/klog.zig");

pub const decodeGcapId = hpet_id.decodeGcapId;

/// 常见 ACPI HPET MMIO 物理基址（若固件未映射则由 `vm.mapDeviceMmioIdentity` 接入）。
pub const HPET_MMIO_PHYS_BASE: u64 = 0xFED0_0000;

/// MMIO 中 Main Counter 寄存器偏移（64 位）。
pub const HPET_MAIN_COUNTER_OFFSET: u64 = 0xF0;

pub var hpet_usable: bool = false;

/// 由 GCAP_ID 高半部推算的计数器频率（Hz）；`period_fs==0` 时按规范假定为 10MHz。
pub var hpet_counter_hz_approx: u64 = 0;

fn readMmioU64(phys_off: u64) u64 {
    // SAFETY: `phys_off` 为 HPET 规范固定偏移；调用前须已 identity 映射 `HPET_MMIO_PHYS_BASE` 所在页（见 `main.zig`）。
    const p = HPET_MMIO_PHYS_BASE + phys_off;
    return @as(*const volatile u64, @ptrFromInt(p)).*;
}

/// 在 `vm.mapDeviceMmioIdentity(HPET_MMIO_PHYS_BASE, …)` 之后调用；**不**启用 legacy 路由、不启动定时器比较器。
pub fn initOptional() bool {
    hpet_usable = false;
    hpet_counter_hz_approx = 0;

    const cap64 = readMmioU64(0);
    const lo: u32 = @truncate(cap64);
    const hi: u32 = @truncate(cap64 >> 32);
    const d = decodeGcapId(lo);

    if (lo == 0 and hi == 0) return false;
    if (lo == 0xffff_ffff and hi == 0xffff_ffff) return false;

    var period_fs: u64 = hi;
    if (period_fs == 0) {
        // 规范：0 表示「遗留」10MHz 时间基准（100ns 周期）。
        period_fs = 100_000_000;
    }
    if (period_fs < 1) return false;

    const hz: u64 = 1_000_000_000_000_000 / period_fs;
    if (hz == 0) return false;

    hpet_counter_hz_approx = hz;
    hpet_usable = true;

    klog.info("HPET: GCAP_ID rev=%u timers_cap=%u period_fs=%u -> ~%u Hz (tick still PIT; see TimerPrecisionRoadmap)", .{
        d.rev_id,
        @as(u32, @intCast(d.num_tim_cap)) +% 1,
        @as(u32, @truncate(period_fs)),
        @as(u32, @truncate(@min(hz, @as(u64, 0xffff_ffff)))),
    });
    return true;
}

/// 主计数器快照；HPET 未标定或映射无效时返回 0。
pub fn readMainCounterSafe() u64 {
    if (!hpet_usable) return 0;
    return readMmioU64(HPET_MAIN_COUNTER_OFFSET);
}

/// K2.3：为真表示已完成 MMIO 探测且推算出非零频率（仍 **未** 将 tick 迁到 HPET）。
pub fn isCalibratedForTickMigration() bool {
    return hpet_usable and hpet_counter_hz_approx > 0;
}
