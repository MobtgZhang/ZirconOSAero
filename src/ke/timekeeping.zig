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

/// I6 回退链（单调时钟 **非** tick 绝对时间）：
/// 1. **HPET** 主计数器（`hpet.readMainCounterSafe`，频率见 `hpet_counter_hz_approx`）— 漂移上界受固件计数器粒度约束；
/// 2. **PIT/调度 tick**（`scheduler.getTicks` × 隐式 tick 周期，约 10ms 级）— 粗粒度；
/// 3. **TSC** 延后（未接线；见 `TimerPrecisionRoadmap.md`）。
///
/// `KeQueryInterruptTime` 语义子集：由 **PIC/PIT（约 100Hz）** 驱动的调度 tick 计数。
pub fn readInterruptTicks() u64 {
    return scheduler.getTicks();
}

/// 单调原始计数：**优先级**（x86_64）— (1) `hpet.readMainCounterSafe` 非零则 HPET 主计数器；(2) 否则 **PIT/调度 tick** `readInterruptTicks()`。
/// ACPI **HPET 表**（`HPET` 签名项）解析 MMIO 基址并与本常量对齐为路线图 I4；当前以 `hpet.initOptional` MMIO 探测成功为准。
/// 其他架构与 tick 同源直至各 arch Generic Timer 接线。
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

/// 各 arch `initTimer` 末尾可调用（占位日志/断言挂钩）；当前无状态。
pub fn noteArchTimerInitialized() void {}
