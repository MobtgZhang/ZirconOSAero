# 问题 #22：VAD 前缀删除只处理首个节点

## 1. 问题编号

`22`

## 2. 问题位置

- 文件路径：`src/mm/vad.zig`
- 函数/模块：`removePrefixRange`
- 行号或代码片段：原实现只定位 `range_start` 所在节点。

## 3. 问题描述

当删除范围跨越多个 VAD 时，后续节点不会被遍历，形成元数据孤岛。

## 4. 复现路径

创建多个相邻 VAD，然后调用 `removePrefixRange()` 删除覆盖所有节点的范围。

## 5. 影响范围

导致 VAD 元数据泄漏、`NtQueryVirtualMemory` 与后续映射判断不一致。

## 6. 严重程度

High

## 7. 可能原因

删除循环只处理第一个包含起始地址的节点，没有推进游标。

## 8. 权威参考依据

- Microsoft Learn：虚拟内存释放作用于整个保留/提交范围。
- ReactOS 行为：VAD 释放必须遍历覆盖范围的所有节点。
- 本次修复来自源码审计与测试，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已新增 `removeSubrange()`，`removePrefixRange()` 现在按 `cur -> seg_end` 循环推进，正确处理首/尾拆分和多个完整节点。

## 10. 验证方法

新增 `vad removePrefixRange spans multiple nodes` 测试，验证三个相邻 VAD 的范围删除只保留尾部。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。
