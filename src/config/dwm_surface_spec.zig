//! DWM 表面标志 — **语义对照表**（实现分别在 `dwm_compositor.RedirectedSurface.flags` 与
//! `compositor.SurfaceFlags`）。完整说明见 [docs/cn/DesktopManagerSpec.md](../../docs/cn/DesktopManagerSpec.md)。
//!
//! | 概念 (NT6.1 / MS DWM)   | 内核 `SurfaceFlags`     | 用户 `SurfaceFlags`     |
//! |-------------------------|-------------------------|-------------------------|
//! | 顶层 / TOPMOST          | `topmost`               | （Z-order 显式赋值）      |
//! | 分层窗口                | `layered`               | `has_alpha`             |
//! | 弹出菜单                | `popup`                 | `LayerType.menu`        |
//! | 子窗口                  | `child`                 | （预留）                |
//! | 非客户区 DWM 绘制       | `dwm_ncrendering`       | `needs_shadow` / 装饰   |
//! | BlurBehind              | `dwm_blur_behind`       | `is_glass`, `needs_blur`|
//! | 贴靠目标                | `snap_target`           | （Shell 策略）          |

pub const spec_version: u32 = 1;
