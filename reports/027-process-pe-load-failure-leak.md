# 问题 #27：PE 进程加载失败后地址空间与进程槽位泄漏

## 1. 问题编号

`27`

## 2. 问题位置

- 文件路径：`src/ps/process.zig`
- 函数/模块：`createProcessFromPe`
- 行号或代码片段：原实现先调用 `createProcess`，在 PE 校验或映射失败时直接 `return null`，未回收已创建的地址空间和进程槽位。

## 3. 问题描述

`createProcess` 成功后，PE 校验或映射失败会留下一个 `active` 进程和已占用地址空间槽位。该进程没有初始线程可自然退出，`g_proc_address_space_busy` 也不会被释放。

## 4. 复现路径

调用 `createProcessFromPe`，先通过 `createProcess` 成功创建进程，再传入无法通过 `validatePeHeader` 的 PE 数据；或使 `mapPeSectionsToAddressSpace` 返回 false。重复触发会耗尽进程和地址空间槽位。

## 5. 影响范围

影响进程创建、内核内存管理和系统长期运行稳定性。失败路径会导致进程数量和地址空间容量被虚假占用，后续合法进程创建失败。

## 6. 严重程度

High

## 7. 可能原因

错误返回路径只处理了函数结果，没有与 `createProcess` 已获取的资源对称配对。

## 8. 权威参考依据

- Windows NT 进程生命周期要求进程地址空间、句柄表与进程对象在进程清理路径统一释放；本判断基于公开 NT 进程语义。
- 本次修复来自源码审计，未将 REA 二进制分析结论作为修复依据；未执行 `ntoskrnl.exe` 对应函数级对照。

## 9. 建议修复方案

已在这两个失败分支调用 `terminateProcess(proc.pid, 0)`。该路径会通过注册的 `before_release_process_address_space` 先切离线程，再调用 `releaseProcessAddressSpace`、释放地址空间槽位、关闭句柄并标记进程 terminated。

## 10. 验证方法

审查失败分支资源释放路径，并运行内核构建与宿主回归测试。后续可增加主机级 PE 失败加载测试，断言地址空间槽位释放、进程状态为 terminated 且地址空间已清空。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。

