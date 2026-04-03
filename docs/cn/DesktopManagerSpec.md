# 桌面管理器总体规格（NT 6.1 风格）

本文档定义 ZirconOSAero 中 **会话 / 窗口站 / 桌面 / DWM 合成** 的职责边界与对象映射，与
[PROCESS_NT61.md](PROCESS_NT61.md) Phase 4 一致，并补充 Win32 子系统与 LPC 对应关系。

## 0. 呈现模型声明（诚实范围）

**合成与 Aero 类视觉效果在 CPU + 线性帧缓冲（GOP）上实现**，为对公开 DWM 文档中「离屏表面再合成」概念的 **软件近似**。本仓库 **不实现** Windows WDDM/D3D 内核显示驱动栈，也 **不** 声称与物理 GPU 上 Windows 7 的渲染管线逐位等价。壁纸、图标与字体须使用仓库许可允许的开源素材（见 [Assets.md](Assets.md)），**不得** 捆绑微软专有位图或声音资源。

## 1. 设计决断：方案 B（内核呈现 + 用户态场景权威）

当前代码路径同时存在：

- **内核**：`src/drivers/video/core/dwm_compositor.zig`、`display.zig`、`renderer_aero.zig` — 帧缓冲上完成 Aero 任务栏、壁纸、玻璃等 **实际像素输出**。
- **用户态 Aero 库**：`src/desktop/aero/src/compositor.zig` — **离屏 Surface、Z-order、脏区、光标层** 的逻辑模型（宿主或测试可接 `renderer.RenderOps`）。

**方案 B**（选定）：内核负责 **扫描输出与与硬件相关的 present**；用户 Aero 库持有 **合成树与 Shell 策略的规范描述**（Surface 生命周期、Layer 类型、Hit-test 顺序）。二者必须通过 **`nt61_aero_defaults.zig` 单一数值源** 对齐玻璃默认参数，避免双轨漂移。

向 **方案 A**（用户态唯一合成进程、内核仅 blit）演进时：保留本规格中的对象与 API 表，将实现从内核 `renderer_aero` 迁出即可。

### 1.1 方案 A 迁移检查表（阶段 2 工程闸门）

下列项用于将 **方案 B → 方案 A** 的职责迁移拆成可验收步骤；行为仍以公开文档（DWM / Desktop Window Manager 概念）为参考，实现保持 clean-room。

| 检查项 | 方案 B（当前）责任所在 | 方案 A 目标责任 | 内核保留（最小集） |
|--------|------------------------|-----------------|-------------------|
| 壁纸 / 任务栏 / 开始菜单像素 | `renderer_aero.zig`、`display.zig` 壳层绘制 | 用户态 compositor + 共享/映射表面 | GOP **blit**、可选硬件光标通知 |
| 每窗玻璃 / 模糊 / 阴影 | `dwm.zig`、`material.zig`、`dwm_compositor.compose` | 用户态或独立合成服务写入离屏缓冲 | 仅 **提交脏区 + present** 契约；不保留盒式模糊热路径（可配置关闭） |
| Z-order / 脏矩形权威 | `user32` + `dwm_compositor` 表面元数据 | 用户态 `aero/compositor.zig` 为单一真源 | 内核校验 HWND/表面绑定与安全策略后 **转发** |
| 缩略图 / Flip3D 采样 | `dwm_compositor` 帧缓冲读回 | 用户态持有缩略缓冲或经 IOCTL 提交位图 | 节流与 **帧序号** 对齐（见下） |
| VSync / 帧节拍 | `display.present`、`isDesktopVsyncPolicyEnabled` | 用户态泵或内核 **诚实** 等待 HAL | `waitForVerticalBlank` 类钩子占位（WDK 行为级，无专有栈） |

**Present 契约（内核 API 草图，已实现入口）**：`display.submitCompositorPresentHints(?framebuffer.Rect)` 在调用 `present()` **之前**登记与本帧相关的脏矩形（并入 `framebuffer.addDirtyRect` 合并策略）；`present()` 末尾 `dwm_compositor.notifyFramePresented()` 递增合成器帧序号并驱动缩略刷新节流。查询节拍：`display.getFrameCount()`（桌面 present 计数）、`dwm_compositor.getFrameNumber()`（合成器序号）。未来用户态唯一合成时，应在 IOCTL/LPC 载荷中携带等价脏区与序号，**不**臆测未公开的 Win32k 内部结构。

**验收**：每迁出一类绘制，同步更新 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §4.1 与主机测试（如 `dwm_nt61_integration_host`）；`-Ddesktop-full` 下行为与默认路径一致。

## 2. 对象与进程映射

