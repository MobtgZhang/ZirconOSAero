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

/// 单调原始计数：x86_64 在 HPET 已标定时为主计数器快照；否则回退为 `readInterruptTicks()`。
/// 其他架构当前与 tick 同源（Generic Timer 等接 T4 后在此分派）。
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
