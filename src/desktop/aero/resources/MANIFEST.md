# ZirconOS Aero 资源清单

本资源包为 ZirconOS 原创设计，所有图形资源由代码生成或使用原创素材。
**不包含任何第三方版权资源**。

## 图形资源

| 资源类型 | 数量 | 说明 |
|---------|------|------|
| 壁纸 | 12 SVG | 原创矢量壁纸，覆盖 8 个主题变体（含 Harmony 风默认）；默认/Harmony 中心光晕与主题 accent 对齐微调 |
| 图标 | 17 SVG | 48×48，内置 13 枚 + `file`/`user`/`lock`/`shutdown` 辅助；见 `icons/README.md` |
| 光标 | 14 SVG | 32×32；**全部**在 [`resource_loader.zig`](../src/resource_loader.zig) `registerBuiltinCursors` 登记（含 `zircon_nwse`）；内核帧缓冲仍用 [`aero_cursor_shape.zig`](../../../drivers/video/aero_cursor_shape.zig) 位图，不加载 SVG |
| Logo | 1 SVG | 与 `theme.zig` accent `#3D8ED8` 同色族；`registerBuiltinBrandAssets` ID 1 |
| 开始按钮 | 1 SVG | Start Orb；`registerBuiltinBrandAssets` ID 2 |
| 设计规格 | `DESIGN.md` | 画布、描边、色板、高光、ID 映射 |
| 视觉验收 | `VISUAL_QA.md` | 四场景截图检查表与构建要点 |

### 图标文件一览

内置注册：`computer`, `documents`, `recycle_bin`, `terminal`, `network`, `browser`, `settings`, `calculator`, `text_editor`, `pictures`, `music`, `folder`, `control_panel`。辅助：`file`, `user`, `lock`, `shutdown`。

内核帧缓冲壳层（`src/drivers/video/icons.zig`）中 `IconId` 数值与上表 **1–13** 一致，16×16 回退位图与同名 SVG 路径对应；辅助 ID 14–17 映射到最近内置形。

## 主题配置

| 文件 | 说明 |
|------|------|
| `themes/zircon-aero.theme` | 主 Aero 主题配置（DWM 参数） |
| `themes/zircon-aero-blue.theme` | 蓝色变体 |
| `themes/zircon-aero-graphite.theme` | 石墨色变体 |
| `themes/characters.theme` | Characters 主题 - 暖色笔触风格 |
| `themes/nature.theme` | Nature 主题 - 紫绿植物风格 |
| `themes/scenes.theme` | Scenes 主题 - 紫色舞台风格 |
| `themes/landscapes.theme` | Landscapes 主题 - 灰银极简风格 |
| `themes/architecture.theme` | Architecture 主题 - 靛蓝建筑风格 |

## 壁纸

| 文件 | 主题 | 说明 |
|------|------|------|
| `wallpapers/zircon_harmony_win7.svg` | Blue (默认) | Harmony 风深蓝氛围 + 四色窗格光晕（原创致敬） |
| `wallpapers/zircon_default.svg` | Blue (备选) | 中心水晶，深蓝渐变背景 |
| `wallpapers/zircon_aurora.svg` | Aurora | 北极光 + 水晶面片 + 星场 |
| `wallpapers/zircon_crystal.svg` | Blue/Graphite | 抽象菱形水晶 + 光斑 |
| `wallpapers/zircon_ocean.svg` | 通用 | 深海光线 + 焦散 |
| `wallpapers/zircon_nebula.svg` | 通用 | 蓝橙星云尘埃带 |
| `wallpapers/zircon_landscape.svg` | 通用 | 水晶山峦 + 湖面倒影 |
| `wallpapers/zircon_characters.svg` | Characters | 暖色墨迹笔触 + 印章 |
| `wallpapers/zircon_nature.svg` | Nature | 紫色花瓣 + 绿叶 |
| `wallpapers/zircon_scenes.svg` | Scenes | 紫色舞台聚光灯 |
| `wallpapers/zircon_landscapes.svg` | Landscapes | 灰银丘陵 + 溪流 |
| `wallpapers/zircon_architecture.svg` | Architecture | 靛蓝玻璃幕墙建筑 |

## 声音方案

| 目录 | 说明 |
|------|------|
| `sounds/sound_scheme.conf` | 主声音方案配置（`registerBuiltinSoundSchemes` ID 1） |
| `sounds/Desktop.ini` | 根映射（ID 2） |
| `sounds/README.md` | 文档（ID 3） |
| `sounds/Afternoon/Desktop.ini` ~ `sounds/Sonata/Desktop.ini` | 13 个变体目录（ID 4–16）；内核暂无 WAV 播放，仅路径登记 |

## 使用方式

- **用户态 Aero 库**：[`resource_loader.zig`](../src/resource_loader.zig) 登记壁纸 / 图标 / 光标 / 主题 / 声音元数据路径 / 品牌 SVG；主题通过 `theme_loader.zig` 加载 `.theme` INI。
- **内核帧缓冲桌面**：[`renderer_aero.zig`](../../../drivers/video/renderer_aero.zig) 用程序化渐变与 `blendTintRect` 绘制默认与 **Ctrl+Alt+F9** 循环的 12 套壁纸预设，**运行时不对 `wallpapers/*.svg` 做光栅化**；SVG 与 `resource_loader` 条目用于清单一致性与宿主工具。桌面图标 SVG 由 [`icons.zig`](../../../drivers/video/icons.zig) 构建期 `@embedFile` 嵌入。

## 注意

`other/resources/Aero/` 中的第三方参考资源**不得**用于发行版构建。
发行版仅使用代码生成的原创资源。

## 合规策略

完整政策与 AI 生成素材归档模板见 **[docs/cn/Assets.md](../../../../docs/cn/Assets.md)**：禁止微软专有素材；仅允许开源许可 / 公有领域 / 自有或 AI 生成并记录来源。