| NT / Win32 概念 | ZirconOSAero 实现位置 | 说明 |
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
| `register_window` / `post_message` | **已实现路径（内核）**：`user32.CreateWindowExA` 在 `dwm_compositor` 已初始化时 `createSurface` 并 `syncCompositorZOrderForUserWindows`；`DestroyWindow` → `destroySurface`；`PostMessageA` / 线程槽 `PostThreadMessageA` 与 `csrFillOneMessageForLpc` 一致；脏区由 `display.renderDesktopFrameEx` 与 `handleMouseMove` 提示驱动（见 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §4.1） |

### 3.1 csrss 与 user32 直连合成（边界）

- **主路径（当前 Shell）**：`user32` 在同内核地址空间内为 `CreateWindowEx` / `DestroyWindow` 直接分配与销毁 `dwm_compositor` 表面，并维护每窗口消息队列；`HWND`→`compositor_surface_id` 的绑定以该路径为准。
- **CSRSS `register_window` / `post_message`**：用于 LPC/会话工具与跨进程叙事样本；取消息时须提供与 `user32` 一致的 **线程 id**（`peekMessageAForThread` / `csrFillOneMessageForLpc`），否则队列不匹配。长期可选收敛：CSR 仅转发到上述 `user32` 队列实现单一真源；在收敛前，本文档以 **「内核 GUI = user32 + compositor；CSR = 兼容/测试端口」** 为界。

### 3.2 DWM 通知：`WM_DWM*` 与监听线程

与 **典型 NT 风格**「csrss 维护监听列表 + LPC 投递」拓扑的差异、本仓库等价实现，以及各消息与 `dwm.zig` 触发关系，见 [DWM_NOTIFY_MODEL_NT61.md](DWM_NOTIFY_MODEL_NT61.md)。

### 3.3 LPC / csrss 与「单一真源」差距清单（工程核对）

| 主题 | 当前状态 | 备注 |
|------|----------|------|
| 窗口创建/销毁 → 合成树 | **主路径闭合**：`user32.CreateWindowEx`/`DestroyWindow` ↔ `dwm_compositor`（`detachCompositorSurface` 单点释放，与 `ensureCompositorSurface` 对偶）；**LPC**：`register_window` / `destroy_window` → `onCsrssRegisterGuiWindow` / `DestroyWindow` | csrss 仅对已存在于 `user32` 表的 HWND 补 `ensureCompositorSurface`；**不能**替代「无 CreateWindow 则无主表面」的语义 |
| Z-order | **子集**：`SetWindowPos` + `syncCompositorZOrderForUserWindows`（**两趟**：先非 `is_topmost` 表面再顶层）；`HWND_TOPMOST` / `HWND_NOTOPMOST` 维护 `Window.is_topmost`；`HWND_TOP` / `HWND_BOTTOM` 仅在 **同 band** 内调整；**指定 HWND 之后**：跨 band 时将 `hwnd` 的 `is_topmost` 与 `insert_after` 对齐后再插入（`user32.placeHwndAboveInsertAfter`） | 见矩阵 §4.1 |
| DWM 监听列表 | **内核线程表**（`registerDwmNotificationListener`），非 csrss 进程内列表 | 与上述典型拓扑差异见 [DWM_NOTIFY_MODEL_NT61.md](DWM_NOTIFY_MODEL_NT61.md) §3 |
| 注册表 → Shell | **ZOSH1 可选文件** + 启动后 `mouse.syncFromRegistry` / `dwm.syncPolicyFromRegistry` | [hive.zig](../../src/registry/hive.zig)、[registry.zig](../../src/registry/registry.zig) |
| 消息队列 tid | **必须一致**：`GetMessage`/`PostMessage` 与 `csrFillOneMessageForLpc` 使用同一 `thread_id` | LPC 测试若 tid 错配则「有 HWND 无消息」假阴性 |

### 3.4 LPC `CsrApiNumber` → `user32` 调用步骤（问题五）

**无** 单独 LPC「创建 HWND」：`CreateWindowEx` 仅在 **user32** 内部分配槽位与（可选）`dwm_compositor` 表面。下表为 `subsystem.handleApiCall` 与内核 `user32` 的**实际**调用链，避免「以为 LPC 会建窗」的文档歧义。

