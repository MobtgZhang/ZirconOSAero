# 计时精度路线图（高于 PIT 100Hz）

## 背景

当前 **PIC + PIT** 约 **100Hz** tick 可满足基础调度过期与桌面心跳；**UI 动画、多媒体定时、更细粒度 `Sleep` 语义** 需要更高分辨率或 **one-shot** 定时源（见内核启动 Phase 2 描述与 [Kernel.md](../en/Kernel.md) 交叉引用）。

## 候选路径（按架构）

| 架构 | 高精度源 | 备注 |
|------|----------|------|
| **x86_64** | **APIC 定时器**（含 TSC-deadline 若可用） | 与现有 I/O APIC / LAPIC 初始化衔接；需文档化 IRQL 与校准。挂钩：`hal/x86_64/lapic_timer_tick.zig`（T3 占位日志）。 |
| **x86_64** | **HPET** | MMIO；与 PIT 并存时的优先级与 `KeQueryInterruptTime` 语义需统一。实现：`hal/x86_64/hpet.zig`（`main.zig` 在绑定内核页表后 `mapDeviceMmioIdentity` + `initOptional`）；**不改 IRQ0**。 |
| **aarch64** | **ARM Generic Timer** | 已在 HAL 方向预留；与 tick 统一为 `ke/timekeeping.zig` + `arch.initTimer`。 |
| **riscv64** | **CLINT / APLIC + rdtime** | 依平台实现；单调读当前回退 tick。 |
| **loongarch64** | **Constant / CPU 定时器 CSR** | 依龙芯公开手册；单调读当前回退 tick。 |

## 里程碑与代码锚点

| # | 内容 | 状态（诚实） |
|---|------|----------------|
| **1** | **抽象**：`ke/timekeeping.zig` — `readInterruptTicks()`（≈ `scheduler.getTicks`）、`readMonotonicRaw()`（x86_64 优先 HPET 主计数器，否则 tick）；`ke/timer.zig` 经 `timekeeping` 读 tick。 | **已接线** |
| **2** | **HPET 探测与频率推算**：GCAP_ID + period(fs) → `hpet_counter_hz_approx`；`isCalibratedForTickMigration()` 为真表示可读主计数器（**仍**未迁 tick）。 | **已接线** |
| **3** | **单一 tick 源**：LAPIC periodic / one-shot 或 TSC-deadline **替换** PIT 前须 mask IRQ0、避免双源风暴。 | **未** — 见 `lapic_timer_tick.zig` |
| **4** | **验证**：100Hz 下调度行为不变；高分辨率引入后补 tick 漂移上界测试。 | 部分（策略单测已有；QEMU 漂移 TBD） |

## 参考（白名单）

- Intel SDM（APIC、TSC）
- ACPI HPET 规范
- ARM DDI 0487（Generic Timer）

## 交叉引用

- 用户态 **`NtDelayExecution` / Sleep** 与 tick 粒度：见 [NT61_VirtualMemory_ABI_Notes.md](NT61_VirtualMemory_ABI_Notes.md) §「延时与 tick」。
