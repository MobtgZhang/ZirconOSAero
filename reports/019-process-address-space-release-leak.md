# 问题 #19：进程地址空间释放只回收 PML4

## 1. 问题编号

`19`

## 2. 问题位置

- 文件路径：`src/mm/vm.zig`
- 函数/模块：`releaseProcessAddressSpace`
- 行号或代码片段：原实现清空元数据后仅 `allocator.free(space.pml4_phys)`。

## 3. 问题描述

进程退出时未遍历用户页表子树，用户数据帧、PDP/PD/PT 等中间页表帧被泄漏。

## 4. 复现路径

创建进程、映射用户页后终止进程并观察物理帧位图；或运行 host 回归测试检查已映射页是否回到空闲池。

## 5. 影响范围

造成大量物理帧泄漏，长期运行会耗尽可用内存，影响系统稳定性。

## 6. 严重程度

Critical

## 7. 可能原因

释放路径只回收顶层 PML4，未调用架构已有的用户半区页表释放器。

## 8. 权威参考依据

- Windows NT 进程终止语义要求回收私有地址空间资源；共享资源按引用计数回收。
- ReactOS 文档/源码行为：进程地址空间销毁需要释放页表与私有页。
- 本次修复来自源码审计与测试，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已在释放时调用 `paging.releaseUserHalfAddressSpace()` 回收用户半区叶帧与中间页表，再释放 PML4。释放回调先减少共享计数再执行 `free()`，避免 CoW 共享页被误释放或永久卡住。

## 10. 验证方法

新增 `releaseProcessAddressSpace frees user leaf and page tables` 测试，验证映射页在释放后回到空闲位图。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。
