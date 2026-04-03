# 调度器 API 与优先级模型（内核 `ke/scheduler.zig`）

## 目标

- **抢占**：由 PIT IRQ0（约 100Hz）调用 `scheduler.tick()`，在启用调度后于就绪线程间切换。
- **32 级分桶就绪队列**：每逻辑 CPU 32 条 FIFO 链（优先级 0–31），`non_empty` 位图 + 最高优先级选取；同优先级严格 **FIFO**（跨 CPU 同优先级通过 `rr_cpu_cursor` 轮询取头）。
- **与进程管理解耦**：调度器仅管理 `Thread` 与 `ThreadContext`；`process_id` 为弱关联。

## 阶段 C 完成定义（调度 / 同步子集）

**本阶段交付**

- `ob.ObjectHeader` 上 **FIFO 等待队列**（`WaitEntry`）与 `ke/wait.zig`：`KeWaitForSingleObject` / `KeWaitForMultipleObjects`（**WaitAny**，≤64）在 `enableScheduling` 之后经 `blockThread` 阻塞，**不再**就未满足条件忙等 `yield`。
- `tick()`：若 **当前线程已 `.blocked`**，强制从全局最高优先级就绪队列 **摘出下一线程** 运行（避免单核上等待路径饿死）。
- `tick()` 内 **`processBlockedObjectWaitsLocked`**：对 `in_object_wait` 线程检查 **tick 截止**（与 `scheduler.tickCountLocked()` / `getTicks()` 同源）及 **`wait_alertable` + 用户 APC 队列非空**，完成等待并投递 `STATUS_TIMEOUT` / `STATUS_USER_APC`。
- **事件**：`NtCreateEvent` 按 `NotificationEvent` / `SynchronizationEvent` 设置 `OBJ_FLAG_EVENT_AUTO_RESET`；`NtSetEvent` 后 `wait.onEventSet` — 手动复位 **广播** 唤醒，自动复位 **唤醒一名** 后清除 `signal_state`（无等待者时保持已信号）。
- **进程销毁**：`terminateThreadsForProcess` 在置 `terminated` 前 **`detachThreadFromWaitQueues`**。
- **调度未启用**（引导早期）：`keWait*` 回退为协作式 `yield` 轮询（与旧行为一致）。

**明确不做（短期）**

- 完整 **设备 IRQL 3–26** / CR8 模型、NUMA 公平份额、**WaitAll**（`NtWaitForMultipleObjects` 非零 `wait_type` 仍为 `STATUS_NOT_IMPLEMENTED`）。
- **用户 APC 例程** 在用户态的实际执行仍为后续里程碑；当前为「可告警等待返回 `STATUS_USER_APC`」可见性。
- **互斥 / 信号量** 的 ntdll 句柄池与 `ObjectHeader.signal_state` 全路径对齐（`NtCreateMutant` / `NtReleaseSemaphore` 等仍为桩或部分桩）— 见契约矩阵与 `README_cn` 同步行。

## 对象等待与 `sched_irq_lock`

- `scheduler.lockSchedIrq` / `unlockSchedIrq` 包装 `IrqSpinLock`，与 `tick`、`enqueueReady`、`blockThread` 同锁。
- `keWait*`：**持锁** 完成入队与 `blockThread`，**解锁后** `yield()`，以便定时器 IRQ 进入 `tick` 并切换。
- **超时语义**：`ntdll` 将相对 `timeout`（100ns）粗换算为 **tick 增量**；非单调时钟的绝对超时仍按无限等待处理（与先前注释一致）。时钟源主刻度见下节。

## 时钟源与 TLB（交叉引用）

- **主调度 tick**：`ke/timer.zig`（PIC + PIT ~100Hz）；可选 **LAPIC 周期 tick** 见 `hal/x86_64/lapic_timer_tick.zig` 与 [TimerPrecisionRoadmap.md](TimerPrecisionRoadmap.md)。
- **SMP TLB**：`hal/x86_64/tlb_broadcast.zig` — 默认 BSP `flushLocal`；**`-Dsmp_tlb_ipi=true`** 且多核时广播专用 IDT 向量；`unmap` / 进程地址空间释放路径须与 K2.5 文档一致，避免 AP 参与用户映射后仅 BSP 刷新。

## IRQL、DPC、APC 与 syscall 返回（阶段 C 审计摘要）

- **IRQL**：子集为 `PASSIVE_LEVEL` / `APC_LEVEL` / `DISPATCH_LEVEL`（`ke/irql.zig`）。x86_64 **设备 IRQ** 路径在 `interrupt_x86.handleIrq` 内先抬升再 `scheduler.tick()`，尾声降至 `DISPATCH_LEVEL` 并 **`dpc.drainAtDispatchLevel`**（每 CPU FIFO）。
- **内核 APC**：`ke/apc.zig` — `deliverKernelApcsForCurrentThread` 仅在 **PASSIVE_LEVEL** 排空；**`arch/x86_64/syscall.zig` 的 `dispatch`** 在写回 `rax` 后统一调用**，与 `int 0x80` / `syscall` 共用同一出口（均经 `handleSyscall` → `dispatch`）。
- **用户 APC**：`alertable` 等待在 `tick` 中与 **`Thread.user_apc_head`** 联动返回 `STATUS_USER_APC`；用户态例程调用链仍为后续工作。
- **自旋锁**：`ke/spinlock.zig` — 持 `IrqSpinLock` 期间不得调用 `keWait*` 等可阻塞路径（注释已标明）。

