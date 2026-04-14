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
        // P5: TTS (Test-Test-Set) 自旋锁优化：先读取锁状态，减少缓存一致性流量
        // 避免多核竞争时大量 cmpxchg 指令导致的总线乒乓
        while (true) {
            // 先非原子读取，快速判断锁是否可能空闲
            if (self.v.load(.monotonic) == 0) {
                // 只有看起来空闲时才尝试原子交换获取锁
                if (self.v.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
                    break;
                }
            }
            // 锁被占用时，CPU 进入低功耗等待状态，减少资源消耗
            arch.spinCpuRelax();
        }
        self.saved_if = were_enabled;
    }

    /// 尝试获取锁，非阻塞，成功返回 true，失败返回 false
    pub fn tryLock(self: *IrqSpinLock) bool {
        const were_enabled = arch.saveAndDisableInterrupts();
        // 尝试原子获取锁
        if (self.v.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            self.saved_if = were_enabled;
            return true;
        }
        // 获取失败，恢复中断状态
        arch.restoreInterrupts(were_enabled);
        return false;
    }

    pub fn unlock(self: *IrqSpinLock) void {
        const were_enabled = self.saved_if;
        self.v.store(0, .release);
        arch.restoreInterrupts(were_enabled);
    }
};
