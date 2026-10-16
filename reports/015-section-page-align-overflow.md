# 问题 #15：Section 大小页对齐溢出

## 1. 问题编号

`15`

## 2. 问题位置

- 文件路径：`src/mm/section.zig`
- 函数/模块：`pageAlignUp`、`createAnonymousSection`、`createFileBackedSection`
- 行号或代码片段：原 `pageAlignUp()` 使用 `(size + page_size - 1)`，未检查 `u64` 溢出。

## 3. 问题描述

当 Section 最大尺寸接近 `u64` 上限时，页对齐计算会整型溢出，导致得到错误的最大值或触发 Zig 整数溢出崩溃。

## 4. 复现路径

调用 `NtCreateSection` 创建匿名 Section，并传入接近 `std.math.maxInt(u64)` 的 `maximum_size`；或使用超大文件尺寸创建文件后备 Section。

## 5. 影响范围

影响 Section 对象创建与后续映射路径，可导致映射边界错误、内核崩溃或拒绝服务。

## 6. 严重程度

High

## 7. 可能原因

对齐函数按内部 `u64` 直接相加，没有使用饱和或 checked arithmetic。

## 8. 权威参考依据

- Microsoft Learn：`NtCreateSection`/`CreateFileMapping` 要求大小按页对齐且必须可校验。
- 本次修复来自源码审计与单元测试，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已将页对齐改为 `pageAlignUpChecked()`，使用 `u64` checked addition；创建 Section 时在占用静态槽位前完成校验，失败返回 `null`。

## 10. 验证方法

已添加 `Section size alignment rejects overflow` 测试，使用 `std.math.maxInt(u64)` 验证不溢出且返回失败。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行；本修复不声明已与原始二进制行为完全等价。
