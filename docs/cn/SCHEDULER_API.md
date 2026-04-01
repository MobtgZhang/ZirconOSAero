# 调度器 API 与优先级模型（内核 `ke/scheduler.zig`）

## 目标

- **抢占**：由 PIT IRQ0（约 100Hz）调用 `scheduler.tick()`，在启用调度后于就绪线程间切换。
- **多级优先级**：数值 **越大越优先**；高优先级就绪时优先获得运行权。
- **与进程管理解耦**：调度器仅管理 `Thread` 记录与 `ThreadContext`；`process_id` 为弱关联，供上层统计与 `#PF` 处理。

## 当前常量

| 符号 | 值 | 说明 |
|------|-----|------|
| `PRIORITY_IDLE` | 4 | 空闲线程默认档 |
| `PRIORITY_NORMAL` | 8 | `createThread` 默认档 |
| `PRIORITY_REALTIME` | 16 | 高优先级占位（可与设备线程绑定） |
| `PRIORITY_CLASS_COUNT` | 8 | 可映射到 NT 风格 0–7 档的 **文档阶梯**（见下） |

### 八档映射（建议）

将 NT 的「优先级类」概念压缩为 8 档时，可使用：

`effective = 4 + class * 2`（class ∈ 0..7）→ 4,6,8,10,12,14,16,18；再裁剪到实现允许的最大值。

与真实 NT 32 级优先级 **不对齐**，仅为本内核可演进阶梯。

## 时间片

- `TIME_SLICE_TICKS`：在 **同等有效优先级**（见下）的就绪线程之间，当前运行线程的剩余 tick；耗尽后才在同优先级的线程间轮转。
- `1` 与历史行为接近：每 tick 可发生同优先级切换。

## I/O 唤醒提升（clean-room）

- `unblockThread` 时：在 `IO_BOOST_DURATION_TICKS` 内将 `io_boost` 增加 `IO_BOOST_PRIORITY_DELTA`（不超过 `255 - priority`），使 `effectivePriority = priority + io_boost`。
- 到期后 `tick()` 将 `io_boost` 清零。这是教科书式「阻塞结束短暂抬高优先级」的极简模型，**不是** Windows NT 调度器的精确复现。

## 与 NT 6.1 / Windows 内核的差异（明确非目标或未完成）

| 能力 | NT / 公开文档侧 | 本仓库 |
|------|-----------------|--------|
| 优先级级数 | 32 级 + 优先级类 | 8 档映射到约 4–18 的 u8 阶梯 |
| 优先级提升 | I/O、前台、饥饿等多源规则 | 仅 `unblockThread` 固定增量 + 定时衰减 |
| NUMA / 处理器亲和 | 存在 | 未实现 |
| 实时带宽 / 公平份额 | 存在 | 未实现 |
| 内核模式抢占边界 | IRQL / 锁协议 | 简化模型 |

## 公开入口

- `init` / `enableScheduling` / `tick` / `yield`
- `createThread` / `blockThread` / `unblockThread` / `terminateThread`
- `setThreadPriority` / `getCurrentThread` / `getTicks`

## 参考

公开文献中的多级反馈队列 / 实时调度概念；算法独立实现，不参考 Windows 调度器源码。
