# ZirconOS Aero Icons

原创图标，与 `resource_loader.zig` 中 `registerBuiltinIcons` 的 ID 一致。统一规格见上级目录 **[DESIGN.md](../DESIGN.md)**。

## 内置 ID（1–25）

| ID | 文件 | 说明 |
|----|------|------|
| 1 | `computer.svg` | 此电脑 / 显示器 |
| 2 | `documents.svg` | 文档 |
| 3 | `recycle_bin.svg` | 回收站（空） |
| 4 | `terminal.svg` | 终端 |
| 5 | `network.svg` | 网络 |
| 6 | `browser.svg` | 浏览器 |
| 7 | `settings.svg` | 设置 |
| 8 | `calculator.svg` | 计算器 |
| 9 | `text_editor.svg` | 文本编辑器 / 记事本 |
| 10 | `pictures.svg` | 图片 / 画图占位 |
| 11 | `music.svg` | 媒体 / WMP 占位 |
| 12 | `folder.svg` | 文件夹 |
| 13 | `control_panel.svg` | 控制面板 |
| 14 | `file.svg` | 通用文件 |
| 15 | `user.svg` | 用户头像 |
| 16 | `lock.svg` | 锁定 |
| 17 | `shutdown.svg` | 关机 |
| 18 | `recycle_bin_full.svg` | 回收站（满） |
| 19 | `drive_fixed.svg` | 本地磁盘 |
| 20 | `drive_removable.svg` | 可移动磁盘 / U 盘 |
| 21 | `drive_optical.svg` | 光盘 |
| 22 | `printer.svg` | 打印机 |
| 23 | `info.svg` | 信息（shell 状态） |
| 24 | `warning.svg` | 警告 |
| 25 | `error.svg` | 错误 / 严重（Zig `IconId` / `PeIconId` 字段名为 `err`，`error` 为语言保留字） |

内核帧缓冲绘制时，ID **14–25** 在 `icons.zig` 的 `bitmapIconId` 中映射到 **1–13** 的 16×16 字形；完整矢量仍以 SVG 为准。

PE 资源 DLL 中的 **101–125** 与上表顺序一致，见 [`../win32/ICON_RESOURCE_IDS.md`](../win32/ICON_RESOURCE_IDS.md)。

## 色板（摘要）

与 `theme.zig` `scheme_blue.accent`（`#3D8ED8`）及青色系 `#2ABFBF` 对齐；描边多用 `#156575`。

## 技术

- 格式：SVG，`viewBox="0 0 48 48"`
- 无外链资源

## 版权

Copyright (C) 2024-2026 ZirconOS Project — LGPL-2.1。非微软资产衍生。
