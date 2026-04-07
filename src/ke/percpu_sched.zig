// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/percpu_sched.zig
// Purpose: 每 CPU 运行队列与负载均衡挂钩点（当前固定 BSP=0；SMP 就绪后接 `madt.logical_cpu_count`）。
//
// This is an independent clean-room implementation.
// Reference: OS textbook work stealing (conceptual).
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K2.6（`home_cpu`、AP 就绪队列）。

const builtin = @import("builtin");

var assign_cpu_rot: u32 = 0;

/// 空闲线程等仍可用本函数；**普通就绪线程** 的 `home_cpu` 由 `scheduler.zig` 内 `pickBalancedHomeCpu()` 按各 CPU 就绪深度选取（K2.6）。
/// 与 `scheduler.setThreadAffinityMask` / `Thread.home_cpu` 配合；窃取路径见 `scheduler.zig` `workStealBalanceIfIdleImpl`。
pub fn assignCpuForNewThread() u32 {
    if (builtin.cpu.arch == .x86_64) {
        const madt = @import("../hal/x86_64/madt.zig");
        const n = madt.logical_cpu_count;
        if (n <= 1) return 0;
        const c = assign_cpu_rot;
        assign_cpu_rot +%= 1;
        return c % n;
    }
    if (builtin.cpu.arch == .loongarch64) {
        const topo = @import("../hal/loongarch64/cpu_topology.zig");
        const n = topo.logicalCpuCount();
        if (n <= 1) return 0;
        const c = assign_cpu_rot;
        assign_cpu_rot +%= 1;
        return c % n;
    }
    if (builtin.cpu.arch == .riscv64) {
        const topo = @import("../hal/riscv64/cpu_topology.zig");
        const n = topo.logicalCpuCount();
        if (n <= 1) return 0;
        const c = assign_cpu_rot;
        assign_cpu_rot +%= 1;
        return c % n;
    }
    if (builtin.cpu.arch == .aarch64) {
        const topo = @import("../hal/aarch64/cpu_topology.zig");
        const n = topo.logicalCpuCount();
        if (n <= 1) return 0;
        const c = assign_cpu_rot;
        assign_cpu_rot +%= 1;
        return c % n;
    }
    if (builtin.cpu.arch == .mips64el) {
        const topo = @import("../hal/mips64el/cpu_topology.zig");
        const n = topo.logicalCpuCount();
        if (n <= 1) return 0;
        const c = assign_cpu_rot;
        assign_cpu_rot +%= 1;
        return c % n;
    }
    return 0;
}

/// 工作窃取已并入 `ke/scheduler.zig` 的 `tick`（`workStealBalanceIfIdleImpl`）；保留空符号避免旧调用点破坏链接。
pub fn workStealBalanceIfIdle() void {}
