# ZirconOS Aero 资源清单

本资源包为 ZirconOS 原创设计，所有图形资源由代码生成或使用原创素材。
**不包含任何第三方版权资源**。

## 图形资源

| 资源类型 | 数量 | 说明 |
|---------|------|------|
| 壁纸 | 12 SVG | 原创矢量壁纸，覆盖 8 个主题变体（含 Harmony 风默认） |
| 图标 | 12 SVG | 48x48 系统图标，水晶/玻璃风格 |
| 光标 | 14 SVG | 32x32 光标集，含动画状态 |
| Logo | 1 SVG | ZirconOS Aero 品牌标识 |
| 开始按钮 | 1 SVG | Start Orb 按钮图标 |

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
| `sounds/sound_scheme.conf` | 主声音方案配置 |
| `sounds/Desktop.ini` | 声音文件本地化映射 |
| `sounds/Afternoon/` ~ `sounds/Sonata/` | 13 个声音方案变体 |

## 使用方式

资源通过 `@embedFile` 嵌入或由渲染代码在运行时按主题配色生成。
主题通过 `theme_loader.zig` 模块加载 `.theme` INI 文件并映射到内部配色方案。

## 注意

`other/resources/Aero/` 中的第三方参考资源**不得**用于发行版构建。
发行版仅使用代码生成的原创资源。
