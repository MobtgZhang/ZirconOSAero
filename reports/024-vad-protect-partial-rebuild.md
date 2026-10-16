# 问题 #24：VAD 保护位更新失败留下部分树

## 1. 问题编号

`24`

## 2. 问题位置

- 文件路径：`src/mm/vad.zig`
- 函数/模块：`replaceRangeProtect`
- 行号或代码片段：原实现删除节点后分段插入，失败时未恢复原树。

## 3. 问题描述

保护范围拆分/重插失败时，函数返回 false 但 VAD 树已处于部分重建状态。

## 4. 复现路径

触发 `replaceRangeProtect()` 的分段插入失败分支（如资源耗尽）。

## 5. 影响范围

导致保护属性不完整、VAD 与 PTE 状态不一致，可能造成越权访问或缺页处理错误。

## 6. 严重程度

High

## 7. 可能原因

删除和插入没有封装为完整事务。

## 8. 权威参考依据

- Microsoft Learn：`VirtualProtect` 语义要求失败时不破坏原保护状态。
- ReactOS 行为：VAD 保护更新失败应恢复原状态。
- 本次修复来自源码审计与测试，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已在修改前保存整棵树中序快照；任意分段插入失败时调用 `restoreFromEntries()` 恢复原树。

## 10. 验证方法

现有 `replaceRangeProtect` 测试通过；可在资源耗尽注入测试中进一步覆盖恢复分支。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。
