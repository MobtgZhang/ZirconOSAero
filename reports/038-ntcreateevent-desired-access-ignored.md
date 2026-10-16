# 问题 #38：NtCreateEvent 忽略请求访问掩码

## 1. 问题编号

`38`

## 2. 问题位置

- 文件路径：`src/libs/ntdll.zig`
- 函数/模块：`NtCreateEvent()`
- 行号或代码片段：修复前 `allocEventObject(initial_state, event_type)` 成功后使用固定 `ob.GENERIC_ALL | ob.SYNCHRONIZE` 创建句柄，`desired_access` 参数被忽略。

## 3. 问题描述

`NtCreateEvent` 接收 `desired_access`，但创建句柄时不使用该值，而是始终授予 `GENERIC_ALL | SYNCHRONIZE`。调用方请求受限访问时，返回句柄的实际权限与请求不符。

## 4. 复现路径

1. 用户进程通过系统调用分发器调用 `NtCreateEvent`。
2. `desired_access` 设置为受限访问掩码。
3. 系统调用成功后检查句柄条目中的 `granted_access`。
4. 修复前观察到句柄被授予固定全权访问，而不是调用方请求的访问掩码。

## 5. 影响范围

- 影响 NT 事件对象的句柄权限模型。
- 可能放大后续句柄继承、复制或访问检查的授权范围。
- 与 Windows 7 `NtCreateEvent` 将 `desired_access` 传入对象插入路径的行为不一致。

## 6. 严重程度

- Medium

## 7. 可能原因

事件池对象创建路径为了简化匿名同步对象，固定授予全权句柄，没有保留调用方请求的访问掩码。

## 8. 权威参考依据

- REA 镜像对照：`/tmp/w7-sys/4/Windows/System32/ntoskrnl.exe`，`NtCreateEvent`，Ghidra 12.1.4 函数伪代码与汇编分析，实际函数地址 `0x140345e60`；证据输出为 `/tmp/rea-ntcreateevent.json`。该函数先校验事件类型，随后调用 `ObCreateObject`、`KeInitializeEvent` 和 Object Manager 插入路径；汇编在 `0x140345e7d` 将 `EDX`（`desired_access`）保存到 `R12D`，在 `0x140345f2e` 将其传给 `R8D`，并在 `0x140345f33` 传入插入函数 `FUN_14036a6f0`。
- `/home/mobtgzhang/api.json`：该文件是 REA provider 配置，不是 Windows API 文档；本条未从中提取行为依据。

## 9. 建议修复方案

在 `NtCreateEvent` 中把 `desired_access` 直接传给 `handle_table.allocHandle`，不再固定为 `GENERIC_ALL | SYNCHRONIZE`。这样句柄条目的 `granted_access` 与调用方请求保持一致，同时保留事件类型白名单校验。

## 10. 验证方法

- 将执行 `zig build test`。
- 将执行 `zig build -Darch=x86_64`。
- 将执行 `zig build -Darch=aarch64`。
- 将执行 `zig build -Darch=riscv64`。
- 将执行 `zig build -Darch=loongarch64`。
- 将执行 `git diff --check`。
- 后续可在 QEMU 中调用 `NtCreateEvent` 并检查受限访问句柄的 `granted_access`；也可用 REA 对比修复后的句柄授权路径。

## 11. 状态

- Fixed

## 12. 修复记录与二进制对照结论

已修改 `src/libs/ntdll.zig`：`NtCreateEvent` 现在使用 `desired_access` 创建句柄。

与原始二进制对照结论：**与原始行为一致（范围：句柄授权保留请求访问掩码）**。REA 证据来自 `ntoskrnl.exe` 的 `NtCreateEvent @ 0x140345e60` 函数伪代码与汇编；该函数把调用方访问掩码传入 Object Manager 插入路径。本报告未声称已复刻完整的命名对象创建路径。
