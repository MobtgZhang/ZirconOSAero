# 问题 #25：VAD 精确删除范围溢出

## 1. 问题编号

`25`

## 2. 问题位置

- 文件路径：`src/mm/vad.zig`
- 函数/模块：`removeExact`
- 行号或代码片段：原实现使用 `start + num_pages * ps`，未检查溢出。

## 3. 问题描述

当页数或起始地址过大时，端点计算可发生 `u64` 溢出，导致错误匹配或比较失真。

## 4. 复现路径

以接近 `u64` 上限的 `start` 或极大 `num_pages` 调用 `removeExact()`。

## 5. 影响范围

可能导致错误的 VAD 删除判断、地址空间元数据损坏或内核崩溃。

## 6. 严重程度

Medium

## 7. 可能原因

缺少 checked multiplication/addition。

## 8. 权威参考依据

- Microsoft Learn：虚拟内存范围参数必须可校验且溢出应返回失败。
- 本次修复来自源码审计与测试，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已使用 `std.math.mul` 和 `std.math.add` 检查页数与端点计算，溢出返回 false。

## 10. 验证方法

新增 `vad removeExact rejects overflow` 测试，验证极大页数不会触发溢出。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。
