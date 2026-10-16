# 问题 #26：MDL PFN 页数计算溢出

## 1. 问题编号

`26`

## 2. 问题位置

- 文件路径：`src/mm/mdl.zig`
- 函数/模块：`fillPfnsIdentityAssume4k`
- 行号或代码片段：原实现将 `byte_count` 和页大小都用 `u32` 计算。

## 3. 问题描述

当 `byte_count` 接近 `u32` 最大值时，`(byte_count + page - 1)` 发生溢出，得到错误页数。

## 4. 复现路径

使用 `byte_count = std.math.maxInt(u32)` 初始化 MDL 并填充 PFN。

## 5. 影响范围

可能导致 DMA/I/O PFN 数量错误、页填充不完整或越界访问。

## 6. 严重程度

Medium

## 7. 可能原因

中间计算被截断为 `u32`。

## 8. 权威参考依据

- Windows WDK：MDL 的 `ByteCount`/PFN 数量需按系统页大小正确上取整。
- 本次修复来自源码审计与测试，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已将 `byte_count` 提升为 `u64` 后计算页数，并继续受 `max_mdl_pfns` 限制。

## 10. 验证方法

新增 `Mdl PFN count does not overflow u32` 测试，验证极大字节计数填充到 PFN 上限且不崩溃。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。
