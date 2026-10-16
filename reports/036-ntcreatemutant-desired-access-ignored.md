# 问题 #36：NtCreateMutant 忽略请求访问掩码

## 1. 问题编号

`36`

## 2. 问题位置

- 文件路径：`src/libs/ntdll.zig`
- 函数/模块：`NtCreateMutant()`
- 行号或代码片段：修复前 `allocMutexObject(initial_owner)` 后使用固定 `ob.GENERIC_ALL | ob.SYNCHRONIZE` 创建句柄，`desired_access` 参数被忽略。

## 3. 问题描述

`NtCreateMutant` 接收 `desired_access`，但创建句柄时不使用该值，而是始终授予 `GENERIC_ALL | SYNCHRONIZE`。调用方请求受限访问时，返回句柄的实际权限与请求不符。

## 4. 复现路径

1. 用户进程通过系统调用分发器调用 `NtCreateMutant`。
2. `desired_access` 设置为受限访问掩码。
3. 系统调用成功后检查句柄条目中的 `granted_access`。
4. 观察到句柄被授予固定全权访问。

## 5. 影响范围

- 影响 NT 互斥体对象的句柄权限模型。
- 可能放大后续句柄继承、复制或访问检查的授权范围。
- 与 Windows 7 `NtCreateMutant` 将 `desired_access` 传入对象插入路径的行为不一致。

## 6. 严重程度

- Medium

## 7. 可能原因

池对象创建路径为了简化匿名同步对象，固定授予全权句柄，没有保留调用方请求的访问掩码。

## 8. 权威参考依据

- REA 镜像对照：`/tmp/w7-sys/4/Windows/System32/ntoskrnl.exe`，`NtCreateMutant`，Ghidra 12.1.4 函数伪代码。镜像内实际函数地址为 `0x140326e40`（PDB 符号经 OMAP 映射定位），函数体调用 `ObCreateObject` 后将 `param_2` 传入 `FUN_14036a6f0`，该函数对应 Object Manager 插入路径。
- `/home/mobtgzhang/api.json`：该文件是 REA provider 配置，不是 Windows API 文档；本条未从中提取行为依据。

## 9. 建议修复方案

在 `NtCreateMutant` 中把 `desired_access` 直接传给 `handle_table.allocHandle`，不再固定为 `GENERIC_ALL | SYNCHRONIZE`。这样句柄条目的 `granted_access` 与调用方请求保持一致。

## 10. 验证方法

- `zig build test`
- `zig build -Darch=x86_64`
- `zig build -Darch=aarch64`
- `zig build -Darch=riscv64`
- `zig build -Darch=loongarch64`
- 后续可用 REA 对比修复后的句柄授权路径，并在 QEMU 中验证受限访问调用后句柄权限。

## 11. 状态

- Fixed

## 12. 修复记录与二进制对照结论

已修改 `src/libs/ntdll.zig`：`NtCreateMutant` 现在使用 `desired_access` 创建句柄。

与原始二进制对照结论：**与原始行为一致（范围：句柄授权保留请求访问掩码）**。REA 证据来自 `ntoskrnl.exe` 的 `NtCreateMutant @ 0x140326e40` 函数伪代码；该函数把调用方访问掩码传入 Object Manager 插入路径。本报告未声称已复刻完整的命名对象创建路径。
