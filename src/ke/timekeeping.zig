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
// Module: src/ke/timekeeping.zig
// Purpose: 单调时钟与「中断 tick」读路径抽象；PIT 驱动的 `scheduler.tick` 为默认可见时间轴，HPET 等为可选高分辨率源。
//
// This is an independent clean-room implementation.
// Reference: [docs/cn/TimerPrecisionRoadmap.md](../../docs/cn/TimerPrecisionRoadmap.md)；K2.3：`readMonotonicRaw` 与 HAL 高分辨率计数器接线。

const scheduler = @import("scheduler.zig");

/// `KeQueryInterruptTime` 语义子集：由 **PIC/PIT（约 100Hz）** 驱动的调度 tick 计数。
pub fn readInterruptTicks() u64 {
    return scheduler.getTicks();
}

/// 单调原始计数：**优先级** — (1) HAL 高分辨率计数器非零时使用；(2) 否则 **调度 tick** `readInterruptTicks()`。
pub fn readMonotonicRaw() u64 {
    if (@import("../hal.zig").readHighResolutionMonotonic()) |counter| {
        return counter;
    }
    return readInterruptTicks();
}

/// 自内核启动以来经过的微秒数（单调递增）。
/// 优先用 HAL 高分辨率计数器差值（亚微秒精度）；回退到调度 tick。
/// 其他架构：回退到 PIT tick × 10_000us（后续逐架构接入高精度源）。
pub fn readBootElapsedUs() u64 {
    if (@import("../hal.zig").readHighResolutionBootElapsedUs()) |micros| {
        return micros;
    }
    return readInterruptTicks() * 10_000;
}

/// 各 arch `initTimer` 末尾可调用（占位日志/断言挂钩）；当前无状态。
pub fn noteArchTimerInitialized() void {}
