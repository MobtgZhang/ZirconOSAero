# 问题 #35：NtCreateEvent 接受非法事件类型

## 1. 问题编号

`35`

## 2. 问题位置

- 文件路径：`src/libs/ntdll.zig`
- 函数/模块：`NtCreateEvent()`
- 行号或代码片段：修复前 `allocEventObject(initial_state, event_type)` 只对 `event_type == SYNCHRONIZATION_EVENT` 添加自动重置标志，其他值不会被拒绝。

## 3. 问题描述

`NtCreateEvent` 接受任意 `event_type` 值并创建事件对象。Windows 7 原始实现只接受 `NOTIFICATION_EVENT`（0）和 `SYNCHRONIZATION_EVENT`（1），其他事件类型应返回 `STATUS_INVALID_PARAMETER`。

## 4. 复现路径

1. 调用 `NtCreateEvent`，传入 `event_type = 2`。
2. 当前实现会创建一个非同步事件对象。
3. 原始实现应立即返回 `STATUS_INVALID_PARAMETER`，不创建对象。

## 5. 影响范围

- 事件对象类型语义错误，可能破坏等待/重置行为。
- 与 Windows 7 `ntoskrnl.exe` 的错误码行为不一致。
- 可能导致上层依赖非法事件类型被拒绝的兼容逻辑失效。

## 6. 严重程度

- Medium

## 7. 可能原因

实现时只把 `SYNCHRONIZATION_EVENT` 作为特殊分支处理，缺少对合法事件类型全集的白名单校验。

## 8. 权威参考依据

- REA / Ghidra 函数分析：
  - 目标文件：`/tmp/w7-sys/4/Windows/System32/ntoskrnl.exe`
  - 函数：`NtCreateEvent`
  - 地址：`0x140345e60`
  - 分析方法：Ghidra 12.1.4 函数伪代码与汇编控制流分析，REA 快照 `/tmp/w7-ntoskrnl.rea`
  - 证据：伪代码在 `param_4 == 0 || param_4 == 1` 时才进入 `ObCreateObject`；否则返回 `-0x3ffffff3`，即 `STATUS_INVALID_PARAMETER`。
- 公开 NT 语义：事件类型为 `NotificationEvent` 和 `SynchronizationEvent` 两个合法枚举值。
- `/home/mobtgzhang/api.json`：该文件是 REA provider 配置，不是 Windows API 文档；本条未从中提取行为依据。

## 9. 建议修复方案

在 `NtCreateEvent` 分配对象前显式校验 `event_type`，只允许 `NOTIFICATION_EVENT` 与 `SYNCHRONIZATION_EVENT`；其他值返回 `STATUS_INVALID_PARAMETER`。

修复后与原始二进制行为对应关系为：`event_type` 合法时进入对象创建路径，非法时直接返回原始观察到的 `STATUS_INVALID_PARAMETER`，不创建对象。

## 10. 验证方法

- 新增主机测试 `event creation validates event type`，验证 `0`、`1` 通过，`2` 被拒绝。
- 将该测试接入 `zig build test`。
- 执行 `zig build test`。
- 可继续使用 REA 对 `NtCreateEvent` 修复前后伪代码进行对照，确认错误码与控制流一致。

## 11. 状态

- Fixed

## 12. 修复记录与二进制对照结论

已修复文件：

- `src/libs/ntdll.zig:1526`
- `src/libs/ntdll.zig:1547`
- `src/libs/ntdll.zig:325`
- `src/ntdll_sync_security_host_test.zig:36`

验证结果：`zig build test` 通过。

与原始二进制对照结论：**部分对照**。REA 已确认原始 `NtCreateEvent` 只接受事件类型 `0` / `1`，否则返回 `STATUS_INVALID_PARAMETER`；本修复对齐该可观察行为。对象创建后续路径与完整副作用仍需进一步 REA 对照。
