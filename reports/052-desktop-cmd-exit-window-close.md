# 问题 #52：桌面 CMD 的 exit 命令不关闭窗口

## 1. 问题编号

`52`

## 2. 问题位置

- 文件路径：`src/desktop/applications/accessories/cmd_shell.zig`、`src/desktop/kernel/shell/cmd_shell_instance.zig`
- 函数/模块：`processCommandEx()`、`cmdExecuteCommand()`
- 行号或代码片段：`exit` 未进入桌面本地命令；桌面窗口实例未响应内核 `state = .exiting`。

## 3. 问题描述

在桌面 CMD 窗口输入 `exit` 后，内核命令解释器把 shell 标记为 exiting，但 GUI CMD 窗口仍然保留并继续接受输入。

## 4. 复现路径

1. 启动 Aero 桌面并打开 Command Prompt。
2. 输入 `exit` 并按 Enter。
3. 观察输出为 “Exiting CMD...”，但窗口未关闭。

## 5. 影响范围

影响桌面 CMD 的命令生命周期与用户预期，可能留下已经逻辑退出的窗口实例。

## 6. 严重程度

- Medium

## 7. 可能原因

桌面 GUI 命令桥接只捕获内核 Console 输出，没有把内核 `exiting` 状态映射到桌面窗口实例的关闭操作。

## 8. 权威参考依据

Windows 7 `cmd.exe` 的 `exit` 内置命令会结束当前命令提示符；ReactOS `cmd` 也以终止当前 shell 实例作为 `exit` 的行为。本判断基于 Windows 7 / ReactOS 命令行为，未做二进制反汇编。

## 9. 建议修复方案

让桌面 CMD 把 `exit` 作为本地生命周期命令处理，设置 `exit_requested`；窗口实例管理器在命令执行完成后关闭对应实例。

## 10. 验证方法

1. 使用 Zig 0.18 构建 x86_64 UEFI 镜像。
2. 启动桌面 CMD，输入 `exit`。
3. 确认窗口关闭且不再响应键盘输入。

## 11. 状态

- Fixed