| LPC API（`subsystem.zig`） | 调用的 `user32` / 其它 | **不**经过的入口 |
|----------------------------|-------------------------|------------------|
| `register_window` | `registerGuiWindow` → **`onCsrssRegisterGuiWindow`**（对已存在 `HWND`：`ensureCompositorSurface` + `notifyCompositorWindowGeometry` + `syncCompositorZOrderForUserWindows` + `syncWin32kFromUser32`） | `CreateWindowEx`、`PostMessage`（除非另行调用） |
| `destroy_window` | **`DestroyWindow`**（内含 `detachCompositorSurface`）→ `unregisterGuiWindow`（计数） | 无单独 `NtUserDestroyWindow` syscall 包装在本表 |
| `post_message` | **`PostMessageA`** | 不创建窗口、不分配表面 |
| `get_message` | **`csrFillOneMessageForLpc`**（内部 `peekMessageAForThread`）；负载 **20–24 须为非零线程 id**（`csr_lpc_policy.resolveGetMessageClientTid`，禁止 `0` 回退 `pid`） | 与 `NtUserGetMessage` 共享队列模型但 **非** 同一 syscall 路径 |

固定偏移与 `csr_lpc_policy.zig` / **`win32k_api_semantics_host`** 一致；`min>max`（且非 `0,0`）在 user32 路径拒绝（`ERROR_INVALID_PARAMETER` / syscall `STATUS_INVALID_PARAMETER`）。

### 3.5 `CreateWindowEx` / `register_window` 与合成表面不变量（问题五）

- **`compositor_surface_id == no_compositor_surface`**：`ensureCompositorSurface` / `CreateWindowEx` 仅在 `dwm_compositor` 已初始化且 `createSurface` 成功时写入有效 id；失败则保持无表面（壳层仍可有 HWND）。
- **销毁**：**仅** `detachCompositorSurface`（`DestroyWindow`）释放 `dwm_compositor` 槽位；禁止在 `is_valid == false` 之后保留非 `no_compositor_surface` 的 id。
- **双入口一致**：`CreateWindowEx` 与 `onCsrssRegisterGuiWindow` 均通过 **`ensureCompositorSurface`** 分配（见 `user32.zig`），LPC 路径在表面已存在时仍 **`notifyCompositorWindowGeometry`** 以刷新脏区。

## 4. Surface 标志语义对照

实现对照见 [`src/config/dwm_surface_spec.zig`](../../src/config/dwm_surface_spec.zig) 表头注释。

**内核** `RedirectedSurface.flags`：`topmost`、`layered`、`popup`、`child`、`has_caption`、`dwm_blur_behind`、`dwm_ncrendering`、`snap_target`。

**用户** `SurfaceFlags`：`has_alpha`、`needs_shadow`、`is_visible`、`is_opaque`、`needs_blur`、`is_glass`、`is_cursor`、`is_desktop`。

映射原则：`dwm_blur_behind` ↔ `is_glass` + `needs_blur`；`dwm_ncrendering` ↔ 非客户区与 `needs_shadow` / 窗口装饰协同。

**编译期防漂移**：[`aero_flag_mapping.zig`](../../src/config/aero_flag_mapping.zig) 内含 `KernelCompositorSurfaceFlags` 字段序与 `kernelToUserland` 语义 `comptime` 断言；用户态 [`compositor.zig`](../../src/desktop/aero/src/compositor.zig) 在文件末尾对 `SurfaceFlags` 调用 `assertUserlandSurfaceFlagsLayout`。

**颜色跨界（canonical）**：**内核合成主路径**以 [`color_nt61.zig`](../../src/config/color_nt61.zig) 的 **`KernelBgr888Low24`** 为唯一打包语义（与 `drivers/video/desktop/theme.zig` 的 `rgb` 一致）；**用户态 / 注册表 / WM 载荷**以 **`ColorrefLow24`** 进出，**必须**经该模块命名转换函数。**不**将「全路径统一 ARGB u32」作为当前里程碑；上述 `KernelBgr888Low24` / `ColorrefLow24` 为当前唯一收口。

**验收（防双轨）**：在 `nt61_aero_defaults.zig` 中仅修改 `KernelDwm.glass_tint_color`（或任一已由 `UserShellDwm` 镜像的字段）而**不**同步更新 `UserShellDwm` 对应别名时，应 **编译失败**（`comptime` 断言）；并 bump `compositor_config_epoch`。

## 5. DWM 最小内部 API 子集（验收参考）

对照 MSDN「Developing for the Desktop Window Manager」概念，内部模块应对齐以下能力（名称可为 Zig 函数，不必导出 DLL）：

- 将玻璃延伸到客户区（等价 `DwmExtendFrameIntoClientArea` 策略）
- BlurBehind 区域（等价 `DwmEnableBlurBehindWindow`）
- 合成启用/禁用（等价 `DwmIsCompositionEnabled` / 禁用回退路径）
- 缩略图 / Flip3D：**内核已实现 CPU 近似**（`display.flip3d_overlay_active`、`dwm_compositor` 每表面缩略缓冲）；用户态 **`compositor.flip3d_preview_enabled`** 表示宿主侧是否参与二次投影预览，与内核 Flip3D 覆盖层语义对齐（均为「预览」非完整 D3D Flip3D）。

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

