# 桌面资源与素材合规

## 原则

- 第三方与参考来源总表（字体、上游、GPL 注意事项）：仓库根目录 [THIRD_PARTY.md](../../THIRD_PARTY.md)。
- **禁止**使用微软公司专有资源（Windows 7/Vista 自带壁纸、图标、音效、Segoe 等未授权分发内容）。
- **允许**：OSI 认可的开源许可、CC0 / 明确允许再分发的素材、仓库内 **原创** SVG/设计、或 **AI 生成** 素材（须在 `MANIFEST.md` 或本条目中记录工具/服务条款与生成说明）。
- 视觉可借鉴 NT 6.1 **布局与交互**，但像素级拷贝微软资产属于违规。

## 仓库内维护

- 逐项清单：`src/desktop/aero/resources/MANIFEST.md`
- 构建与主题仅引用已审核路径；`other/resources/` 等第三方参考目录不得进入发行配置。

## AI 生成素材归档（模板）

每条记录建议包含：文件名、生成日期、工具/模型名称、许可条款链接、提示词摘要（可选）。

## 批次记录（非 AI）

| 日期 | 范围 | 来源 | 说明 |
|------|------|------|------|
| 2026-03-24 | `src/desktop/aero/resources/icons/*.svg`、`start_orb.svg`、`logo.svg`、部分 `cursors/*.svg`、`wallpapers/zircon_default.svg`、`zircon_harmony_win7.svg` | **原创重绘**（仓库内人工编写 SVG） | 与 `resources/DESIGN.md` 及 `theme.zig` accent 统一；未使用外部图包或 AI 出图。 |
| 2026-03-24 | `src/desktop/aero/src/resource_loader.zig`、`desktop.zig` | 代码 | 修正 `addIcon`/`addCursor`/`addThemeFile` 与磁盘文件名一致；控制面板桌面图标 ID 改为 13。 |
| 2026-03-25 | `src/drivers/video/display.zig`、`icons.zig`、`mouse.zig`、`drivers/mod.zig`；`boot/zbm/uefi/menu_common.zig` | **原创代码** | 全架构光标与 mouse 坐标同步；`IconId` 与 Aero 1–13 对齐；ZBM 菜单扩展按键与 `WaitForKey` 路径。 |
