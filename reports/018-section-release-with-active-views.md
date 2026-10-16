# 问题 #18：存在活跃视图时释放 Section 对象

## 1. 问题编号

`18`

## 2. 问题位置

- 文件路径：`src/mm/section.zig`、`src/libs/ntdll.zig`
- 函数/模块：`releaseSectionObject`、`NtClose`
- 行号或代码片段：原实现可能在活跃视图仍持有对象指针时回收静态槽位。

## 3. 问题描述

Section 视图登记了指向 `SectionObject` 的原始指针，但没有对应对象引用。关闭句柄或提前释放对象可能产生悬挂指针。

## 4. 复现路径

映射 Section 视图后关闭 Section 句柄，或触发对象释放路径；随后访问视图元数据或执行懒加载。

## 5. 影响范围

可导致 use-after-free、静态槽位复用错误、文件后备懒加载崩溃。

## 6. 严重程度

Critical

## 7. 可能原因

视图引用未纳入对象引用计数，且对象释放函数缺少视图存活保护。

## 8. 权威参考依据

- Microsoft Learn：映射视图保持 Section 对象存活，`NtClose` 不应因存在视图而失败。
- ReactOS 行为：Section 对象与视图引用生命周期分离。
- 本次修复来自源码审计与测试，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已为每次映射和 fork 复制增加 `header.addRef()`；卸载、释放地址空间或 fork 失败时对称 `header.release()`。`releaseSectionObject()` 同时保留 `active_view_count != 0` 保护；`NtClose` 不再因有视图而提前拒绝。

## 10. 验证方法

新增 `Section release is deferred while views remain` 测试，验证存在视图时对象不释放，视图结束后可回收。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。