- **`nt61_aero_defaults.KernelDwm.blur_budget_pixel_passes_per_frame`**：每帧 `display.renderDesktopFrameEx` / `renderAeroDesktop` 入口重置；`dwm.zig` 内每次 `boxBlurRect` 按 `宽×高×pass` 扣减（与 [`dwm_blur_budget.zig`](../../src/config/dwm_blur_budget.zig) 同源公式，`zig build test` → **dwm_blur_budget_host**），耗尽则本帧后续 blur 跳过，仍保留 tint 与高光。
- **`-Ddwm_blur_stats=true`**：`renderDesktopFrameEx` / `renderAeroDesktop` 末尾 `dwm.flushBlurFrameStatsDebug` 打 **`klog.debug`** 一行（`box_blur_calls` / `budget_denials` / `tint_only_calls`），与 `-Ddesktop_bisect` 分帧取证配合；详见 [SOFTWARE_COMPOSITOR_WDDM.md](SOFTWARE_COMPOSITOR_WDDM.md)。
- **`blur_max_single_rect_pixels` / `blur_max_rect_calls_per_frame`**：单块面积与每帧调用次数硬顶，避免前几趟大矩形占满整帧（高分 GOP / LoongArch UEFI 下尤关键）。
- **`blur_resolution_downgrade_pixel_threshold`** 与 **`glass_blur_radius_hd_cap` / `glass_blur_passes_hd_cap`**：帧像素数超阈值时自动下调半径与遍数。
- **`glass_blur_radius_loongarch_cap` / `glass_blur_passes_loongarch_cap`**：由 **`dwm.applyPlatformAndResolutionTuning`** 在 `display.initAeroDwm`（`fb` 已就绪）时与分辨率策略一并应用到 `dwm`/`dwm_config`/`material`。
- **`taskbar_blur_radius_cap`**：限制任务栏全宽条带的模糊半径，减轻条带成本。
- **`renderGlassTintOnly`**：无 `boxBlur`，用于拖窗标题栏、右键菜单、开始菜单首帧大面板等，优先帧率。
- **壳层打开时** `setGlassLiteBlurEnabled(true)` 仍生效；**任务栏**在上下文菜单 / 开始菜单 / 托盘飞出打开时额外走 **`renderGlassTintOnly`**（`display.renderDesktopAeroTaskbar`），避免与场景模糊叠乘。
- **取证**：`framebuffer.logDesktopGopSummary()` 在 `initDesktopMode` 打 **`DesktopGOP:`**；`-Ddesktop_bisect=true` 时在 `main.zig` 桌面循环输出 **`renderDesktopFrameEx` 前后 scheduler tick 差** 与 `fb_w`；与 `drivers/input/mouse_debug.zig` 联用时关注开始菜单打开场景下 **`startmenu_partial`** 占比告警阈值（回归局部重绘是否退化成全场景）。
- **Flip3D / Alt+Tab（`display.flip3d_overlay_active`）**：`arch.consumeFlip3dHotkey`（x86_64 → `keyboard.consumeFlip3dHotkey`）与 `display` 内切换覆盖层消费 **同一热键**；首帧打开置 `flip3d_needs_scene_refresh=true` 以刷新冻结前的壁纸/窗景，随后在 `flip3d_needs_scene_refresh==false` 时 `renderSceneWithoutSoftwareCursorFlip3dAware` **冻结背景采样**，仅叠 Flip3D 层与光标以降低每帧 CPU。卡片缩略数据源：`dwm_compositor.collectShellWindowSurfaceIds`（多 surface，有数量与 z 过滤）及每表面 `refreshSurfaceThumbFromFramebuffer`（2×2 盒滤）；任务栏 Explorer 按钮悬停仍走 `maybeRefreshExplorerTaskbarThumb` 的帧缓冲采样路径（与 HWND→surface 映射说明见契约矩阵 §4.1）。

调参时只改 `nt61_aero_defaults.zig`（单一数值源），避免与 `display.initAeroDwm` 漂移。

## 9. 参考链接

- [The Desktop Window Manager (Microsoft Learn)](https://learn.microsoft.com/en-us/windows/win32/learnwin32/the-desktop-window-manager)
- [DirectComposition — Architecture and components](https://learn.microsoft.com/en-us/windows/win32/directcomp/architecture-and-components)
- [Window Stations and Desktops](https://learn.microsoft.com/windows/win32/winstation/window-stations-and-desktops)（会话/桌面公开概念）
