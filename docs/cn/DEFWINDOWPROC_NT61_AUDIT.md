# DefWindowProcA（NT 6.1）与 `user32.zig` 对照备忘

**目的**：C1 清单 — 与 [Microsoft Learn — DefWindowProc](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-defwindowproca) 行为级对照；实现见 [`user32.zig`](../../src/subsystems/win32/user32.zig) `DefWindowProcA`。

| 消息（示例） | Learn 要点 | 本仓库 |
|--------------|------------|--------|
| `WM_NULL` | 默认返回 0 | 落入通用分支 → 0 |
| `WM_NCHITTEST` | 缺省命中测试 | `defNcHitTestForWindow` |
| `WM_NCCALCSIZE` / `WM_NCPAINT` | 非客户区 | 子集几何与脏区 |
| `WM_DWMCOMPOSITIONCHANGED` 等 | 应用常自行处理 | 广播由 `broadcastDwm*`，`DefWindowProc` 可返回 0 |

**非目标**：用户 VA `WndProc`、完整 NC 绘制与挂钩链 — 见 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §5.1。

**测试**：`dwm_messages_nt61_host`（常量 + 打包器）；`DefWindowProc` 逐消息扩展时补 **win32k_api_semantics_host** 或专用 `tests/nt61/*_host.zig`。
