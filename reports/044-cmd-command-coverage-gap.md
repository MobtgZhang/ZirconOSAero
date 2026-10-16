# 问题 #44：cmd.exe 命令覆盖缺口

## 1. 问题编号

`44`

## 2. 问题位置

- 文件路径：`src/subsystems/win32/cmd.zig`
- 函数/模块：命令派发表、帮助输出
- 行号或代码片段：`endlocal`、`getmac`、`gpupdate`、`msconfig`、`msinfo32`、`nlsfunc` 缺少入口或仅缺失输出。

## 3. 问题描述

cmd.exe 的命令覆盖仍低于 Windows 7 实际命令集合，用户输入这些命令会进入 unrecognized 分支或缺少帮助项。

## 4. 复现路径

在 CMD Shell 输入 `endlocal`、`getmac`、`gpupdate`、`msconfig`、`msinfo32` 或 `nlsfunc`。

## 5. 影响范围

降低 Ring 3 shell 的 Windows 7 兼容性和可用性。

## 6. 严重程度

Medium

## 7. 可能原因

命令派发表按增量扩展，尚未建立完整命令矩阵。

## 8. 权威参考依据

Windows 7 cmd.exe 支持以上内置命令或系统工具启动路径；本次实现为非版权文本的兼容行为子集。

## 9. 建议修复方案

新增命令入口与基础输出函数，并把命令加入 `HELP` 列表。后续继续补齐批处理控制流、参数展开和退出码语义。

## 10. 验证方法

构建通过；命令派发表中可见新入口；可在 QEMU CMD Shell 中执行并观察非失败输出。

## 11. 状态

Fixed
