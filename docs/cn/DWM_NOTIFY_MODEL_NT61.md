# DWM 通知投递模型（与 csrss / LPC 叙事对照）

## 广播策略决策表（须广播 / 启动豁免 / 不广播）

| 变更源 | 须广播 | 说明 |
|--------|--------|------|
| `dwm.setCompositionEnabled` | `WM_DWMCOMPOSITIONCHANGED` | 合成总开关 |
| `dwm.setColorizationTint` | `WM_DWMCOLORIZATIONCOLORCHANGED` | 染色 + lParam 混合位 |
| `dwm.setGlass` | `WM_DWMNCRENDERINGCHANGED` | 毛玻璃 / NC 策略（**不**发 `WM_DWMCOMPOSITIONCHANGED`） |
| `dwm.syncPolicyFromRegistry` | 见下行 | 见 `src/config/dwm_config_registry_sync.zig` 差异位；**仅当** `user32.getWindowCount() > 0` 且相对前快照有变化时补发；染色 → `WM_DWMCOLORIZATIONCOLORCHANGED`；不透明度 / 任务栏染色 / Aero Peek → `WM_DWMNCRENDERINGCHANGED` |
| `dwm.init` / `applyPlatformAndResolutionTuning` | 否（启动/内部） | 模糊预算与半径上限为性能路径，非独立 `WM_DWM*` 契约 |
| `setSkipGlassBoxBlur` / `setGlassLiteBlurEnabled` | 否 | 帧内交互优化，非 `DwmConfig` |
| 缩略图刷新 | `WM_DWMSENDICONICTHUMBNAIL` | `user32.broadcastDwmIconicThumbnailRequested` |

**启动豁免**：尚无有效 HWND 时，`syncPolicyFromRegistry` **不**投递 `WM_DWM*`，避免桌面会话建立前的空队列噪声。

## 本仓库当前实现（内核单地址空间 Shell）

- **状态变更源**：`src/drivers/video/dwm.zig` 的 `setCompositionEnabled`、`setColorizationTint`、`setGlass`、`syncPolicyFromRegistry` 等。
- **广播路径**：`src/subsystems/win32/user32.zig` 中 `broadcastDwmCompositionChanged` / `broadcastDwmColorizationChanged` / `broadcastDwmNcRenderingChanged` / `broadcastDwmIconicThumbnailRequested`：向 **每个有效 HWND 的消息队列** `postMessage`，并 **额外** 向已登记线程 `PostThreadMessage`（`registerDwmNotificationListener` + `dwm_listener_tids[]`，上限 8）。
- **与 content7.1「csrss 维护监听列表 + LPC 投递」的差异**：本阶段 **无** 独立 csrss 进程内维护列表；等价语义为「登记线程 tid + 内核侧线程投递表」。若将来引入真 LPC/csrss，可将 `registerDwmNotificationListener` 的登记迁移到 csrss，而 ** HWND 队列广播** 仍可与现路径并存（双投）或收敛为单一真源（见 [DesktopManagerSpec.md](DesktopManagerSpec.md) §3.1）。

## WM\_DWM\* 与 `dwm.zig` 触发对应关系

| 消息 | 触发入口（本仓库） | `wParam` / `lParam` 约定（简化） |
|------|-------------------|----------------------------------|
| `WM_DWMCOMPOSITIONCHANGED` | `dwm.setCompositionEnabled` | `wParam`：合成开=1、关=0；`lParam`=0 |
| `WM_DWMCOLORIZATIONCOLORCHANGED` | `dwm.setColorizationTint`；**或** `syncPolicyFromRegistry` 在已有窗口时若染色 dword 变化 | `wParam`：COLORREF 风格色值；`lParam`：混合开≠0（注册表路径当前简化为 `TRUE`） |
| `WM_DWMNCRENDERINGCHANGED` | `dwm.setGlass`（毛玻璃开关变化）；**或** `syncPolicyFromRegistry` 在已有窗口时若不透明度 / 任务栏染色 / Peek 变化 | `wParam`=1（策略启用）；`lParam`=0 |
| `WM_DWMSENDICONICTHUMBNAIL` | `user32.broadcastDwmIconicThumbnailRequested` | `wParam`=0；`lParam` 低/高 16 位为最大宽、高 |

毛玻璃开关 **不** 单独发 `WM_DWMCOMPOSITIONCHANGED`；合成总开关与毛玻璃在配置结构上分离（见 `dwm.DwmConfig`）。

## 测试锚点

主机单测：`tests/nt61/dwm_messages_nt61.zig`、`tests/nt61/dwm_nt61_integration_host.zig`（常量、`lParam` 打包与监听队列叙事烟测）；**`dwm_config_registry_sync_host`**（注册表同步 → 广播提示位）；**`nt61_dual_track_host`**（默认值与标志映射回归）。

## 3. 与「理想 csrss + LPC」拓扑的差异（对照 content7.1）

| 理想项（路线图叙述） | 本仓库当前 |
|----------------------|------------|
| csrss 维护 DWM 监听列表 | 列表在 **内核 `user32`**（`dwm_listener_tids`）；`register_dwm_listener` LPC 仅 **转发** 到同一 API |
| 状态变更经 LPC 投递 `WM_DWM*` | 变更在 **`dwm.zig`**，广播在 **`user32.broadcastDwm*`**（同内核地址空间） |
| 迁移策略 | 将来可将登记权威迁到 csrss 进程；HWND 队列广播可保留或收敛为单投 — 见 [DesktopManagerSpec.md](DesktopManagerSpec.md) §3.1、§3.3（**C1 独立里程碑**，非本迭代「问题二必达」） |
