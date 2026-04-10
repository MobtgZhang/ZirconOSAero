# Desktop Manager Overall Spec (NT 6.1 Style)

This document defines **Session / Window Station / Desktop / DWM composition** responsibility boundaries and object mapping in ZirconOSAero. Consistent with [PROCESS_NT61.md](PROCESS_NT61.md) Phase 4, supplementing Win32 subsystem and LPC relationships.

## 0. Present Model Declaration (Honest Scope)

Composition and Aero-style visual effects are implemented on **CPU + linear framebuffer (GOP)**, as a **software approximation** of the "off-screen surface then composite" concept in public DWM documentation. This repository **does not implement** the Windows WDDM/D3D kernel display driver stack and **does not claim** bit-exact rendering pipeline equivalence with Windows 7 on physical GPU.

Wallpaper, icons, and fonts must use open-source materials permitted by the repository license (see [Assets.md](../cn/Assets.md)).

## 1. Design Decision: Scheme B (Kernel Present + Userspace Scene Authority)

Current code has both:

- **Kernel**: `src/drivers/video/core/dwm_compositor.zig`, `display.zig`, `renderer_aero.zig` — handle actual pixel output (taskbar, wallpaper, glass) on framebuffer.
- **Userspace Aero library**: `src/desktop/aero/src/compositor.zig` — logical model for off-screen surfaces, Z-order, dirty regions, cursor layer (host/test can wire `renderer.RenderOps`).

**Scheme B** (chosen): kernel is responsible for **scan output and hardware-related present**; userspace Aero library holds **compositing tree and Shell policy authoritative descriptions** (Surface lifecycle, Layer types, Hit-test order).

Both sides must align via **`nt61_aero_defaults.zig`** as single numeric source for glass default parameters.

Evolution toward **Scheme A** (userspace sole compositing process, kernel only blit): retain object and API tables in this spec, migrate implementation out of kernel `renderer_aero`.

### 1.1 Scheme A Migration Checklist (Phase 2 Engineering Gate)

| Check item | Scheme B (current) responsibility | Scheme A target responsibility | Kernel retains (minimal) |
|------------|--------------------------------|-----------------------------|--------------------------|
| Wallpaper / taskbar / Start menu pixels | `renderer_aero.zig`, `display.zig` shell drawing | userspace compositor + shared/mapped surfaces | GOP **blit**, optional hardware cursor notification |
| Per-window glass / blur / shadow | `dwm.zig`, `material.zig`, `dwm_compositor.compose` | userspace or separate compositing service writes off-screen buffer | only **submit dirty region + present** contract; no box blur hot path |
| Z-order / dirty rectangle authority | `user32` + `dwm_compositor` surface metadata | userspace `aero/compositor.zig` single source | kernel validates HWND/surface binding and security policy then **forwards** |
| Thumbnail / Flip3D sampling | `dwm_compositor` framebuffer read-back | userspace holds thumbnail buffer or submits bitmap via IOCTL | throttle and **frame serial** alignment (see below) |
| VSync / frame beat | `display.present`, `isDesktopVsyncPolicyEnabled` | userspace pump or kernel **honest** wait on HAL | `waitForVerticalBlank`-style hook placeholder |

**Present contract**: `display.submitCompositorPresentHints(?framebuffer.Rect)` registers dirty rectangles related to the current frame **before** `present()` is called; `present()` end calls `dwm_compositor.notifyFramePresented()` to increment compositor frame serial and drive thumbnail refresh throttle.

**Acceptance**: migrate each drawing category, synchronize [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §4.1 and host tests (e.g. `dwm_nt61_integration_host`).

## 2. Object and Process Mapping

| NT / Win32 concept | ZirconOSAero implementation | Notes |
|--------------------|--------------------------|-------|
| Session (logon) | `session.zig` | one per boot |
| Window Station (WinSta0) | `win_sta.zig` | interactive |
| Desktop (Default) | `desktop.zig` | active interactive desktop |
| DWM | `dwm_compositor.zig` | in-kernel; not win32k.sys |
| csrss | `subsystem.zig` | LPC stub |

## 3. LPC / csrss API Opcodes

| Opcode | Name | Layout | Notes |
|--------|------|--------|-------|
| `register_window` | register HWND | hwnd (LE u32), thread_id, parent_hwnd | owned by `subsystem` |
| `post_message` | post to HWND queue | hwnd, msg, wParam, lParam | `user32.broadcastDwm*` writes here |
| `get_message` | fetch next message | output to fixed offsets per `csr_lpc_policy.zig` | `csrFillOneMessageForLpc` |
| `0x10027` | `register_dwm_listener` | v1: magic `0x014D5744` + tid; old: tid only | cap 8 listeners |
| `0x10028` | `open_desktop` | magic `DSK1` + name | returns 1-based HDESK |
| `0x10029` | `switch_desktop` | same | |
| `0x1002A` | `close_desktop` | magic `DSL1` + HDESK | |

## 4. DWM Notification Broadcast Policy

| Change source | Must broadcast? | Notes |
|--------------|-----------------|-------|
| `dwm.setCompositionEnabled` | `WM_DWMCOMPOSITIONCHANGED` | overall on/off |
| `dwm.setColorizationTint` | `WM_DWMCOLORIZATIONCOLORCHANGED` | tint + lParam blend |
| `dwm.setGlass` | `WM_DWMNCRENDERINGCHANGED` | does **not** send `WM_DWMCOMPOSITIONCHANGED` |
| `dwm.syncPolicyFromRegistry` | conditional | only when `user32.getWindowCount() > 0` and changed from previous snapshot |
| Startup | exempt | no HWND yet → no dispatch |

See [DWM_NOTIFY_MODEL_NT61.md](DWM_NOTIFY_MODEL_NT61.md) for wParam/lParam conventions.

## 5. Surface Flag Semantic Mapping

Kernel ↔ userspace `SurfaceFlags` must be aligned via `config/aero_flag_mapping.zig` and tested by **`aero_flag_mapping_host`**. See [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §4.1.

## 6. CPU Compositing Performance Budget

Guidelines for box blur in CPU software compositing. See [SOFTWARE_COMPOSITOR_WDDM.md](../cn/SOFTWARE_COMPOSITOR_WDDM.md) for authoritative constants.
