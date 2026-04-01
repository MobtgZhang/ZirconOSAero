# 桌面管理器总体规格（NT 6.1 风格）

本文档定义 ZirconOSAero 中 **会话 / 窗口站 / 桌面 / DWM 合成** 的职责边界与对象映射，与
[PROCESS_NT61.md](PROCESS_NT61.md) Phase 4 一致，并补充 Win32 子系统与 LPC 对应关系。

## 0. 呈现模型声明（诚实范围）

**合成与 Aero 类视觉效果在 CPU + 线性帧缓冲（GOP）上实现**，为对公开 DWM 文档中「离屏表面再合成」概念的 **软件近似**。本仓库 **不实现** Windows WDDM/D3D 内核显示驱动栈，也 **不** 声称与物理 GPU 上 Windows 7 的渲染管线逐位等价。壁纸、图标与字体须使用仓库许可允许的开源素材（见 [Assets.md](Assets.md)），**不得** 捆绑微软专有位图或声音资源。

## 1. 设计决断：方案 B（内核呈现 + 用户态场景权威）

当前代码路径同时存在：

- **内核**：`src/drivers/video/dwm_compositor.zig`、`display.zig`、`renderer_aero.zig` — 帧缓冲上完成 Aero 任务栏、壁纸、玻璃等 **实际像素输出**。
- **用户态 Aero 库**：`src/desktop/aero/src/compositor.zig` — **离屏 Surface、Z-order、脏区、光标层** 的逻辑模型（宿主或测试可接 `renderer.RenderOps`）。

**方案 B**（选定）：内核负责 **扫描输出与与硬件相关的 present**；用户 Aero 库持有 **合成树与 Shell 策略的规范描述**（Surface 生命周期、Layer 类型、Hit-test 顺序）。二者必须通过 **`nt61_aero_defaults.zig` 单一数值源** 对齐玻璃默认参数，避免双轨漂移。

向 **方案 A**（用户态唯一合成进程、内核仅 blit）演进时：保留本规格中的对象与 API 表，将实现从内核 `renderer_aero` 迁出即可。

## 2. 对象与进程映射

| NT / Win32 概念 | ZirconOS 实现位置 | 说明 |
|-----------------|-------------------|------|
| Session | SMSS `src/servers/smss.zig`、会话状态 | 会话 0 交互桌面 |
| Window station | `subsystem.WindowStation` | `WinSta0` 在 csrss `init()` 创建 |
| Desktop | `subsystem.Desktop` | `Default`、`Winlogon`；可切换活动桌面 |
| 线程桌面绑定 | `Win32Process.desktop_id` | `setProcessDesktop` / `switchToDesktop` |
| CSRSS | `src/subsystems/win32/subsystem.zig` | `CsrApiNumber.create_desktop` 等 |
| user32 入口 | `src/subsystems/win32/user32.zig` | `GetDesktopWindow`、`OpenDesktop` 等（逐步扩展） |
| DWM 策略（Shell） | `shell.zig`、`dwm.zig`、`compositor.zig` | 玻璃、主题、窗口装饰 |
| 内核 DWM 像素管线 | `dwm.zig`（video）、`dwm_compositor.zig` | 盒式模糊、重定向表面元数据 |

## 3. LPC / API 操作码（规划与已实现）

| 端口 / API | 用途 |
|------------|------|
| `\LPC\CsrApiPort` | csrss 请求（见 `subsystem.CsrApiNumber`） |
| `create_window_station` | 创建窗口站（已实现创建 `WinSta0`） |
| `create_desktop` | 在默认窗口站下新建桌面 |
| `register_window` / `post_message` | 与合成 Surface 生命周期对齐（后续） |

## 4. Surface 标志语义对照

实现对照见 [`src/config/dwm_surface_spec.zig`](../../src/config/dwm_surface_spec.zig) 表头注释。

**内核** `RedirectedSurface.flags`：`topmost`、`layered`、`popup`、`child`、`has_caption`、`dwm_blur_behind`、`dwm_ncrendering`、`snap_target`。

**用户** `SurfaceFlags`：`has_alpha`、`needs_shadow`、`is_visible`、`is_opaque`、`needs_blur`、`is_glass`、`is_cursor`、`is_desktop`。

映射原则：`dwm_blur_behind` ↔ `is_glass` + `needs_blur`；`dwm_ncrendering` ↔ 非客户区与 `needs_shadow` / 窗口装饰协同。

## 5. DWM 最小内部 API 子集（验收参考）

