# 问题 #11：lookaside 推入/弹出缺少中断保护

## 1. 问题编号

`11`

## 2. 问题位置

- 文件路径：`src/mm/lookaside.zig`
- 函数/模块：`tryPop()`、`tryPush()`
- 行号或代码片段：原实现读取 `heads[c][slot]`、写回 `h.next`/`node.next`、更新 `depths` 的过程没有任何关中断或原子化窗口。

## 3. 问题描述

lookaside 链表按当前 CPU 分桶，但普通线程与中断上下文可能访问同一个 CPU 桶。若 `tryPush()` 读取旧链头后被中断打断，中断处理函数再对同一槽位推入或弹出节点，返回后线程会基于旧链头写入，造成链表分叉、节点丢失或深度计数不一致。

## 4. 复现路径

需要多核或可抢占/中断内核环境：

1. 线程在某个池档位调用 `tryPop()` 并读取到链头。
2. 同一 CPU 的定时器或设备中断进入池释放路径并调用 `tryPush()`。
3. 中断返回后线程继续用过期链头写回 `heads[c][slot]`。

宿主单元测试当前 `percpu.currentCpuIndex()` 恒为 0 且依赖宿主线程模型，难以直接复现；本问题为内核运行时竞争，需要系统级验证。

## 5. 影响范围

- 可导致池节点丢失、重复返回或悬挂指针式链表错误。
- 破坏 `depths` 与实际链长的同步关系。
- 影响池热路径与依赖池分配的内核子系统稳定性。

## 6. 严重程度

- High

## 7. 可能原因

实现假设 lookaside 桶只会在当前 CPU 的非中断上下文访问，未覆盖中断重入窗口。该假设与内核池释放路径可能在中断上下文执行的事实不一致。

## 8. 权威参考依据

- Windows 7 SP1 x64 `ntoskrnl.exe`（SHA-256 `7fba129db114e8808a2ee5ae597f66176b7eb3c4077e0b5e9a3be3f74aa2e6a6`）。
- REA/Ghidra 分析 `ExInterlockedPopEntryList`，函数地址 `0x140078930`：反汇编显示 `PUSHFQ`/`CLI`、`BTS.LOCK` 自旋、链表弹出、`AND.LOCK` 解锁，并保存/恢复 IF 位。该导出函数证明链式释放/分配操作在 Windows 内核实现中带有中断保护与同步自旋。
- REA/Ghidra 分析 `ExFlushLookasideListEx`，函数地址 `0x1401001a0`：函数先调用 `ExpInterlockedFlushSList`，再遍历弹出节点并调用清理回调，说明 lookaside 操作依赖互斥的链表抽取原语。
- WDK 对 lookaside list 与 interlocked list 操作的公开行为描述。
- `/home/mobtgzhang/api.json` 是 REA 接入配置，不是本函数的 API 语义文档；未从中提取 API 行为描述。

## 9. 建议修复方案

在 `tryPop()` 和 `tryPush()` 进入临界区前保存 IF 并关闭中断，完成单链表读写后按原 IF 状态恢复。这样不会引入 `pool_gate` 嵌套持锁，也能覆盖同 CPU 中断重入。后续若开放真正的 SMP per-CPU 错误分桶，应再评估跨 CPU 一致性与 KPCR 接线。

## 10. 验证方法

- 运行 `zig build test` 与 `zig build -Darch=x86_64`，确认热路径编译与现有池测试不回归。
- 构造池分配/释放回调，在中断路径中高频释放节点，配合中断出口调度进行压力验证。
- 使用 QEMU 多核镜像与中断负载进行运行时复测；如无法稳定注入竞争，先保留代码级审查与 Windows 二进制互锁原语对照结论。

## 11. 状态

- Fixed

## 12. 修复说明

已为 `tryPop()` 和 `tryPush()` 添加保存/恢复 IF 的关中断窗口。该修复与 REA 观察到的 `ExInterlockedPopEntryList` 中断保护行为方向一致；宿主单元测试和 x86-64 内核构建通过，多核中断竞争仍需 QEMU 系统级验证。
