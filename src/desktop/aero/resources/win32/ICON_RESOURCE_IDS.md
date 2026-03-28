# Zircon 壳层图标：逻辑 ID、PE 资源号与文件名

本表将 **`IconId`（1–25）**、**PE `RT_ICON` 资源整数 ID（101–125）** 与 **SVG/ICO 基名** 对齐。  
这些 ID 为 **ZirconOS 自有编号**，与 Windows 7 `shell32.dll` / `imageres.dll` 内索引**无对应关系**。

| IconId | PE 资源 ID | SVG / ICO 基名 | 说明 |
|--------|------------|----------------|------|
| 1 | 101 | `computer` | 此电脑 |
| 2 | 102 | `documents` | 文档 |
| 3 | 103 | `recycle_bin` | 回收站空 |
| 4 | 104 | `terminal` | 终端 |
| 5 | 105 | `network` | 网络 |
| 6 | 106 | `browser` | 浏览器 |
| 7 | 107 | `settings` | 设置 |
| 8 | 108 | `calculator` | 计算器 |
| 9 | 109 | `text_editor` | 记事本 |
| 10 | 110 | `pictures` | 图片 |
| 11 | 111 | `music` | 音乐 |
| 12 | 112 | `folder` | 文件夹 |
| 13 | 113 | `control_panel` | 控制面板 |
| 14 | 114 | `file` | 通用文件 |
| 15 | 115 | `user` | 用户 |
| 16 | 116 | `lock` | 锁定 |
| 17 | 117 | `shutdown` | 关机 |
| 18 | 118 | `recycle_bin_full` | 回收站满 |
| 19 | 119 | `drive_fixed` | 本地磁盘 |
| 20 | 120 | `drive_removable` | 可移动磁盘 |
| 21 | 121 | `drive_optical` | 光盘 |
| 22 | 122 | `printer` | 打印机 |
| 23 | 123 | `info` | 信息 |
| 24 | 124 | `warning` | 警告 |
| 25 | 125 | `error`（文件名 `error.svg`；Zig 枚举成员 `err`） | 错误 |

头文件宏：`zircon_icon_ids.h`。资源脚本：`zircon_shell32_res.rc`。

Shell 风格引用示例：`zircon_shell32_res.dll,-101`（指向本表 PE 列，非 Win7 的 101）。

**维护约定**：本表须与根目录 [`build.zig`](../../../../../build.zig) 中的 `aero_shell_icon_basenames`（及 `laShellIconsManifestJsonAlloc` 生成的 `icons[]` 行）保持同步；增删图标时三处同改。
