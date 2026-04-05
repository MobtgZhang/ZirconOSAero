# LPC 大消息与 `MSG_DATA_SIZE` 边界（NT 6.1 对齐说明）

本内核进程内 LPC 环（`src/lpc/ipc.zig`）单条载荷上限为 **`MSG_DATA_SIZE`（64 字节）** 的紧凑 `Message.data`；与 csrss 握手的扩展字段见 [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md)。

## 超过内联缓冲时的策略（clean-room）

1. **首选（路线图）**：调用方通过 **`NtCreateSection` + `NtMapViewOfSection`** 映射共享节，**小消息**仅携带 **视图句柄/偏移/长度** 或协议魔数；大字节留在节内。须与 [MM_Section_Roadmap.md](MM_Section_Roadmap.md) 同步验收。
2. **当前未实现节协作时**：用户态 `NtRequestWaitReplyPort` / 等价路径在探测到请求超过 `MSG_DATA_SIZE` 的可复制载荷时，应返回 **`STATUS_BUFFER_TOO_SMALL`**（`0xC0000023`），与 MSDN 对「缓冲不足」类语义一致；**不得**静默截断。
3. **QEMU / 单测**：以 `tests/lpc_two_pid_host.zig`（队列语义）与契约矩阵 **B1** 行为为准；节视图协议落地后补 **端到端** 用例。

## 参考

- [Local Procedure Calls (LPC)](https://learn.microsoft.com/windows-hardware/drivers/kernel/local-procedure-calls-lpc-) — 概念层，无源码依赖。
