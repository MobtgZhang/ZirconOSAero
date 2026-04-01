// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/percpu_sched.zig
// Purpose: 每 CPU 运行队列与负载均衡挂钩点（当前固定 BSP=0；SMP 就绪后接 `madt.logical_cpu_count`）。
//
// This is an independent clean-room implementation.
// Reference: OS textbook work stealing (conceptual).

const builtin = @import("builtin");

var assign_cpu_rot: u32 = 0;

/// 新线程默认落在的 CPU；SMP 就绪后按 `madt.logical_cpu_count` 轮询占位（AP 队列就绪后换最短队列策略）。
pub fn assignCpuForNewThread() u32 {
    if (builtin.cpu.arch == .x86_64) {
        const madt = @import("../hal/x86_64/madt.zig");
        const n = madt.logical_cpu_count;
        if (n <= 1) return 0;
        const c = assign_cpu_rot;
        assign_cpu_rot +%= 1;
        return c % n;
    }
    return 0;
}

/// 占位：空闲 CPU 从邻队窃取就绪线程；依赖 `scheduler` 导出 per-CPU 队列后实现。
pub fn workStealBalanceIfIdle() void {}
