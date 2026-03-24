# ZirconOS Aero 资源视觉规格（v2）

与 `resource_loader.zig` 中注册的 ID 一致；合规见 `MANIFEST.md` 与 `docs/cn/Assets.md`。

## 画布与几何

| 资源 | viewBox | 安全边距 | 说明 |
|------|---------|----------|------|
| 系统图标 | `0 0 48 48` | 内缩约 4px | 任务栏/桌面缩放后轮廓可读 |
| 光标 | `0 0 32 32` | 热点在箭头尖等语义位置 | 线宽与色相与图标系一致 |
| Start Orb | `0 0 54 54` | 外环与任务栏高度匹配 | 与主题 `accent` 同色族 |
| Logo | `0 0 256 256` | 品牌用途 | 与 Orb 同色族，可加副标题 |

## 线宽与圆角

- 图标主轮廓描边：**1.5px**（`vector-effect: non-scaling-stroke` 可选）。
- 次要装饰线：**1px**。
- 矩形圆角：约 **2–3px**（48 画布上）；大面板 **rx="2.5"** 为基准。
- 避免过细 hairline（小于 1 设备像素）在缩小后消失。

## 色板（与 `theme.zig` scheme_blue 对齐）

| 角色 | Hex | 用途 |
|------|-----|------|
| Accent | `#3D8ED8` | 高亮、环、与玻璃标题条呼应 |
| Teal 主色 | `#2ABFBF` | 图标主表面渐变中点 |
| 深青 | `#0D5C5C` / `#1A8A8A` | 暗部、描边 |
| 浅高光 | `#A8F0F0` / `#E8F8F8` | 玻璃面顶部 |
| 结构灰 | `#B8B8B8`–`#6A6A6A` | 显示器边框、金属件 |
| 警告/关机 | `#E85A5A` | 仅关机、删除语义 |

渐变：**≤3 个 stop** 的线性渐变为主；径向高光 **1 层** 即可。

## 高光与阴影

- 统一使用 **单层** `feDropShadow`（`dy≈1.5`，`stdDeviation≈1.5`，低透明度）或省略以减小 SVG 体积。
- 玻璃高光：椭圆或线性白半透明 **一层**，避免多层叠加发糊。

## 导出检查

- 删除编辑器元数据；无外链图片/字体依赖（Logo 文本可用系统字体族回退）。
- `id` 在单文件内唯一；无需合并 defs 到全局。

## 图标 ID ↔ 文件（内置）

| ID | 文件 |
|----|------|
| 1 | `computer.svg` |
| 2 | `documents.svg` |
| 3 | `recycle_bin.svg` |
| 4 | `terminal.svg` |
| 5 | `network.svg` |
| 6 | `browser.svg` |
| 7 | `settings.svg` |
| 8 | `calculator.svg` |
| 9 | `text_editor.svg` |
| 10 | `pictures.svg` |
| 11 | `music.svg` |
| 12 | `folder.svg` |
| 13 | `control_panel.svg` |

辅助未注册 ID（文档/打包用）：`file.svg`、`user.svg`、`lock.svg`、`shutdown.svg`。
