// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/spinlock.zig
// Purpose: 自旋锁 + 关中断（x86_64 `cli`/`sti`），供调度器与 SMP 演进路径使用。
//
// This is an independent clean-room implementation.
// Reference: OS textbook spinlocks; Intel SDM — interrupt flag.

const std = @import("std");

pub const IrqSpinLock = struct {
    v: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *IrqSpinLock) void {
        asm volatile ("cli" ::: .{ .memory = true });
        while (self.v.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
    }

    pub fn unlock(self: *IrqSpinLock) void {
        self.v.store(0, .release);
        asm volatile ("sti" ::: .{ .memory = true });
    }
};