## 常量与刻度

| 符号 | 说明 |
|------|------|
| `PRIORITY_IDLE` / `PRIORITY_NORMAL` / `PRIORITY_REALTIME` | 常用档占位（1 / 8 / 24） |
| `PRIORITY_DYNAMIC_MAX` (=15) | **动态**区间上界：仅当 `priority <= 15` 时参与防饥饿 `STARVATION_BOOST`；**实时**档（>15）不通过该路径被动态线程「抬走」 |
| `PRIORITY_CLASS_COUNT` | 8 档 `priority_class`，影响时间片长度 |
| `QUANTUM_BY_CLASS` | clean-room 量子表 `{4,5,6,7,8,10,12,14}` tick；见 `quantumTicksForClass` |
| `TIME_SLICE_TICKS` | 兼容旧符号；实际量子为 `quantumTicksForThread` |

### 八档映射（`priorityFromClass`）

`effective 基线 = 2 + class * 3`（class ∈ 0..7），裁剪到 **31**。`effectivePriority` = `min(31, priority + io_boost)` 与 `mutex_inherit_floor` 取 max，再对动态线程施加饥饿提升。

### 防饥饿（clean-room）

就绪线程（非当前运行）每 tick 累加 `starve_ticks`；超过 `STARVATION_TICK_THRESHOLD` 后 **仅当** `priority <= PRIORITY_DYNAMIC_MAX` 时在有效优先级上 `+STARVATION_BOOST`（上限 31）。

### 互斥体优先级继承（最小子集）

- `ke/sync.zig`：`Mutex.acquireWithInheritance` / `release` 与 `scheduler.beginMutexInheritance`、`updateMutexInheritFloor`、`endMutexInheritance` 配对；每条 mutex 等待边在**首次**阻塞时 `begin` 一次，后续自旋仅 `update`；持有者**最外层** `release` 时 `end` 一次。
- **多锁**：`Thread.mutex_inherit_depth` 计数并行等待边；仅当深度归零时清零 `mutex_inherit_floor`（深度仍大于 0 时 floor 可能**暂高于**剩余等待者真实需求，属可接受保守抬升）。
- **验证**：`zig build test` → **mutex_inherit_depth_host**（深度模型主机对照）。

### 处理器亲和

- `Thread.affinity_mask`：位 i = 可运行于逻辑 CPU i；**0** 表示「当前构建可见的全部逻辑 CPU」（受 `MAX_SCHED_CPUS` 截断）。
- `setThreadAffinityMask` / `home_cpu`：`createThread` 使用 `pickBalancedHomeCpu()`（最短就绪队列）；`createIdleThread` 仍用 `percpu_sched.assignCpuForNewThread()`。

## I/O 唤醒提升（clean-room）

- `unblockThread`：`io_boost` 在 `IO_BOOST_DURATION_TICKS` 内增加 `IO_BOOST_PRIORITY_DELTA`。
- 到期由 `tick()` 清零。

## 与 NT 6.1 / Windows 内核的差异

| 能力 | NT / 公开文档侧 | 本仓库 |
|------|-----------------|--------|
| 就绪组织 | 多级反馈 + 动态调整 | 32 分桶 FIFO + 显式 boost/饥饿/继承钩子 |
| NUMA / 公平份额 | 有 | **Explicitly out of scope（短期）** — 不在本里程碑假装「完整调度器」；见契约矩阵 §0 |
| IRQL / 抢占边界 | 严格（DISPATCH_LEVEL 等） | **子集**：`ke/irql.zig` 提供 PASSIVE / APC / DISPATCH 与 raise/lower；x86 IRQ 出口提升至 DISPATCH 后 `dpc.drainAtDispatchLevel`；**无** 完整 CR8/设备 IRQL 3–26 模型 |
| 前台量子 / GUI boost | 前台略长量子、输入路径提升 | `Process.is_foreground`、`quantumTicksForThread` 略增；`noteGuiInputBoostStub` 占位（可接消息泵/input 完成） |

## 公开入口

- `init` / `enableScheduling` / `tick` / `yield`
- `createThread` / `blockThread` / `unblockThread` / `terminateThread`
- `setThreadPriority` / `setThreadPriorityClass` / `setThreadAffinityMask`
- `beginMutexInheritance` / `updateMutexInheritFloor` / `endMutexInheritance`（由 `Mutex` 调用）；`clearMutexInheritFloor` 为强制复位（调试）
- `getCurrentThread` / `getTicks` / `effectivePriorityForThread`

## 测试

主机策略公式回归：`zig build test` → **scheduler_policy_host**（与 `scheduler.zig` 数值策略保持同步）。

对象等待链（FIFO / 幂等摘除）：`zig build test` → **object**（`src/zircon_host_ob_test.zig`「ObjectHeader wait list …」）。

互斥继承深度：`mutex_inherit_depth_host`。可告警等待与用户 APC 可见性：`wait_user_apc_nt61_host`。

## 参考

公开文献中的多级队列 / 实时调度概念；算法独立实现，不参考 Windows 调度器源码。
