# DWM Notification Delivery Model (vs. csrss / LPC Narrative)

## Broadcast Policy Decision Table (must-broadcast / startup-exempt / do-not-broadcast)

| Change source | Must broadcast? | Notes |
|---------------|-----------------|-------|
| `dwm.setCompositionEnabled` | `WM_DWMCOMPOSITIONCHANGED` | Overall composition on/off |
| `dwm.setColorizationTint` | `WM_DWMCOLORIZATIONCOLORCHANGED` | Tint + lParam blend bit |
| `dwm.setGlass` | `WM_DWMNCRENDERINGCHANGED` | Glass / NC policy; **does NOT** send `WM_DWMCOMPOSITIONCHANGED` |
| `dwm.syncPolicyFromRegistry` | see below | See `src/config/dwm_config_registry_sync.zig` diff bits; **only when** `user32.getWindowCount() > 0` and changed from previous snapshot |
| `dwm.init` / `applyPlatformAndResolutionTuning` | No (startup/internal) | Blur budget and radius upper bound are performance path, not independent `WM_DWM*` contract |
| `setSkipGlassBoxBlur` / `setGlassLiteBlurEnabled` | No | In-frame interaction optimization, not `DwmConfig` |
| Thumbnail refresh | `WM_DWMSENDICONICTHUMBNAIL` | `user32.broadcastDwmIconicThumbnailRequested` |

**Startup exemption**: when no valid HWND exists yet, `syncPolicyFromRegistry` does **not** dispatch `WM_DWM*`, avoiding empty-queue noise before desktop session establishment.

## Current Repository Implementation (Kernel Single-Address-Space Shell)

- **State change sources**: `src/drivers/video/core/dwm.zig` methods: `setCompositionEnabled`, `setColorizationTint`, `setGlass`, `syncPolicyFromRegistry`, etc.
- **Broadcast path**: `src/subsystems/win32/user32.zig`: `broadcastDwmCompositionChanged` / `broadcastDwmColorizationChanged` / `broadcastDwmNcRenderingChanged` / `broadcastDwmIconicThumbnailRequested` / `broadcastDwmWindowMaximizedChanged` / `broadcastDwmIconicLivePreviewBitmapRequested` — posts to **each valid HWND's message queue** via `postMessage`, **additionally** `PostThreadMessage` to registered threads (**authoritative tid table**: `csr_dwm_listeners.zig`, written by LPC `register_dwm_listener`; cap 8; `user32.registerDwmNotificationListener` still forwards to same table). `wParam`/`lParam` packing aligns with `compositionChangedWParam`, `colorizationChangedLParam`, `iconicSizeRequestLParam` in `dwm_nt61_api_contract.zig`.
- **Difference from canonical "csrss maintains DWM listener list + LPC dispatch" topology**: listener tid table has landed on **csrss module side** (`csr_dwm_listeners.zig` + `subsystem.handleApiCall`); **HWND queue broadcast** still in `user32.broadcastDwm*` (see [DesktopManagerSpec.md](DesktopManagerSpec.md) §3.1).

## WM_DWM* ↔ `dwm.zig` Trigger Mapping

| Message | Trigger entry (repository) | `wParam` / `lParam` convention (simplified) |
|---------|---------------------------|----------------------------------------|
| `WM_DWMCOMPOSITIONCHANGED` | `dwm.setCompositionEnabled` | `wParam`: on=1, off=0; `lParam`=0 |
| `WM_DWMCOLORIZATIONCOLORCHANGED` | `dwm.setColorizationTint`; or `syncPolicyFromRegistry` when windows exist and tint dword changed | `wParam`: COLORREF-style color value; `lParam`: blend on≠0 |
| `WM_DWMNCRENDERINGCHANGED` | `dwm.setGlass` (glass toggle changed); or `syncPolicyFromRegistry` when windows exist and opacity/taskbar tint/Peek changed | `wParam`=1 (policy enabled); `lParam`=0 |
| `WM_DWMSENDICONICTHUMBNAIL` | `user32.broadcastDwmIconicThumbnailRequested` | `wParam`=0; `lParam` low/high 16 bits = max width/height (`iconicSizeRequestLParam`) |
| `WM_DWMWINDOWMAXIMIZEDCHANGE` | `user32.broadcastDwmWindowMaximizedChanged` | `wParam` non-zero = maximized; `lParam`=0 |
| `WM_DWMSENDICONICLIVEPREVIEWBITMAP` | `user32.broadcastDwmIconicLivePreviewBitmapRequested` | Same `lParam` packing as thumbnail request |

Glass toggle does **not** independently send `WM_DWMCOMPOSITIONCHANGED`; overall composition switch and glass are separate fields in `dwm.DwmConfig`.

## Test Anchors

Host tests: `tests/nt61/dwm_messages_nt61.zig`, `tests/nt61/dwm_nt61_integration_host.zig` (constants, `lParam` packing and listener queue narrative smoke); **`dwm_config_registry_sync_host`** (registry sync → broadcast hint bits); **`nt61_dual_track_host`** (default value and flag mapping regression).

## Difference from Canonical csrss + LPC Topology

| Canonical item (roadmap narrative) | Repository current |
|-----------------------------------|-------------------|
| csrss maintains DWM listener list | **`csr_dwm_listeners.zig`** (`subsystem.register_dwm_listener` writes); `user32.broadcastDwm*` reads table, `PostThreadMessage` |
| State changes dispatched via LPC to `WM_DWM*` | Changes in **`dwm.zig`**, broadcast in **`user32.broadcastDwm*`** (same kernel address space) |
| Migration strategy | Future: move registration authority to csrss process; HWND queue broadcast can stay or converge to single dispatch — see [DesktopManagerSpec.md](DesktopManagerSpec.md) §3.1, §3.3 (**C1 independent milestone**) |
