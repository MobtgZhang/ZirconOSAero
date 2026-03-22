# ZirconOS Aero

**ZirconOS Aero 毛玻璃桌面主题** — ZirconOS 桌面环境的 Aero 视觉风格实现。
受经典毛玻璃 DWM 合成设计启发，完全原创实现。兼容 NT6 内核模式。

## 特性

- **DWM 合成器**：多遍 Box Blur 模拟高斯模糊（Aero Glass 毛玻璃效果）
- **透明边框**：窗口标题栏、任务栏支持半透明玻璃渲染
- **高光反射**：上部 1/3 区域的镜面高光带
- **柔和阴影**：多层递减透明度的软阴影
- **8 种配色方案**：Blue、Graphite、Aurora、Characters、Nature、Scenes、Landscapes、Architecture
- **运行时主题切换**：通过 theme_loader 解析 .theme INI 配置文件
- **完整 Shell**：登录、桌面、任务栏、开始菜单、窗口装饰、控件
- **ZirconAero / Win7 壳层元素**：Harmony 风格默认壁纸、通知区布局常量、Aero Peek 显示桌面条、桌面小工具（CPU/网络）状态 API、快捷方式标记
- **12+ 张原创 SVG 壁纸**：含 `zircon_harmony_win7.svg`（深蓝 + 四色窗格致敬）
- **13 种声音方案**：对应不同场景和氛围

## 目录结构

```
src/
├── root.zig              # 库入口，导出所有模块
├── main.zig              # 可执行入口 / 集成测试
├── theme.zig             # 颜色方案、布局、DWM 配置、壁纸映射
├── theme_loader.zig      # .theme INI 配置文件解析器
├── dwm.zig               # 桌面窗口管理器（blur / tint / shadow）
├── compositor.zig        # DWM 合成器：Surface / Z-Order / 损坏追踪
├── renderer.zig          # 渲染抽象层
├── input.zig             # 输入：热键 / 鼠标插值
├── cursor.zig            # 光标渲染
├── desktop.zig           # 桌面管理器（图标 / 壁纸 / 主题切换 / 快捷方式）
├── gadgets.zig           # 桌面小工具状态（CPU、网络标签）
├── taskbar.zig           # 玻璃任务栏（含 Aero Peek 命中矩形）
├── startmenu.zig         # 开始菜单（双栏 / 搜索框）
├── window_decorator.zig  # 窗口装饰器（圆角 / 控制按钮）
├── shell.zig             # Shell 主程序（会话管理 / 主题切换）
├── controls.zig          # UI 控件样式
└── winlogon.zig          # 登录管理

resources/
├── MANIFEST.md           # 资源清单
├── logo.svg              # ZirconOS Aero 品牌标识
├── start_orb.svg         # Start Orb 按钮
├── themes/               # 8 个 .theme 配置文件
├── icons/                # 12 个 48x48 SVG 系统图标
├── cursors/              # 14 个 32x32 SVG 光标
├── wallpapers/           # 11 个原创 SVG 壁纸 + 5 个分类子目录
└── sounds/               # 声音方案配置 + 13 个方案子目录
```

## 主题变体

| 主题 | 配色 | 壁纸 | 说明 |
|------|------|------|------|
| Blue (默认) | 蓝色毛玻璃 | zircon_harmony_win7 | Harmony 风深蓝氛围 + 四色窗格光晕 |
| Graphite | 灰色中性 | zircon_crystal | 菱形水晶 + 光斑 |
| Aurora | 青绿极光 | zircon_aurora | 北极光 + 星场 |
| Characters | 暖色笔触 | zircon_characters | 墨迹笔画 + 印章 |
| Nature | 紫绿植物 | zircon_nature | 花瓣 + 绿叶 |
| Scenes | 紫色舞台 | zircon_scenes | 聚光灯 + 幕布 |
| Landscapes | 灰银极简 | zircon_landscapes | 丘陵 + 溪流 + 雾 |
| Architecture | 靛蓝建筑 | zircon_architecture | 玻璃幕墙 + 窗格 |

## 构建

```bash
# 从主仓库根目录
zig build desktop -Dtheme=aero
make run-desktop-aero

# 单独构建
cd src/desktop/aero && zig build
```

## Aero Glass 渲染流程

```
1. 读取窗口后方的帧缓冲区内容
2. 多遍 Box Blur（水平 → 垂直，3 遍 ≈ 高斯模糊）
3. 去饱和 + 颜色染色混合（glass_tint + opacity + saturation）
4. 叠加镜面高光带（上部 1/3 亮度增加）
5. 渲染窗口内容
6. 绘制多层软阴影
```

## 启动流程（参考 ReactOS NT6 桌面模式）

```
1. WinLogon 认证用户并创建桌面会话
2. Shell (explorer) 初始化 DWM 合成器
3. theme_loader 注册内建主题并加载用户偏好
4. 初始化桌面（壁纸 + 图标网格）、任务栏、开始菜单
5. 进入桌面消息循环，处理输入和窗口管理
```

## 许可证

GNU Lesser General Public License v2.1

所有资源为 ZirconOS 项目原创设计，不依赖任何第三方版权素材。
