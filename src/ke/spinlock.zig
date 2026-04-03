// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/spinlock.zig
// Purpose: 自旋锁 + 保存 IF 后关中断；`unlock` 仅恢复入锁前 IF，避免 ISR 内误 `sti` 导致 IRQ 重入。
// 持锁期间禁止调用 `keWait*`、池分配等可阻塞或可能再次索取同一调度 IRQ 锁的路径（死锁 / IRQL 语义违规）。
//
// This is an independent clean-room implementation.
// Reference: OS textbook irqsave spinlocks; Intel SDM — RFLAGS.IF; ARM DAIF.I; LoongArch CRMD.IE。

const std = @import("std");
const arch = @import("../arch.zig");

pub const IrqSpinLock = struct {
    v: std.atomic.Value(u32) = .init(0),
    /// 仅当前持有者写入；`unlock` 在 `store` 前读取。
    saved_if: bool = false,

    pub fn lock(self: *IrqSpinLock) void {
        const were_enabled = arch.saveAndDisableInterrupts();
        while (self.v.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            arch.spinCpuRelax();
        }
        self.saved_if = were_enabled;
    }

    pub fn unlock(self: *IrqSpinLock) void {
        const were_enabled = self.saved_if;
        self.v.store(0, .release);
        arch.restoreInterrupts(were_enabled);
    }
};
