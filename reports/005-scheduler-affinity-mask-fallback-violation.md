# 问题 #5：调度器将无交集亲和掩码回退到 CPU 0

## 1. 问题编号

`5`

## 2. 问题位置

- 文件路径：`src/ke/scheduler.zig`
- 函数/模块：`pickHomeCpuForAffinity()`、`enqueueReadyLocked()`、`setThreadAffinityMask()`、`affinityCpuMask()`
- 行号或代码片段：`pickHomeCpuForAffinity()` 在 `[0, schedNumCpus())` 内未找到置位比特时返回 `0`；`enqueueReadyLocked()` 随后按该结果把线程放入 CPU 槽 0。

## 3. 问题描述

当线程亲和掩码不包含任何当前参与调度的 CPU 时，调度器没有拒绝或跳过该线程，而是回退到 CPU 0。这样会调度到亲和掩码明确不允许的 CPU 上，破坏线程亲和性约束。

## 4. 复现路径

将某个线程的亲和掩码设置为仅包含当前调度 CPU 数量之外的比特，例如在调度器只支持 CPU 0 到 CPU 7 的构建中设置第 8 位或更高位，然后唤醒该线程。

## 5. 影响范围

- 违反线程 CPU 亲和性，可能在不受支持的 CPU 槽上运行。
- 导致依赖处理器绑定、NUMA 或设备本地性的驱动与线程出现错误行为。
- 在当前实现最大调度 CPU 槽为 8 的情况下，高位掩码会稳定触发该问题。

## 6. 严重程度

- High

## 7. 可能原因

`pickHomeCpuForAffinity()` 使用“找不到可用比特则返回 0”的默认值。该默认值便于避免空返回类型，但把无效掩码错误解释为“允许 CPU 0”。入队路径也没有再次确认候选槽位确实与掩码相交后终止调度。

## 8. 权威参考依据

- 项目源码：`src/ke/scheduler.zig` 中亲和掩码、`home_cpu` 与就绪队列入队逻辑。
- Windows 亲和掩码的通用语义应依据 Windows 7 文档或 ReactOS 行为另行验证；本报告未使用 REA 二进制对照结论。
- `/home/mobtgzhang/api.json` 是 REA 接入配置，不能作为 Windows API 文档使用。

## 9. 建议修复方案

在当前调度 CPU 范围内选择掩码中第一个置位比特。若没有交集，则不应把线程放入任何就绪队列。可让亲和选择函数表达“无可用 CPU”结果，并在入队和重平衡路径跳过该线程，同时保留原掩码以便后续诊断。

## 10. 验证方法

- 构造仅含调度范围外比特的掩码，确认线程不会被入队到 CPU 槽 0。
- 构造包含 CPU 2 的掩码，确认线程只进入对应槽位。
- 运行调度相关测试和 `zig build -Darch=x86_64`。
- 后续需用 Windows 7 文档或 REA 对相关内核 API 的行为对照确认无效掩码的精确返回码与错误路径；本报告只确认当前实现的调度一致性缺陷。

## 11. 状态

- Fixed

## 12. 修复说明

`pickHomeCpuForAffinity()` 改为返回 `?u32`，只在当前调度 CPU 范围内选择第一个允许比特；无交集时返回 `null`。`enqueueReadyLocked()` 收到 `null` 时不再入队，`setThreadAffinityMask()` 也不再把无效掩码改写为 CPU 0。该修复保证无效掩码线程不会落入不允许的槽位。构建和 config/boot 回归测试通过；Windows 7 无效亲和掩码的精确 API 返回码仍需文档或 REA 对照验证。
