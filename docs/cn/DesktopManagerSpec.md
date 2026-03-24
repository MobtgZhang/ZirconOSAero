# 桌面管理器总体规格（NT 6.1 风格）

本文档定义 ZirconOSAero 中 **会话 / 窗口站 / 桌面 / DWM 合成** 的职责边界与对象映射，与
[PROCESS_NT61.md](PROCESS_NT61.md) Phase 4 一致，并补充 Win32 子系统与 LPC 对应关系。

## 1. 设计决断：方案 B（内核呈现 + 用户态场景权威）

当前代码路径同时存在：

- **内核**：`src/drivers/video/dwm_compositor.zig`、`display.zig`、`renderer_aero.zig` — 帧缓冲上完成 Aero 任务栏、壁纸、玻璃等 **实际像素输出**。
- **用户态 Aero 库**：`src/desktop/aero/src/compositor.zig` — **离屏 Surface、Z-order、脏区、光标层** 的逻辑模型（宿主或测试可接 `renderer.RenderOps`）。

**方案 B**（选定）：内核负责 **扫描输出与与硬件相关的 present**；用户 Aero 库持有 **合成树与 Shell 策略的规范描述**（Surface 生命周期、Layer 类型、Hit-test 顺序）。二者必须通过 **`dwm_nt61_defaults.zig` 单一数值源** 对齐玻璃默认参数，避免双轨漂移。

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

## 7. 参考链接

- [The Desktop Window Manager (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/win32/learnwin32/the-desktop-window-manager)
- [DirectComposition — Architecture and components](https://learn.microsoft.com/en-us/windows/win32/directcomp/architecture-and-components)
- [ReactOS ntuser/desktop.c](https://doxygen.reactos.org/d2/dc3/win32ss_2user_2ntuser_2desktop_8c_source.html)
