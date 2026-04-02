# NT 6.1 窗口消息 / user32 契约追溯表（ZirconOSAero）

本表将 **Microsoft Learn** 上的窗口函数与消息与仓库路径、测试挂钩；实现须 clean-room。每合并一批能力须更新 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 并运行 `bash scripts/verify-compliance.sh`（见 [NT61_PR_GATES.md](NT61_PR_GATES.md)）。

| 类别 | 名称 | 参考（Learn） | 代码路径 | 测试 / 验证 |
|------|------|---------------|----------|-------------|
| API | `CreateWindowEx` | Window 函数 | `src/subsystems/win32/user32.zig` | 契约：失败 `NULL` + `SetLastError` |
| API | `DestroyWindow` | 同上 | 同上 | `ERROR_INVALID_HANDLE` |
| API | `SetWindowPos` / `MoveWindow` | 同上 | 同上 | 与 `dwm_compositor` 脏区联动 |
| API | `GetMessage` / `PeekMessage` | 消息泵 | 同上 | 线程过滤 + `PM_*` |
| 内核 | `NtUserDispatchMessage`（折叠 SSDT `0x5E`） | 消息泵 | `syscall.zig` + `user32.zig` `ntUserDispatchMessageSyscall` | W 波次桩 → 完整 WndProc |
| API | `BeginPaint` / `EndPaint` | WM_PAINT | 同上 | `PAINTSTRUCT` |
| 消息 | `WM_DWMCOMPOSITIONCHANGED` 等 | DWM 消息 | `user32.zig` `broadcastDwm*` | 矩阵 §4 |
| 消息 | `WM_NCHITTEST` / `WM_NCLBUTTONDOWN` | 非客户区 | `user32.zig` `DefWindowProcA` | [PointerPolicy_NT61.md](PointerPolicy_NT61.md) |
| 消息 | `WM_DWMSENDICONICTHUMBNAIL` | DWM | `user32.broadcastDwmIconicThumbnailRequested` + `dwm_compositor` 缩略缓冲 | 矩阵 §4 |
| 内核 | HWND / Z-order 真源 | win32k 概念 | `user32` + `win32k/mod.zig` | `zig build test` → win32k_host |
| LPC | `register_window` / `post_message` | 子系统 | `subsystem.zig` + `port.setCsrRequestHandler` | MVT / 手测 |

## 维护

新增行时同步 **§ 状态** 与 [API_COMPAT_MATRIX.md](API_COMPAT_MATRIX.md)（若存在对应行）。
