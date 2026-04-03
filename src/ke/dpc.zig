// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/dpc.zig
// Purpose: 最小 **DPC** 队列：ISR 仅置位，在 IRQ 出口统一排空（降低 ISR 占用；语义对齐 NT DPC 的「低 IRQL 延后」思想，非完整 KMDF DPC 对象模型）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: WDK — DPC 与 IRQL 的公开行为描述 (learn.microsoft.com)
//
// IRQL 模型（本仓库简化声明，供审计对照 NT 6.1 文档）：
// - ISR 运行在「设备 IRQL」概念层；本实现不在每条路径维护软件 IRQL 寄存器，仅保证 DPC 排空点低于 ISR 重入窗口（见 `interrupt_x86.zig` 出口调用 `dpc.drainPending`）。
// - `drainPending` 等价于在 **DISPATCH_LEVEL 以下** 执行延后工作（输入轮询），与 WDK 所述「DPC 在 DISPATCH_LEVEL 运行」对齐到**调用时机**而非完整 `KIRQL` 状态机。
// - 持有自旋锁期间不得调用会触发调度的例程；当前 `pollAll` 路径须在注释中声明是否满足该约束。
// - **I/O**：异步 IRP 在 `IoMarkIrpPending` 后可在本排空点或工作线程上下文调用 `io.IoCompleteRequest`
//   （WDK：完成例程 IRQL ≤ DISPATCH_LEVEL）；当前仓库仍以同步 `dispatchIrp` 为主，此条为接线契约。
// - **PnP/Power**：`IRP_MJ_PNP` / `IRP_MJ_POWER` 完成路径亦须遵守上述 IRQL 约束（K4.3/K4.4）；见 `src/io/io.zig` 与 [DriverMilestones_NT61.md](../../docs/cn/DriverMilestones_NT61.md)。
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K4.4（完整 IRQL 状态机为长期项）。

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
