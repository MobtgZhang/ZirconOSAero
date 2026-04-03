# 调度器 API 与优先级模型（内核 `ke/scheduler.zig`）

## 目标

- **抢占**：由 PIT IRQ0（约 100Hz）调用 `scheduler.tick()`，在启用调度后于就绪线程间切换。
- **32 级分桶就绪队列**：每逻辑 CPU 32 条 FIFO 链（优先级 0–31），`non_empty` 位图 + 最高优先级选取；同优先级严格 **FIFO**（跨 CPU 同优先级通过 `rr_cpu_cursor` 轮询取头）。
- **与进程管理解耦**：调度器仅管理 `Thread` 与 `ThreadContext`；`process_id` 为弱关联。

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

## 参考

公开文献中的多级队列 / 实时调度概念；算法独立实现，不参考 Windows 调度器源码。
