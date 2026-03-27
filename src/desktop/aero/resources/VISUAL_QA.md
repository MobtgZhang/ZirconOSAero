# Aero 壳层视觉验收基线

在目标分辨率（建议 1920×1200 或与主壁纸 `zircon_harmony_win7.svg` 一致）下截取以下四张，用于回归对比。路径可放在 `docs/cn/screenshots/aero/`（若仓库忽略二进制，仅本地保留亦可）。

| # | 场景 | 检查要点 |
|---|------|----------|
| 1 | 桌面图标网格 | 9 列竖排常用项（Computer/Recycle/Documents/Network 等）+ 资源库 17 类图标 ID 一致；快捷方式角标可读 |
| 2 | 任务栏 | 玻璃条、缩略按钮、Start Orb 与主题 accent 协调 |
| 3 | 「开始」菜单 | 左右列图标与 ID 映射正确（含计算器/记事本/媒体等） |
| 4 | 托盘区 | 托盘图标与壁纸对比度足够，不被 Harmony 背景吞没 |
| 5 | 非 x86（如 AArch64）+ VirtIO 鼠标 | QEMU 增加 `-device virtio-mouse-pci`（或等价）；指针随移动更新，开始菜单项可 hover |
| 6 | ZBM 操作系统菜单 | 方向键 / PageUp·PageDown / Home·End / `j`·`k`·`w`·`s` / 数字键 `1`–`8` 可改选；串口-only 固件可能无 ConIn，属固件限制 |
| 7 | 壁纸预设 | **Ctrl+Alt+F9** 循环 12 套程序化背景（与 `resource_loader` 壁纸条目对应）；首帧仍为快速渐变 |
| 8 | 光标形态 | 开始菜单项上为手形（箭头位图）、Explorer 地址栏为竖线光标、拖标题栏为四向移动 |

**构建检查**：`resource_loader` 中 `addIcon` / `addCursor` / `addThemeFile` / `addSoundScheme` / `addBrandAsset` 路径与 `resources/` 内文件名一致，`zig build` 无缺失嵌入路径。

**内核壁纸**：QEMU 默认背景来自 `renderer_aero.zig` 的 `renderHarmonyWallpaper` 等程序化绘制，与 `wallpapers/*.svg` 为概念对齐而非像素一致。

**桌面右键菜单**（帧缓冲）：`display.zig` `renderContextMenu` 使用主题 `titlebar_text`（黑）于浅底，避免白字低对比。

**图标一致**：内核 `src/drivers/video/icons.zig` 中 `IconId` 数值与 `resource_loader` / `DESIGN.md` 内置 ID（1–17）一致；帧缓冲回退位图与 Aero SVG 同源路径。
