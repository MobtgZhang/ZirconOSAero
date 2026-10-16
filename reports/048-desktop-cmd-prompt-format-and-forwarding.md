# 问题 #48：桌面 CMD prompt 空参数输出字面量

## 1. 问题编号

`48`

## 2. 问题位置

- 文件路径：`src/desktop/applications/accessories/cmd_shell.zig`
- 函数/模块：`executeCommand`
- 行号或代码片段：原代码调用 `formatOutputStatic(out_buf, "PROMPT {text}\r\n")`。

## 3. 问题描述

桌面 CMD 执行不带参数的 `prompt` 时，直接返回静态字符串，导致屏幕显示未格式化的 `{text}`，而不是当前命令提示符。

## 4. 复现路径

进入桌面 CMD，输入 `prompt` 并回车。

## 5. 影响范围

- CMD 输出与 Windows cmd.exe 的 `prompt` 行为不一致；
- 用户无法确认当前提示符状态；
- 暴露内部格式化占位符，降低 shell 兼容性。

## 6. 严重程度

- Low

## 7. 可能原因

使用了 `formatOutputStatic`，但该函数不做 Zig 格式化替换。

## 8. 权威参考依据

- Windows cmd.exe 的 `PROMPT` 不带参数显示当前提示符，参考 Microsoft Learn《Command shell overview》与 `prompt /?` 的行为描述。
- 本条未使用 REA 对照镜像，因为这是源代码层面的格式化缺陷。

## 9. 建议修复方案

改用 `formatOutput(out_buf, "PROMPT {s}\r\n", .{shell.getPrompt()})`。同时把 `mkdir`/`md` 从本地未实现分支移除，让已支持文件操作的内核 CMD 分发器处理。

## 10. 验证方法

1. 构建 x86_64 ESP 并启动桌面；
2. 在桌面 CMD 执行 `prompt`，确认输出为当前提示符而非 `{text}`；
3. 执行 `mkdir`，确认进入内核 CMD 分发而不是本地“not implemented”；
4. 运行 `make test ARCH=x86_64` 防止回归。

## 11. 状态

- Fixed
