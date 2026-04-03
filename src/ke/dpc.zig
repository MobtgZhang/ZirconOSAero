// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/dpc.zig
// Purpose: **每逻辑 CPU FIFO DPC** 队列 + IRQ 出口在 **DISPATCH_LEVEL** 排空；槽数与 `irql.MAX_IRQL_CPUS` 一致。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: WDK — DPC 与 IRQL 的公开行为描述 (learn.microsoft.com)
//
// IRQL 模型（本仓库简化声明，供审计对照 NT 6.1 文档）：
// - ISR 运行在「设备 IRQL」概念层；本实现不在每条路径维护软件 IRQL 寄存器，仅保证 DPC 排空点低于 ISR 重入窗口（见 `interrupt_x86.zig` 出口调用 `drainAtDispatchLevel`）。
// - `drainAtDispatchLevel` 仅在 **IRQL ≥ DISPATCH_LEVEL** 时执行队列；与 WDK 所述「DPC 在 DISPATCH_LEVEL 运行」对齐到**调用时机**。
// - 持有自旋锁期间不得调用会触发调度的例程；当前 `pollAll` 路径须在注释中声明是否满足该约束。
// - **I/O**：异步 IRP 在 `IoMarkIrpPending` 后可在本排空点或工作线程上下文调用 `io.IoCompleteRequest`
//   （WDK：完成例程 IRQL ≤ DISPATCH_LEVEL）；当前仓库仍以同步 `dispatchIrp` 为主，此条为接线契约。
// - **PnP/Power**：`IRP_MJ_PNP` / `IRP_MJ_POWER` 完成路径亦须遵守上述 IRQL 约束（K4.3/K4.4）；见 `src/io/io.zig` 与 [DriverMilestones_NT61.md](../../docs/cn/DriverMilestones_NT61.md)。
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K4.4（完整 IRQL 状态机为长期项）。

const builtin = @import("builtin");
const irql_mod = @import("irql.zig");

const dpc_fifo_cap: usize = 128;

const DpcSlot = struct {
    func: *const fn (?*anyopaque) void,
    ctx: ?*anyopaque,
};

const DpcFifo = struct {
    fifo: [dpc_fifo_cap]DpcSlot = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
};

var dpc_state: [irql_mod.MAX_IRQL_CPUS]DpcFifo = [_]DpcFifo{.{}} ** irql_mod.MAX_IRQL_CPUS;

/// 由鼠标/键盘等 ISR 路径调用：以 DPC 延后 `input_hub.pollAll`。
var input_flush_pending: [irql_mod.MAX_IRQL_CPUS]bool = @splat(false);

fn runInputFlushDpc(ctx: ?*anyopaque) void {
    _ = ctx;
    if (builtin.target.cpu.arch == .x86_64) {
        @import("../drivers/input/input_hub.zig").pollAll();
    }
}

/// 由鼠标/键盘等 ISR 路径调用：以 DPC 延后 `input_hub.pollAll`。
pub fn requestInputFlushDeferred() void {
    const slot = irql_mod.currentCpuSlot();
    if (!queueDpc(runInputFlushDpc, null)) {
        input_flush_pending[slot] = true;
    }
}

/// 排队通用 DPC；队列满时返回 `false`（调用方可降级为置位 `input_flush_pending` 等）。
pub fn queueDpc(func: *const fn (?*anyopaque) void, ctx: ?*anyopaque) bool {
    const slot = irql_mod.currentCpuSlot();
    const q = &dpc_state[slot];
    if (q.count >= dpc_fifo_cap) return false;
    q.fifo[q.tail] = .{ .func = func, .ctx = ctx };
    q.tail = (q.tail + 1) % dpc_fifo_cap;
    q.count += 1;
    return true;
}

/// 在 **DISPATCH_LEVEL 及以上** 排空 **当前 CPU 槽** 的 FIFO DPC；否则立即返回（防误用）。
pub fn drainAtDispatchLevel() void {
    if (irql_mod.getCurrentIrql() < irql_mod.DISPATCH_LEVEL) return;
    const slot = irql_mod.currentCpuSlot();
    const q = &dpc_state[slot];
    while (q.count > 0) {
        const s = q.fifo[q.head];
        q.head = (q.head + 1) % dpc_fifo_cap;
        q.count -= 1;
        s.func(s.ctx);
    }
    if (input_flush_pending[slot]) {
        input_flush_pending[slot] = false;
        if (builtin.target.cpu.arch == .x86_64) {
            @import("../drivers/input/input_hub.zig").pollAll();
        }
    }
}

/// 兼容旧名：IRQ 出口在抬升到 DISPATCH 后调用 `drainAtDispatchLevel`。
pub fn drainPending() void {
    drainAtDispatchLevel();
}
