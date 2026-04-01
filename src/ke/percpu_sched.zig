// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/percpu_sched.zig
// Purpose: 每 CPU 运行队列与负载均衡挂钩点（当前固定 BSP=0；SMP 就绪后接 `madt.logical_cpu_count`）。
//
// This is an independent clean-room implementation.
// Reference: OS textbook work stealing (conceptual).

const builtin = @import("builtin");

/// 新线程默认落在的 CPU；多核就绪后改为最低负载队列。
pub fn assignCpuForNewThread() u32 {
    if (builtin.cpu.arch == .x86_64) {
        const madt = @import("../hal/x86_64/madt.zig");
        _ = madt.logical_cpu_count;
    }
    return 0;
}

/// 占位：空闲 CPU 从邻队窃取的就绪线程（与 `scheduler.tick` 协同的后续项）。
pub fn workStealBalanceIfIdle() void {}
