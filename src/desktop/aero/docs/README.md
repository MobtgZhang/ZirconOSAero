# ZirconOS Aero 桌面管理器文档

本目录包含 ZirconOS Aero 桌面管理器的架构文档和设计说明。

## 文档索引

| 文档 | 说明 |
|------|------|
| [architecture.md](architecture.md) | 整体架构设计与分层结构 |
| [dwm-compositor.md](dwm-compositor.md) | DWM 合成器技术详解 |
| [smooth-cursor.md](smooth-cursor.md) | 丝滑鼠标移动实现原理 |

## 概述

ZirconOS Aero 是 ZirconOS 操作系统的玻璃效果桌面环境主题库。它参考了 Windows 7 DWM（Desktop Window Manager）的架构理念，实现了独立的窗口合成、玻璃透明效果、圆角窗口装饰以及丝滑的鼠标移动体验。

### 核心特性

- **DWM 合成引擎** — 每个窗口渲染到独立表面，合成器统一合成输出
- **Aero Glass 效果** — 玻璃透明、高斯模糊、渐变标题栏
- **丝滑鼠标移动** — 子像素插值、线性平滑、VSync 同步
- **双栏开始菜单** — 搜索框、固定程序、系统链接
- **玻璃任务栏** — Orb 开始按钮、任务缩略图预览
- **主题配色系统** — Zircon Blue、Graphite、Aurora、High Contrast

### 版本

当前版本：v0.2.0
