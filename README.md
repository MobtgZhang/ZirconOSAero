# ZirconOSAero - Windows Vista/7 Aero 桌面主题

## 概述

ZirconOSAero 是 ZirconOS 操作系统的 **Windows Aero** 风格桌面环境实现。
Aero（Authentic, Energetic, Reflective, and Open）是 Windows Vista 引入、
Windows 7 完善的视觉主题，以其标志性的毛玻璃透明效果和精致的动画闻名于世。

本模块参考 [ReactOS](https://github.com/reactos/reactos) 的桌面架构设计，
目标是实现完整的 Aero 风格桌面 Shell、窗口装饰、任务栏和 Flip 3D 窗口切换。

## 设计风格

### Aero 核心视觉特征

| 特征 | 说明 |
|------|------|
| **毛玻璃效果 (Glass)** | 窗口标题栏和边框半透明，背景高斯模糊 + 反光 |
| **Aero Peek** | 鼠标悬停任务栏预览窗口缩略图（Win7） |
| **Aero Snap** | 窗口拖拽到屏幕边缘自动半屏/全屏（Win7） |
| **Flip 3D** | Win+Tab 3D 立体窗口切换动画 |
| **精致阴影** | 窗口四周细腻的投影阴影 |
| **Segoe UI 字体** | 系统默认使用 Segoe UI 9pt |

### 配色方案

| 元素 | Vista 默认 | Windows 7 默认 |
|------|-----------|---------------|
| 窗口边框 | 半透明深蓝 `rgba(0,0,0,0.5)` + 模糊 | 半透明蓝 `rgba(116,184,252,0.5)` + 模糊 |
| 标题栏文字 | 白色 + 发光阴影 | 黑色 / 白色（自适应） |
| 任务栏 | 深色半透明玻璃 | 蓝色半透明玻璃 |
| 开始按钮 | 圆形 Windows 标志 (Vista) | 圆形发光球体 (Win7) |
| 高亮色 | 蓝色 `#0078D4` | 蓝色 `#4580C4` |

### 与 Luna 的关键差异

- **透明度**：Luna 为纯色渐变，Aero 为半透明毛玻璃
- **窗口边框**：Luna 为蓝色粗边框，Aero 为透明薄边框 + 阴影
- **控件风格**：Luna 为 3D 凸起按钮，Aero 为扁平化玻璃按钮
- **任务栏**：Luna 为蓝色渐变实心，Aero 为深色透明玻璃
- **开始菜单**：Luna 为双栏 XP 风格，Aero 为 Vista/7 圆角搜索菜单
- **字体**：Luna 用 Tahoma 8pt，Aero 用 Segoe UI 9pt

## 模块架构

```
ZirconOSAero/
├── src/
│   ├── root.zig              # 库入口，导出所有公共模块
│   ├── main.zig              # 可执行入口 / 集成测试
│   ├── theme.zig             # Aero 主题定义（颜色、透明度、模糊参数）
│   ├── winlogon.zig          # 用户登录管理（Vista/7 风格登录界面）
│   ├── desktop.zig           # 桌面管理器（壁纸、Gadgets 侧边栏）
│   ├── taskbar.zig           # 任务栏（Aero Peek 预览、跳转列表）
│   ├── startmenu.zig         # 开始菜单（搜索框、所有程序、电源按钮）
│   ├── window_decorator.zig  # 窗口装饰器（毛玻璃标题栏、Aero Snap）
│   ├── shell.zig             # 桌面 Shell 主程序（explorer.exe 风格）
│   └── controls.zig          # Aero 风格控件（玻璃按钮、进度条动画）
├── resources/
│   ├── wallpapers/           # 桌面壁纸
│   ├── icons/                # 系统图标（拟物化风格）
│   ├── ui/                   # UI 组件素材
│   ├── cursors/              # 鼠标光标（Aero 风格）
│   └── MANIFEST.md           # 资源清单
├── build.zig
├── build.zig.zon
└── README.md
```

## 计划实现的组件

### WinLogon（用户登录）
- Vista 风格：全屏背景模糊 + 中央用户选择面板
- Win7 风格：用户头像列表 + 密码输入框 + 辅助功能按钮

### Desktop（桌面管理器）
- 壁纸管理（默认 Vista 极光 / Win7 蓝色窗口壁纸）
- Windows Sidebar / Gadgets 侧边栏（Vista）
- 桌面图标（拟物化风格）
- 右键菜单（圆角 + 阴影）

### Taskbar（任务栏）
- **Vista 风格**：快速启动栏 + 任务按钮 + 系统托盘
- **Win7 风格**：大图标固定任务栏 + Aero Peek + 跳转列表
- 半透明玻璃材质
- Show Desktop 按钮（右下角竖条）

### Start Menu（开始菜单）
- 搜索框（底部即时搜索）
- 程序列表（左栏可滚动）
- 系统链接（右栏：文档、图片、计算机、控制面板）
- 电源按钮（关机/睡眠/重启）

### Window Decorator（窗口装饰器）
- 毛玻璃标题栏（高斯模糊 + 半透明叠加）
- 标题栏按钮（最小化/最大化/关闭，悬停发光效果）
- Aero Snap（拖拽到屏幕边缘自动吸附）
- 窗口阴影（四周柔和投影）

### Controls（UI 控件）
- 玻璃风格按钮（悬停发光、按下内凹）
- 进度条（带动画流光效果）
- 滚动条（透明薄型）
- 命令链接按钮（Vista 特色控件）

## 与主系统集成

ZirconOSAero 通过以下内核子系统接口工作：

1. **user32.zig** — 窗口管理 API、消息队列
2. **gdi32.zig** — 绘图 API（需扩展 alpha 混合和模糊支持）
3. **subsystem.zig** (csrss) — 窗口站和桌面管理
4. **framebuffer.zig** — 帧缓冲区显示驱动

### 配置

在 `config/desktop.conf` 中选择 Aero 主题：

```ini
[desktop]
theme = aero
color_scheme = default    # default | blue | graphite
shell = explorer
```

## 构建

```bash
cd 3rdparty/ZirconOSAero
zig build
zig build test
```

## 开发状态

当前为项目框架阶段，计划按以下顺序实现：

1. `theme.zig` — Aero 配色和尺寸常量
2. `window_decorator.zig` — 毛玻璃标题栏效果
3. `taskbar.zig` — 透明任务栏
4. `startmenu.zig` — Vista/7 风格开始菜单
5. `desktop.zig` — 桌面管理器
6. `controls.zig` — Aero 风格控件
7. `winlogon.zig` — 登录界面
8. `shell.zig` — Shell 集成

## 参考

- [ReactOS](https://github.com/reactos/reactos) — 开源 Windows 兼容操作系统
- Windows Vista / Windows 7 Aero 视觉规范
- [DWM (Desktop Window Manager)](https://learn.microsoft.com/en-us/windows/win32/dwm/dwm-overview) — 桌面窗口管理器文档
- Microsoft UX Guidelines for Windows Vista/7
