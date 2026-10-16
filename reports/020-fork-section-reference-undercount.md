# 问题 #20：Fork 复制 Section 视图缺少对象引用

## 1. 问题编号

`20`

## 2. 问题位置

- 文件路径：`src/mm/vm.zig`
- 函数/模块：`duplicateUserMappingsForFork`、`copyUserSideMetadataForFork`
- 行号或代码片段：原实现直接 `memcpy` `section_view_obj` 指针。

## 3. 问题描述

子进程复制了指向 `SectionObject` 的原始指针，但没有增加对象引用；父进程或原进程释放对象后，子进程元数据成为悬挂指针。

## 4. 复现路径

父进程映射文件或匿名 Section 后 fork；随后父进程卸载视图或关闭对象，再由子进程访问视图元数据或触发懒加载。

## 5. 影响范围

可导致 use-after-free、Section 静态槽位复用错误、文件后备内容错误或内核崩溃。

## 6. 严重程度

Critical

## 7. 可能原因

fork 元数据复制只复制指针数组，没有同步引用计数。

## 8. 权威参考依据

- Windows NT fork/进程创建语义：子进程持有的对象引用必须独立计数。
- ReactOS 行为：对象引用计数覆盖每个进程持有的视图。
- 本次修复来自源码审计与测试，未将 REA 二进制分析结论作为修复依据。

## 9. 建议修复方案

已在复制 Section 视图元数据后为每项调用 `header.addRef()` 并同步增加 `active_view_count`；失败或释放时对称递减。

## 10. 验证方法

通过 fork/CoW host 测试与 Section 生命周期测试联合验证；后续可增加 fork 后父进程关闭句柄的专项用例。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64`、`aarch64`、`riscv64`、`loongarch64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。
