# 问题 #28：对象引用与句柄表并发更新竞态

## 1. 问题编号

`28`

## 2. 问题位置

- 文件路径：`src/ob/object.zig`
- 函数/模块：`ObjectHeader.addRef`、`HandleTable.allocHandle`、`HandleTable.closeHandle`、`incHandleCount`
- 行号或代码片段：`HandleTable` 原先没有表级锁；`allocHandle` 在无锁状态下修改同一空闲槽位、`count` 和对象引用计数。

## 3. 问题描述

两个 CPU 同时调用同一进程句柄表的 `allocHandle` 时，可能扫描到同一个空闲槽位并先后写入，导致句柄计数、`count` 与实际有效句柄不一致。`addRef` 和 `handle_count` 使用无饱和原子加，极端并发下可回绕，造成过早释放或引用计数错误。

## 4. 复现路径

在 SMP 环境中，两个线程同时持有同一 `Process.handle_table` 指针并调用 `allocHandle`；或在极高频率引用/关闭路径中将 `ref_count`/`handle_count` 推到 `u32` 上限。

## 5. 影响范围

影响进程、线程、文件、注册表键、Section、事件、互斥体和信号量等全部句柄对象。可导致句柄覆盖、引用泄漏、过早回收、句柄计数不一致，以及并发关闭时的使用后释放风险。

## 6. 严重程度

High

## 7. 可能原因

对象管理器假设 SMP/ISR 可并发，但句柄槽位分配缺少串行化；引用计数更新缺少饱和保护。

## 8. 权威参考依据

- Windows NT 对象管理器使用引用计数与句柄计数保护对象生命周期；句柄关闭必须平衡创建时的引用与句柄计数。该依据来自公开 NT 对象管理语义。
- 本次修复来自源码审计和并发语义审查，未将 REA 二进制分析结论作为修复依据；未执行 `ntoskrnl.exe` 对应函数级对照。

## 9. 建议修复方案

已为 `HandleTable` 增加 IRQ 自旋锁，`allocHandle` 与 `closeHandle` 在表锁内完成槽位查找、引用计数、句柄计数和 `count` 更新。`addRef` 改为 CAS 饱和递增；新增 `incHandleCount` 在 CAS 递增前拒绝 `u32` 最大值，并在表满或计数饱和时对称回滚引用。

## 10. 验证方法

新增宿主测试验证 `addRef` 饱和不回绕、句柄计数饱和时分配失败且引用不泄漏。后续应在多核/QEMU 环境中并发执行同进程句柄创建关闭压力测试，断言计数最终一致。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。

