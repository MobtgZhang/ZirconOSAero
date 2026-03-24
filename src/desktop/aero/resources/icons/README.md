# ZirconOS Aero Icons

原创图标，与 `resource_loader.zig` 注册 ID 一致。统一规格见上级目录 **[DESIGN.md](../DESIGN.md)**。

## 内置 ID（`registerBuiltinIcons`）

| ID | 文件 | 说明 |
|----|------|------|
| 1 | `computer.svg` | 此电脑 / 显示器 |
| 2 | `documents.svg` | 文档 |
| 3 | `recycle_bin.svg` | 回收站 |
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

## 辅助资源（未按 ID 注册，供文档或其它壳层引用）

| 文件 | 说明 |
|------|------|
| `file.svg` | 通用文件 |
| `user.svg` | 用户头像 |
| `lock.svg` | 锁定 |
| `shutdown.svg` | 关机 |

## 色板（摘要）

与 `theme.zig` `scheme_blue.accent`（`#3D8ED8`）及青色系 `#2ABFBF` 对齐；描边多用 `#156575`。

## 技术

- 格式：SVG，`viewBox="0 0 48 48"`
- 无外链资源

## 版权

Copyright (C) 2024-2026 ZirconOS Project — LGPL-2.1。非微软资产衍生。
