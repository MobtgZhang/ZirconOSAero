# ZirconOS Aero 桌面管理器 — 架构设计

## 一、整体分层架构

ZirconOS Aero 桌面管理器采用分层架构设计，参考 Windows 7 DWM 的核心理念：**每个窗口独立渲染到显存表面，合成器统一合成输出**。

```
┌─────────────────────────────────────────────────────┐
│                 用户态应用程序                        │
│           (Shell 命令 / 窗口应用)                     │
├─────────────────────────────────────────────────────┤
│           ZirconOS Aero Shell (shell.zig)            │
│  ┌───────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ 开始菜单    │  │ 任务栏    │  │ 桌面 & 图标管理   │  │
│  │ startmenu  │  │ taskbar  │  │ desktop          │  │
│  └───────────┘  └──────────┘  └──────────────────┘  │
├─────────────────────────────────────────────────────┤
│           DWM 合成器 (compositor.zig)                │
│  ┌──────────────┐  ┌─────────────────────────────┐  │
│  │  Surface 管理  │  │  Z-Order 排序 & 损坏区域追踪  │  │
│  └──────────────┘  └─────────────────────────────┘  │
│  ┌──────────────┐  ┌─────────────────────────────┐  │
│  │  光标独立图层  │  │  VSync 帧同步               │  │
│  └──────────────┘  └─────────────────────────────┘  │
├─────────────────────────────────────────────────────┤
│           渲染抽象层 (renderer.zig)                   │
│     fillRect / drawGradient / drawBlur / blitSurface │
├─────────────────────────────────────────────────────┤
│           输入处理层 (input.zig)                      │
│     子像素插值 / 热键注册 / 鼠标状态追踪               │
├─────────────────────────────────────────────────────┤
│           主题定义 (theme.zig)                        │
│     颜色方案 / 尺寸常量 / 玻璃参数 / 字体配置          │
├─────────────────────────────────────────────────────┤
│           内核帧缓冲驱动                              │
│     framebuffer.zig / display.zig / mouse.zig        │
└─────────────────────────────────────────────────────┘
```

## 二、模块职责

### 2.1 Shell（shell.zig）

Shell 是桌面环境的主控模块，负责协调所有桌面组件的生命周期和事件分发。

**状态机：**
```
not_started → initializing → welcome_screen → loading_desktop → desktop_active
                                                    ↑                ↓
                                              welcome_screen ← logging_off
                                                    ↑                ↓
                                                  locked    ←     locking
```

**核心功能：**
- 初始化所有子系统（theme, winlogon, desktop, taskbar, startmenu, compositor, input）
- 事件路由：根据当前状态将鼠标/键盘事件分发到对应的处理函数
- 窗口管理：注册/移除/激活窗口，维护窗口 Z-Order
- 与合成器集成：每个窗口创建对应的 Surface，光标位置实时同步

### 2.2 合成器（compositor.zig）

参考 DWM 设计，实现离屏表面合成。

**核心概念：**
- **Surface**：每个窗口、桌面背景和光标各自拥有独立的 Surface
- **Z-Order 排序**：合成时按 Z 值从低到高绘制，确保正确的层叠关系
- **损坏区域追踪（Damage Tracking）**：仅重绘变化的区域，减少 GPU 开销
- **光标独立图层（Cursor Layer）**：光标移动不触发全场景重绘，实现极低延迟的光标响应
- **VSync 同步**：帧呈现与显示器刷新率对齐，避免画面撕裂

**合成流程：**
```
每帧刻（VSync）:
  1. 检查是否需要重绘（needsRedraw）
  2. 如果只有光标移动 → 执行 composeCursorOnly()（极快路径）
  3. 如果有场景变化 → 排序 Surface → composeFull/composePartial
  4. 清除所有 Surface 的损坏标记
  5. flushRender() → 提交到帧缓冲
```

### 2.3 渲染器（renderer.zig）

提供平台无关的绘图接口，通过 `RenderOps` 函数指针表实现后端可替换。

**关键接口：**
| 函数 | 用途 |
|------|------|
| `fillRect` | 填充矩形区域 |
| `drawGradient` | 线性渐变（水平/垂直） |
| `drawBlur` | 高斯模糊（Glass 效果核心） |
| `drawRoundRect` | 圆角矩形 |
| `blitSurface` | 将 Surface 内容合成到目标位置 |
| `fillRectAlpha` | 带 Alpha 的矩形填充 |
| `drawShadow` | Aero 风格 8px 软阴影 |
| `drawGlassSurface` | 完整的 Glass 表面渲染（模糊 + 染色叠加） |

### 2.4 输入处理（input.zig）

**丝滑鼠标实现 — 详见 [smooth-cursor.md](smooth-cursor.md)**

- 子像素精度追踪（256 倍精度）
- 线性插值平滑（lerp_factor 可调）
- 速度追踪与阻尼
- 全局热键注册与分发

### 2.5 主题系统（theme.zig）

定义 4 种配色方案的完整颜色集，每种方案包含 50+ 个颜色值：

| 方案 | 风格 |
|------|------|
| Zircon Blue | 蓝色系玻璃效果（默认） |
| Zircon Graphite | 石墨灰色系 |
| Zircon Aurora | 青绿极光色系 |
| High Contrast | 无障碍高对比度 |

**Glass 参数：**
- `blur_radius` — 模糊半径（默认 12）
- `opacity` — 整体透明度（默认 180/255）
- `tint_color` — 染色颜色
- `tint_opacity` — 染色透明度
- `reflection_strength` — 反射高光强度

### 2.6 桌面组件

| 模块 | 文件 | 功能 |
|------|------|------|
| 桌面管理 | `desktop.zig` | 图标网格布局、壁纸管理、右键菜单 |
| 任务栏 | `taskbar.zig` | 玻璃任务栏、Orb 按钮、通知区域、时钟 |
| 开始菜单 | `startmenu.zig` | 双栏布局、搜索框、固定/最近程序 |
| 窗口装饰 | `window_decorator.zig` | Glass 标题栏、圆角、控制按钮、HitTest |
| 控件库 | `controls.zig` | 按钮、文本框、复选框、进度条、列表框 |
| 登录管理 | `winlogon.zig` | 用户认证、会话管理、欢迎屏幕 |

## 三、数据流

### 鼠标事件流
```
PS/2 IRQ12 → mouse.zig (内核驱动, 带插值)
  → display.zig (平滑光标更新)
    → shell.zig (事件路由)
      → input.zig (子像素插值)
        → compositor.zig (光标图层更新)
          → renderer.zig (帧缓冲输出)
```

### 窗口创建流
```
应用请求创建窗口
  → shell.registerWindow()
    → window_decorator.layoutButtons() (计算装饰尺寸)
    → compositor.createSurface() (分配离屏表面)
    → taskbar.addTaskButton() (添加任务栏按钮)
```

## 四、设计原则

1. **分离关注点**：每个模块职责单一，通过明确的接口交互
2. **零分配**：所有数据结构使用固定大小数组，无堆内存分配
3. **无依赖**：Aero 库不依赖 `std`（`main.zig` 测试入口除外）
4. **可替换后端**：渲染器通过函数指针表实现，可对接不同的图形后端
5. **平滑优先**：鼠标移动通过多层插值确保视觉丝滑
