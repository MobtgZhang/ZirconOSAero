# Aero（NT 6.1）渲染参数与实现要点

本文记录 **内核帧缓冲路径**（`src/drivers/video/renderer_aero.zig`、`dwm.zig`、`display.zig`）中与 Windows 7 Aero 氛围对齐的默认参数及托盘布局。

**单一数值源**：`src/config/zircon_aero_defaults.zig`（内核与用户态 Aero 主题共用）。架构与职责见 [DesktopManagerSpec.md](DesktopManagerSpec.md)。

## DWM 玻璃（`renderGlassEffect`）

| 参数 | 当前默认（`initAeroDwm`） | 说明 |
|------|---------------------------|------|
| `glass_blur_radius` | 6 | 标题栏/面板盒式模糊半径 |
| `glass_blur_passes` | 2 | 逼近高斯的遍数 |
| `glass_tint_opacity` | 62 | 标题栏染色强度 |
| `glass_taskbar_tint_opacity` | 96 | 任务栏略更不透明（与当前 `initAeroDwm` 一致） |
| `specular_intensity` | 42 | 顶区镜面高光 |

任务栏在 `dwm.zig` 内使用 **两遍较小半径** 的 `boxBlurRect`，在性能与观感间折中。

## Harmony 壁纸

- 垂直渐变基底 + 两层光晕（bloom）+ **四边暗角**（vignette）。
- 拖动窗口时的脏区修补见 `patchHarmonyWallpaperRegion` / `patchHarmonyRegion`，与全屏壁纸层保持一致。

## 任务栏托盘

- 布局见 `aero_tray.zig`：网络 → **媒体占位（browser 图标）** → 设置 → 「显示隐藏的图标」箭头 → 时钟。
- 音量专用位图可在未来扩展 `IconId` 后替换中间格图标。

## 用户态 Aero 库（`src/desktop/aero`）

- `compositor.zig` 的 **局部合成** 会先以桌面底色填充所有脏矩形之 **并集**，再按层绘制，避免 clip 合成残留。

更完整的阶段划分见 [PROCESS_NT61.md](PROCESS_NT61.md)。

## 指针与输入（全架构）

- **光标绘制**：`display.renderDesktopFrame` 每帧从 `drivers/input/mouse.zig` 同步 `cursor_x` / `cursor_y`，**不依赖 x86**；VirtIO-Input 与 PS/2 共用同一逻辑坐标。
- **QEMU 建议**：非 x86 或无可用时，为虚拟机添加 **`-device virtio-mouse-pci`**（与 `virtio_input_pci.zig` 对齐）；x86 仍可使用默认 PS/2 或同上 VirtIO。
- **壳层图标 ID**：`icons.zig` 中 `IconId` 与 Aero `resource_loader` 注册 ID **1–25** 一致；帧缓冲 16×16 字形仍仅对 **1–13** 有独立像素，其余通过 `bitmapIconId` 映射。矢量源为 `src/desktop/aero/resources/icons/*.svg`；宿主 PE 资源号见 `resources/win32/ICON_RESOURCE_IDS.md`（101–125）。总述与 Win32 兼容说明见 [NT61_ShellIcons.md](NT61_ShellIcons.md)。
