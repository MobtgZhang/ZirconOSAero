# 问题 #16：Section 映射偏移未校验页对齐

## 1. 问题编号

`16`

## 2. 问题位置

- 文件路径：`src/mm/section.zig`
- 函数/模块：`mapViewIntoProcess`
- 行号或代码片段：原实现只检查 `section_offset >= maximum_size`，未检查页对齐。

## 3. 问题描述

非页对齐的 `section_offset` 可以进入映射路径，导致文件读取偏移、页索引和视图边界计算失真。

## 4. 复现路径

调用 `NtMapViewOfSection` 时传入非页对齐的 `SectionOffset`，例如 `1`。

## 5. 影响范围

影响文件后备视图和匿名视图的页边界与内容定位，可能导致读入错位数据或越界访问。

## 6. 严重程度

High

## 7. 可能原因

缺少 NT 映射 API 的偏移对齐前置条件。

## 8. 权威参考依据

- Microsoft Learn：`NtMapViewOfSection` 的 `SectionOffset` 需按系统页大小对齐。
- 本次修复来自源码审计与平台文档，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已在 `mapViewIntoProcess()` 入口检查 `section_offset` 是否为页对齐；不对齐返回 `STATUS_INVALID_PARAMETER`。

## 10. 验证方法

通过构建与现有 Section/VM 回归测试验证；后续可补充 QEMU 用户态用例验证非对齐偏移返回值。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。
