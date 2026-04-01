# 计时精度路线图（高于 PIT 100Hz）

## 背景

当前 **PIC + PIT** 约 **100Hz** tick 可满足基础调度过期与桌面心跳；**UI 动画、多媒体定时、更细粒度 `Sleep` 语义** 需要更高分辨率或 **one-shot** 定时源（见内核启动 Phase 2 描述与 [Kernel.md](../en/Kernel.md) 交叉引用）。

## 候选路径（按架构）

| 架构 | 高精度源 | 备注 |
|------|----------|------|
| **x86_64** | **APIC 定时器**（含 TSC-deadline 若可用） | 与现有 I/O APIC / LAPIC 初始化衔接；需文档化 IRQL 与校准。 |
| **x86_64** | **HPET** | MMIO；与 PIT 并存时的优先级与 `KeQueryInterruptTime` 语义需统一。 |
| **aarch64** | **ARM Generic Timer** | 已在 HAL 方向预留；与 tick 统一为 `arch` 分派。 |
| **riscv64** | **CLINT / APLIC + rdtime** | 依平台实现。 |
| **loongarch64** | **Constant / CPU 定时器 CSR** | 依龙芯公开手册。 |

## 里程碑建议

1. **抽象**：在 `ke/` 或 `hal/` 增加 **单调时钟 + 可选 high_res tick** 接口，PIT 仍为 fallback。
2. **验证**：调度器在 100Hz 下行为不变；引入高分辨率后补 **单元 / QEMU** 测试（tick 漂移上界）。
3. **文档**：更新 [SyscallABI.md](SyscallABI.md) 无关，但 **PROCESS_NT61.md** 与 **Kernel.md** 中「定时子系统」小节应指向本文。

## 参考（白名单）

- Intel SDM（APIC、TSC）
- ACPI HPET 规范
- ARM DDI 0487（Generic Timer）