对照 MSDN「Developing for the Desktop Window Manager」概念，内部模块应对齐以下能力（名称可为 Zig 函数，不必导出 DLL）：

- 将玻璃延伸到客户区（等价 `DwmExtendFrameIntoClientArea` 策略）
- BlurBehind 区域（等价 `DwmEnableBlurBehindWindow`）
- 合成启用/禁用（等价 `DwmIsCompositionEnabled` / 禁用回退路径）
- 缩略图 / Flip3D：**可选**（`compositor.flip3d_enabled` 预留）

## 6. 资源合规

发行素材不得包含微软专有资源；见 [Assets.md](Assets.md) 与 `src/desktop/aero/resources/MANIFEST.md`。

## 7. 与 desktop-src（GDI / DWM）的契约对照

若使用离线 Learn 镜像（例如 `references/win32/desktop-src`），优先浏览其中 **`gdi/`**、**`dwm/`** 与 **`ProcThread/`** 等目录，核对：

- `src/subsystems/win32/gdi32.zig`、`user32.zig` 的 API 形参与错误路径；
- `src/desktop/aero/` 与 `nt61_aero_defaults.zig` 的合成/玻璃参数是否与文档描述一致。

**鼠标与指针（`inputdev/`、`LearnWin32/mouse-*.md`）**：与内核帧缓冲合成相关的命中、光标形态与重绘策略见 [PointerPolicy_NT61.md](PointerPolicy_NT61.md) 第 2–3 节（含 **NC 热跟踪** 与 `needs_caption_chrome_only` / `render_cap` 路径，D1–D5 行为对照表）。

行为以公开文档为准，实现须独立编写；详见 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)。

## 8. 内核 CPU 合成性能预算（与 DWM 概念对照）

公开文档中 DWM 将各窗绘制到**离屏表面**再合成；本仓库在无 GPU 合成时于帧缓冲上近似该流程，盒式模糊成本为 \(O(\text{像素} \times \text{半径} \times \text{遍数})\)。

- **`nt61_aero_defaults.KernelDwm.blur_budget_pixel_passes_per_frame`**：每帧 `display.renderDesktopFrameEx` / `renderAeroDesktop` 入口重置；`dwm.zig` 内每次 `boxBlurRect` 按 `宽×高×pass` 扣减，耗尽则本帧后续 blur 跳过，仍保留 tint 与高光。
- **`blur_max_single_rect_pixels` / `blur_max_rect_calls_per_frame`**：单块面积与每帧调用次数硬顶，避免前几趟大矩形占满整帧（高分 GOP / LoongArch UEFI 下尤关键）。
- **`blur_resolution_downgrade_pixel_threshold`** 与 **`glass_blur_radius_hd_cap` / `glass_blur_passes_hd_cap`**：帧像素数超阈值时自动下调半径与遍数。
- **`glass_blur_radius_loongarch_cap` / `glass_blur_passes_loongarch_cap`**：由 **`dwm.applyPlatformAndResolutionTuning`** 在 `display.initAeroDwm`（`fb` 已就绪）时与分辨率策略一并应用到 `dwm`/`dwm_config`/`material`。
- **`taskbar_blur_radius_cap`**：限制任务栏全宽条带的模糊半径，减轻条带成本。
- **`renderGlassTintOnly`**：无 `boxBlur`，用于拖窗标题栏、右键菜单、开始菜单首帧大面板等，优先帧率。
- **壳层打开时** `setGlassLiteBlurEnabled(true)` 仍生效；**任务栏**在上下文菜单 / 开始菜单 / 托盘飞出打开时额外走 **`renderGlassTintOnly`**（`display.renderDesktopAeroTaskbar`），避免与场景模糊叠乘。
- **取证**：`framebuffer.logDesktopGopSummary()` 在 `initDesktopMode` 打 **`DesktopGOP:`**；`-Ddesktop_bisect=true` 时在 `main.zig` 桌面循环输出 **`renderDesktopFrameEx` 前后 scheduler tick 差** 与 `fb_w`。

调参时只改 `nt61_aero_defaults.zig`（单一数值源），避免与 `display.initAeroDwm` 漂移。

## 9. 参考链接

- [The Desktop Window Manager (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/win32/learnwin32/the-desktop-window-manager)
- [DirectComposition — Architecture and components](https://learn.microsoft.com/en-us/windows/win32/directcomp/architecture-and-components)
- [Window Stations and Desktops](https://learn.microsoft.com/windows/win32/winstation/window-stations-and-desktops)（会话/桌面公开概念）
