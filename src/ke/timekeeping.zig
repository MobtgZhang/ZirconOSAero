// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/timekeeping.zig
// Purpose: 单调时钟与「中断 tick」读路径抽象；PIT 驱动的 `scheduler.tick` 为默认可见时间轴，HPET 等为可选高分辨率源。
//
// This is an independent clean-room implementation.
// Reference: [docs/cn/TimerPrecisionRoadmap.md](../../docs/cn/TimerPrecisionRoadmap.md)；K2.3：`readMonotonicRaw` 与 `hal/x86_64/hpet.zig` 主计数器接线。

const builtin = @import("builtin");
const scheduler = @import("scheduler.zig");

/// `KeQueryInterruptTime` 语义子集：由 **PIC/PIT（约 100Hz）** 驱动的调度 tick 计数。
pub fn readInterruptTicks() u64 {
    return scheduler.getTicks();
}

/// 单调原始计数：**优先级**（x86_64）— (1) `hpet.readMainCounterSafe` 非零则 HPET 主计数器；(2) 否则 **PIT/调度 tick** `readInterruptTicks()`。
pub fn readMonotonicRaw() u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const hpet = @import("../hal/x86_64/hpet.zig");
            const c = hpet.readMainCounterSafe();
            if (c != 0) return c;
        },
        else => {},
    }
    return readInterruptTicks();
}

/// 自内核启动以来经过的微秒数（单调递增）。
/// x86_64：优先用 HPET 主计数器差值（亚微秒精度）；回退到 PIT tick × 10_000us。
/// 其他架构：回退到 PIT tick × 10_000us（后续逐架构接入高精度源）。
pub fn readBootElapsedUs() u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const hpet = @import("../hal/x86_64/hpet.zig");
            if (hpet.hpet_usable) {
                const hz = hpet.hpet_counter_hz_approx;
                if (hz > 0) {
                    const now = hpet.readMainCounterSafe();
                    if (now != 0) {
                        const delta = now -% hpet.boot_counter_base;
                        return delta / (hz / 1_000_000);
                    }
                }
            }
        },
        else => {},
    }
    return readInterruptTicks() * 10_000;
}

/// 各 arch `initTimer` 末尾可调用（占位日志/断言挂钩）；当前无状态。
pub fn noteArchTimerInitialized() void {}
