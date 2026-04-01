// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/dpc.zig
// Purpose: 最小 **DPC** 队列：ISR 仅置位，在 IRQ 出口统一排空（降低 ISR 占用；语义对齐 NT DPC 的「低 IRQL 延后」思想，非完整 KMDF DPC 对象模型）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: WDK — DPC 与 IRQL 的公开行为描述 (learn.microsoft.com)

const builtin = @import("builtin");

var input_flush_pending: bool = false;

/// 由鼠标/键盘等 ISR 路径调用：将 `input_hub.pollAll` 延后到 `drainPending`。
pub fn requestInputFlushDeferred() void {
    input_flush_pending = true;
}

pub fn drainPending() void {
    if (!input_flush_pending) return;
    input_flush_pending = false;
    if (builtin.target.cpu.arch == .x86_64) {
        @import("../drivers/input/input_hub.zig").pollAll();
    }
}
