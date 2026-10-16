# 问题 #17：Section 视图计数回绕

## 1. 问题编号

`17`

## 2. 问题位置

- 文件路径：`src/mm/section.zig`
- 函数/模块：`mapViewIntoProcess`
- 行号或代码片段：原实现使用 `sec.active_view_count +%= 1`。

## 3. 问题描述

`active_view_count` 使用包装加法，理论上达到 `u32` 上限后会回绕为 0，使对象生命周期判断失真。

## 4. 复现路径

极长运行或在测试中人为把 `active_view_count` 置为 `u32` 最大值后继续映射视图。

## 5. 影响范围

影响 Section 对象生命周期与映射视图计数，可能导致过早释放或资源泄漏。

## 6. 严重程度

Medium

## 7. 可能原因

计数路径误用了 Zig 的包装加法。

## 8. 权威参考依据

- Microsoft Learn：对象/视图生命周期应基于引用计数且失败返回资源类 NTSTATUS。
- 本次修复来自源码审计，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已改为先检查 `active_view_count == maxInt(u32)`，失败返回 `STATUS_INSUFFICIENT_RESOURCES`，并回滚已完成的匿名映射与视图记录。

## 10. 验证方法

现有 Section/VM 测试通过；可在后续测试中注入最大计数以覆盖回滚分支。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。
