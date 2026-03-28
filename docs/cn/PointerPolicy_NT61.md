# 指针策略与 NT 6.1 用户期望对照（clean-room）

本文将 **Windows 7 时代控制面板 / 注册表中常见的指针相关设置**（公开文档与离线 `desktop-src` 中 *Mouse*、*Control Panel* 等主题的**行为描述**）映射到本仓库实现字段，便于验收与调参。**不**复制任何 Windows 源码；算法为自研。

## 1. 概念映射表

| 用户可见概念（公开文档/注册表常见键） | 本仓库实现 | 模块 |
|--------------------------------------|------------|------|
| 指针速度（Sensitivity） | `MouseState.sensitivity`（N/10 缩放） | [`src/drivers/input/mouse.zig`](../../src/drivers/input/mouse.zig) |
| 提高指针精确度 / 加速（Enhance pointer precision） | `acceleration_enabled`、`acceleration_threshold`、`acceleration_curve` | 同上 |
| 指针轨迹平滑（部分 SKU 文案） | `smoothing_enabled`、`prev_dx/dy` 混合 | 同上 |
| 显示指针位置（Ctrl 键显示轨迹等） | 未实现；属 Shell 行为 | — |
| 双击速度、滚动行数 | 属窗口消息/Shell，非内核指针驱动 | `user32`/Shell 长期项 |

注册表侧常见路径（**仅作索引**，值以你环境为准）：`HKCU\Control Panel\Mouse` 下的 **Sensitivity**、**MouseSpeed**、**MouseThreshold1/2**、**MouseSensitivity** 等与上表概念对应；本内核当前 **未**从这些键自动加载，默认以 `mouse.zig` 结构体初值及 `setSensitivity` / `setAcceleration` / `setSmoothing` 为准。

## 2. 合成与刷新（非 desktop-src 内核细节）

- **子步插值**：`interpolation_enabled` / `interpolation_steps`（默认开启、3 步）减轻单 tick 内大跳变；与 [`display.renderDesktopFrameEx`](../../src/drivers/video/display.zig) 中 `isInterpolating()` 协同。
- **单轮合并**：`input_hub.pollAll` 包裹 `beginMotionCoalesce` / `endMotionCoalesce`，同一轮内多条 REL 合并后再缩放入队。
- **壳层重绘 vs 光标层**：[`display.handleMouseMove`](../../src/drivers/video/display.zig) 返回 `MouseMovePaintHint`：`needs_full_scene`（开始菜单项高亮、拖动窗体位移等）走整壁纸+壳层；`needs_caption_chrome_only` 仅调用 [`renderer_aero.redrawCaptionBandsOnly`](../../src/drivers/video/renderer_aero.zig) 重画 Explorer/任务管理器**标题栏带**（最小化/最大化/关闭热态），避免整屏；**仅** `desktop_cursor_kind` 变化走 `cursor_plane` 快速路径。
- **地址栏 I-beam 迟滞**：`pointInExplorerAddressBarEx` / `pointInExplorerAddressBarHysteresis`（约 2px）减少箭头/I-beam 在边界上的抖动。
- **标题栏三键迟滞**：[`hitTestAeroCaptionButtonsHysteresis`](../../src/drivers/video/display.zig)（约 2px 粘性区）减少三键边界上悬停状态翻转频率。

### 2.1 非客户区热跟踪（desktop-src 行为级，无抄码）

Win32 文档中，非客户区鼠标移动与按钮 **hot tracking** 通常对应**窗口局部**更新，而非使整个桌面无效。本机用 **`needs_caption_chrome_only` + 标题栏带重绘** 逼近该预期；**不**声称与 CSRSS/`DefWindowProc` 内部实现一致。对照阅读：`inputdev/wm-ncmousemove.md`、`wm-ncmousehover.md`。

## 3. Win32 输入文档对照（desktop-src，行为级 D1–D5）

离线镜像路径示例：`references/win32/desktop-src`。下表仅对齐**公开文档描述的行为语义**，实现为本仓库独立代码，不复制任何示例源码。

| ID | 主题 | 建议阅读的 md 路径（镜像内） | 与本项目的关系 |
|----|------|-------------------------------|----------------|
| D1 | 鼠标移动与共合 | `inputdev/wm-mousemove.md`、`LearnWin32/mouse-movement.md` | 高频移动可在系统侧合并；本机对应 REL 合并、插值与 VirtIO 排空，见 `mouse.zig` / `virtio_input_pci.zig`。 |
| D2 | 非客户区 vs 客户区 | `inputdev/wm-ncmousemove.md`、`wm-ncmousehover.md` | 标题栏/客户区命中与将来 `WM_NC*` 消息语义一致；`hitTestAeroCaptionButtons` / `hitTestAeroCaptionButtonsHysteresis` 与 `needs_caption_chrome_only` 合成路径对齐「NC 热态局部刷新」预期。 |
| D3 | 光标与 WM_SETCURSOR | `inputdev/about-mouse-input.md`、`mouse-input-functions.md`（索引） | Win32 下由窗口过程与默认处理决定光标；本机 **合成器** 在 `updateDesktopCursorKind` 中根据命中设置 `desktop_cursor_kind`，等价于「谁拥有输入命中谁设定指针形态」。 |
| D4 | 悬停与离开 | `inputdev/wm-mousehover.md`、`wm-mouseleave.md` | 文档中的 HOVER 时间/矩形；开始菜单项高亮仍走 **`needs_full_scene`**（整屏重绘），局部菜单 blit 为 backlog；标题栏三键热态已走 `caption_partial`。 |
| D5 | 滚轮与顺序 | `inputdev/wm-mousewheel.md` | 滚轮应触发内容更新；本机 `main` 中 `event.scroll != 0` → `needs_ui_paint`，避免与纯指针移动混淆。 |

## 4. 参考阅读（合法来源）

- Microsoft Learn：鼠标、指针、辅助功能相关 **用户文档**（行为级）。
- VirtIO：`virtio-input` 设备规范（事件编码）。
- 本仓库：[AeroDesktopRuntime.md](AeroDesktopRuntime.md) 输入路径与 `MOUSE_DEBUG` 字段说明（含 `render_full` / `render_cap` / `render_fast`，`-Dmouse_debug=true`）。
