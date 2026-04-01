// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/spinlock.zig
// Purpose: 自旋锁 + 关中断（经 `arch.disableInterrupts` / `enableInterrupts`），供调度器与 SMP 演进路径使用。
//
// This is an independent clean-room implementation.
// Reference: OS textbook spinlocks; Intel SDM — IF bit; LoongArch CSR.CRMD.IE（公开手册）。

const std = @import("std");
const arch = @import("../arch.zig");

pub const IrqSpinLock = struct {
    v: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *IrqSpinLock) void {
        arch.disableInterrupts();
        while (self.v.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            arch.spinCpuRelax();
        }
    }

    pub fn unlock(self: *IrqSpinLock) void {
        self.v.store(0, .release);
        arch.enableInterrupts();
    }
};
