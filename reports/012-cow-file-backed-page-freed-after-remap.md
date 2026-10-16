# 问题 #12：文件后备 CoW 成功重映射后立即释放新物理页

## 1. 问题编号

`12`

## 2. 问题位置

- 文件路径：`src/mm/vm.zig`
- 函数/模块：`tryCowWriteFault()`
- 行号或代码片段：原实现使用 `defer if (old_share_count == 0) space.allocator.free(new_phys);`，该语句在成功路径也会执行。

## 3. 问题描述

`tryCowWriteFault()` 在文件后备页共享计数为 0 时分配新私有帧、从文件重新加载内容并重映射 PTE。随后函数返回，无条件 `defer` 判断 `old_share_count == 0` 为真，立刻把刚刚映射到 PTE 的 `new_phys` 归还物理页分配器。后续访问该页会读取可能被覆盖的内存，严重时导致内核或用户数据损坏。

## 4. 复现路径

1. 建立一个映射到文件后备只读页的地址空间。
2. 使该物理页 `shareCount == 0`。
3. 在该页触发写故障，调用 `tryCowWriteFault()`。
4. 函数成功返回后立即触发该 VA 的后续访问。

在单线程宿主测试中可通过调用后检查 `isPhysicalPageFree(new_phys)` 复现；真实 QEMU 需要可写入的文件后备 section。

## 5. 影响范围

- 可导致已提交的文件后备页被错误复用。
- 造成跨对象数据损坏、内核读用户/文件页时数据不一致或内存管理器崩溃。
- 影响映像、数据文件 section、fork/CoW 与 demand-paging 相关路径。

## 6. 严重程度

- Critical

## 7. 可能原因

原代码把“仅错误路径需要释放新帧”的生命周期写成了普通 `defer`。`old_share_count == 0` 是选择重载策略的条件，不是函数结束前释放新帧的条件。

## 8. 权威参考依据

- 项目源码：`src/mm/vm.zig` 的 `tryCowWriteFault()`、`cowReloadFromFileView()`、`space.allocator.free()` 与 `FrameAllocator.free()`。
- WDK/Windows 内存管理公开概念：copy-on-write 写入故障应建立新的私有可写物理页并更新 PTE，原只读映射保留；Windows 7 具体内部页表操作须以二进制对照为准。
- Windows 7 SP1 x64 `ntoskrnl.exe`（SHA-256 `7fba129db114e8808a2ee5ae597f66176b7eb3c4077e0b5e9a3be3f74aa2e6a6`）已通过 REA/Ghidra 建立分析快照；本报告未引用具体的未导出 `Mi*CopyOnWrite` 函数结论，因为 Ghidra 自动分析未提供可靠符号名，当前修复依据的是 Zig 生命周期错误本身。
- `/home/mobtgzhang/api.json` 是 REA 接入配置，不是内存管理 API 文档；未从中提取 CoW 语义。

## 9. 建议修复方案

将普通 `defer` 改为 `errdefer`：新帧只在重载、查找 VAD 或重映射 PTE 失败时释放；重映射成功后函数返回，新帧必须保持已分配状态。若旧页是共享写时复制页，成功后仍递减旧物理页共享计数。

## 10. 验证方法

- 构造带文件后备只读 VAD 的地址空间，设置 `shareCount == 0` 后调用写故障，验证成功返回时对应新物理页不在空闲位图中。
- 构造重映射失败路径，验证新物理页被释放，避免错误路径泄漏。
- 运行 `zig build test`、`zig build -Darch=x86_64`，并用 QEMU 运行文件映射写压测。

## 11. 状态

- Fixed

## 12. 修复说明

已把成功也会执行的 `defer` 改为 `errdefer`，保留成功路径的新物理页所有权。宿主单元测试与 x86-64 构建验证待本轮统一执行；QEMU 文件后备压测仍待补充。
