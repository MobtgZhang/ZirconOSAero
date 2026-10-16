# 问题 #13：帧分配路径忽略锁定 PFN 或被锁定链头提前阻断

## 1. 问题编号

`13`

## 2. 问题位置

- 文件路径：`src/mm/frame.zig`
- 函数/模块：`popFrameInZoneFixed()`、`allocZeroed()`、`allocZeroedBelowMaxPhys()`
- 行号或代码片段：原 `popFrameInZoneFixed()` 只检查链头；`allocZeroed()` 与 `allocZeroedBelowMaxPhys()` 从零页链表取帧时未检查 `pfn_locks`。

## 3. 问题描述

帧分配器维护独立的 PFN 锁计数，但部分分配路径没有一致遵守该锁。`allocZeroed()` 会弹出并激活一个已锁定帧；`allocZeroedBelowMaxPhys()` 同样会把锁定零页链表节点分配出去。相反，`popFrameInZoneFixed()` 在普通/高/低 zone 链头命中锁定帧时立即返回 `null`，不会扫描后面的未锁定帧。结果是锁定帧可能被分配，或者一个锁定帧阻断整个空闲链表。

## 4. 复现路径

1. 调用 `testSeedLinearFreeFrames()` 构造多个空闲帧。
2. 将帧 0、帧 1 放入零页链表并调用 `lockPfnPhys()` 锁定帧 0。
3. 调用 `allocZeroed()` 或 `allocZeroedBelowMaxPhys()`，原实现返回并激活帧 0。
4. 另一场景：锁定普通空闲链表头后调用 `allocInZone()`，原实现直接返回 `null`，即使后续帧可用。

宿主单元测试可直接复现；真实内核中对应 MDL 锁页、页表帧或驱动保留页路径。

## 5. 影响范围

- 已锁定帧可能被再次映射，造成页所有权冲突、数据损坏或悬挂引用。
- MDL、页表、驱动保留页等依赖 PFN 锁的路径可能失去互斥保护。
- 单个锁定帧位于链表头时可阻断同 zone 的其他空闲帧分配，导致虚假内存耗尽。
- 影响 VM、MDL、连续物理分配和驱动 I/O 相关子系统的稳定性。

## 6. 严重程度

- High

## 7. 可能原因

PFN 锁检查没有集中到统一的链表弹出原语。普通分配路径只在链头检查一次，零页分配路径则完全没有检查；两条路径随后各自调用 `activateFrame()`。代码演进时新增的零页复用路径复用了链表节点但没有复用锁定帧的排除规则。

## 8. 权威参考依据

- 项目源码：`FrameAllocator.pfn_locks`、`lockPfnPhys()`、`unlockPfnPhys()`、`free()`、`allocContiguousInZone()` 中对 PFN 锁的一致检查。
- Windows 7 SP1 x64 `ntoskrnl.exe`（SHA-256 `7fba129db114e8808a2ee5ae597f66176b7eb3c4077e0b5e9a3be3f74aa2e6a6`）REA/Ghidra 快照；本报告未引用未导出的具体 PFN 数据库内部函数符号，因为自动分析未提供可核验的名称。
- WDK/ReactOS 公开概念：MDL 锁页与 PFN 数据库的页状态转换要求已锁页不被普通分配路径复用；具体 Windows 7 内部函数行为仍需后续 REA 对照。
- `/home/mobtgzhang/api.json` 是 REA 接入配置，不是本问题的 API 文档；未从中提取 PFN 锁语义。

## 9. 建议修复方案

把“跳过锁定帧”集中到零页/普通空闲链表遍历逻辑中：遍历链表时检查每个节点的 `pfn_locks`，仅对未锁定帧执行 `listUnlink()` 和 `activateFrame()`；超过清零地址上限的零页帧也应继续向后扫描而不是终止。这样与 `allocContiguousInZone()`、`free()` 已有的锁定帧语义保持一致。

## 10. 验证方法

- 构造锁定链头与锁定零页帧的宿主单元测试，验证 `allocInZone()`、`allocZeroed()`、`allocZeroedBelowMaxPhys()` 都返回后续未锁定帧。
- 验证锁定帧在分配后 `pfnState()` 不变为 active，且对应物理地址不会被 `free()` 错误回收。
- 运行 `zig build test` 与 `zig build -Darch=x86_64`。
- 后续用 QEMU 运行 MDL 锁页和页表分配负载，验证锁定帧不再被普通分配复用。

## 11. 状态

- Fixed

## 12. 修复说明

已新增统一的未锁定链表弹出与“低于地址上限的未锁定零页”弹出辅助函数，`popFrameInZoneFixed()`、`allocZeroed()`、`allocZeroedBelowMaxPhys()` 均改用该逻辑。新增三个锁定帧回归测试。`zig build test` 与 `zig build -Darch=x86_64` 通过；QEMU 系统级验证待后续执行。
