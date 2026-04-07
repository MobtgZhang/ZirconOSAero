# NT 6.1 风格内置应用路线图（Clean-room）

本文档对照 Windows 7 常见内置程序清单，说明 ZirconOSAero 中的**实现状态、依赖子系统与参考方式**。实现须为独立编写；禁止复制 Windows / ReactOS / Wine 源码或微软专有素材。AI 生成代码须经人工版权审查（见项目 `.cursor/rules/zig-nt61-copyright-safety-testing.mdc`）。

## 参考方式（desktop-src）

离线 Learn 镜像路径示例：`ZirconOSFluentRust/references/win32/desktop-src`（与 [DesktopManagerSpec.md](DesktopManagerSpec.md) 第 7 节一致）。**仅**用于核对公开 API 名称、Shell/DWM 概念与文档化行为，**不**作为实现源码来源。

## 应用平台（宿主模型）

当前桌面为**内核帧缓冲 + Aero 渲染路径**（见 [AeroDesktopRuntime.md](AeroDesktopRuntime.md)）。内置 GUI 采用 **Phase 1-B：Shell 宿主内嵌窗口**（[`src/drivers/video/desktop/builtin_apps.zig`](../../src/drivers/video/desktop/builtin_apps.zig)），与将来「独立用户态进程 + `CreateProcess`」可并存；迁移时在路线图中将状态改为 `process`。

| 组件 | 位置 | 说明 |
|------|------|------|
| 应用 ID 与启动 | `builtin_apps.zig` | `BuiltinAppId` 单一枚举 |
| 开始菜单 → 启动 | `startmenu.zig` | 左列/右列/「所有程序」 |
| 绘制与命中 | `display.zig` / `renderer_aero.zig` | 任务管理器之上叠画内置窗 |
| 文件对话框 | `builtin_apps.zig`（`FileDialog`） | VFS 打开/保存；演示路径见下 |
| 剪贴板 | `builtin_apps.zig`（`Clipboard`） | 主格式：`text` 或 `dib_bgr32` 占位（截图） |

## 与代码对齐（强制同步项）

| 项 | 代码事实 |
|----|-----------|
| `BuiltinAppId` | `builtin_apps.zig` 中 `enum(u16)`，含附件/媒体/Shell/安全等全部占位 ID |
| `ALL_PROGRAMS` | 当前 **13** 项：`notepad, wordpad, paint, calculator, minesweeper, solitaire, spider_solitaire, freecell, hearts, osk, charmap, cmd_shell, dotnet_shell_host`；侧栏高度有限，增删须改本表 |
| 演示路径 | `demo_notepad_vfs_path` = `C:\NOTEPAD.TXT`（记事本/写字板 Open/Save） |
| 任务管理器前置 | `display.bringTaskManagerToFront()`；**热键** `Ctrl+Shift+Esc` 在 `display.handleDesktopHotkeys` → `arch.consumeTaskMgrHotkey` |
| `taskmgr_focus` ID | `launch(.taskmgr_focus)` **仅 klog**，开始菜单**无**单独「任务管理器」项；与上栏热键区分 |
| 搜索过滤 | `startmenu.feedSearchFromKeyboard` 填充缓冲；**非空时** ASCII 子串过滤左列、右列、「所有程序」行（大小写不敏感） |
| 输入注入 | `arch.injectSyntheticChar`：x86_64 → PS/2 环；loongarch64 → `evdev_virtio_bridge` |

## 任务管理器与「Windows 搜索」（表述对齐）

- **任务管理器**：始终绘制于 Shell（非 `BuiltinAppId` 窗口）。进程列表来自 [`process.getProcessList()`](../../src/ps/process.zig)（最多展示 8 行 + 余量提示）；CPU/内存列为占位。**不会**因开始菜单中的 stub ID 自动弹出。
- **Windows 搜索**：状态为 **partial**——仅搜索框缓冲、占位符与**菜单项过滤**，无全机索引/后台服务。

## 桌面小工具（Gadgets）

内核内嵌 Shell **不包含** Sidebar 小工具引擎。天气/时钟等扩展见 **用户态宿主** [`src/desktop/aero/src/gadgets.zig`](../../src/desktop/aero/src/gadgets.zig)（与内核路线图分列，避免混淆）。

## 资源管理器（Explorer）对齐 Checklist

以下与 [`shell_strings.zig`](../../src/drivers/video/desktop/shell_strings.zig)、`renderer_aero` 导航命中**逐项对齐**（替代笼统「深化中」）：

- [ ] 命令栏/库按钮字符串与 `shell_strings` 中英文一致  
- [ ] 地址栏与 `explorer_w2k_loc` 枚举切换时页脚状态行一致  
- [ ] 左侧导航命中区域与绘制几何一致  
- [ ] Aero/经典主题下同一逻辑路径可重复进入  

## 状态图例

| 标记 | 含义 |
|------|------|
| full | 具备可交互最小功能 |
| full(min) | 纯文本或极简规则可玩，高级格式/策略另行列 planned |
| partial | 部分路径接通（VFS、剪贴板占位、枚举显示等） |
| stub | 壳窗口 + 说明文本 / 日志 |
| planned | 仅路线图登记 |
| n/a | 文档级 out-of-scope |

## 附件（Accessories）

| 应用 | 状态 | 依赖 | desktop-src 提示主题 |
|------|------|------|---------------------|
| 画图 (Paint) | full | 帧缓冲、鼠标 | `gdi/` |
| 写字板 — 纯文本 | full(min) | 独立缓冲、`FileDialog`、`readInputChar` | `richedit/`、`shell/`（概念） |
| 写字板 — RTF 子集 | planned | 富文本解析子集 | 公开 RTF 概述（非实现来源） |
| 记事本 (Notepad) | full | 键盘、`FileDialog`、VFS | 编辑控件概念 |
| 计算器 (Calculator) | full | 鼠标 | — |
| 截图工具 | partial | `copyDrawBufferRectBytes`、`Clipboard.setDibBgr32` | `gdi/`、`clipboard` 概念 |
| 放大镜 | partial | 鼠标坐标、`copyDrawBufferRectBytes`、最近邻缩放 | `winuser/`、`magnification` 概念 |
| 讲述人 | partial | 焦点变化 → klog（无 TTS） | 可访问性公开概念 |
| 屏幕键盘 (OSK) | full | `Clipboard` + `injectSyntheticChar` | `inputdev/` |
| 字符映射表 | full | `Clipboard`、UTF-8 | `wingdi/`、`string` 概念 |
| 同步中心 | partial | `hdmi.getOutputCount()` / IOCTL 语义一致 | `shell/`、`sync` 概念 |
| 连接到投影仪 | partial | 同上（输出计数文案） | 显示枚举公开概念 |

## 媒体与娱乐

| 应用 | 状态 | 说明 |
|------|------|------|
| Windows Media Player | stub | 无内核 PCM/WAV 缓冲；解码 HAL 后升级为 partial |
| Windows Media Center | planned | 低优先级 |
| DVD Maker | n/a | 不支持 |
| 录音机 | partial | 占位 VU；采集 IOCTL 未接 |

## 网络与通信

| 应用 | 状态 | 说明 |
|------|------|------|
| Internet Explorer 8 | stub | **非 Trident**；可插拔渲染（如 Gecko/WebKit **类**）策略见表下 |
| Windows Live Mail | planned | 非 Win7 核心预装 |
| 传真和扫描 | stub | TWAIN/WIA **概念目录**：desktop-src 下 `twain`、`wia_*` 主题（仅文档索引） |

**IE 策略（摘要）**：URL/书签列表可为占位；引擎通过抽象接口接入，不实现 MSHTML/Trident。

## 系统工具

| 应用 | 状态 | 说明 |
|------|------|------|
| 任务管理器 | partial | `process.getProcessList()`；CPU/内存采样二期 |
| 控制面板 | partial | CPL 分类占位列表（可扩展 applet） |
| 注册表编辑器 | partial | 内存只读演示树（HKLM/HKCU 字符串） |
| 磁盘清理 | stub | 安全说明：`drawStubLines` / 本文 — 无破坏性擦除直至配额 API |
| 磁盘碎片整理 | stub | 块 IOCTL 未接；闪存可跳过 |
| 备份和还原 / 系统还原 | stub | 无 VSS；不假设快照存在 |
| 事件查看器 | partial | 静态通道说明行 |
| 设备管理器 | partial | PCI/`pcie.zig` 文案 |
| 计算机管理 | partial | 点击行启动 Event Viewer / Device Manager 窗 |
| 资源监视器 / 性能监视器 | stub | 与 KE/PS 采样二期 |
| 任务计划程序 | stub | 作业存储占位 |
| 命令提示符 | stub | `cmd.zig`（内核内置最小 CMD 行） |
| **PowerShell**：兼容 cmdlet 宿主 | **不适用（内核）** / **工具链 partial** | **内核不提供** PowerShell；完整 .NET 宿主仍为 **仓库外**。阶段 D 起：主机工具 **[`tools/pwsh-lite`](../../tools/pwsh-lite/)**（`zig build pwsh-lite`）为 **自研** cmdlet 管道演示，`zig build test` → **pwsh_lite_host**；**不**声称与 Windows PowerShell 等价。 |

## 游戏（Games）

| 应用 | 状态 | 说明 |
|------|------|------|
| 扫雷 | full | 原创逻辑 |
| 纸牌 (Solitaire) | partial | 1..13 顺序叠牌最小玩法 |
| 蜘蛛纸牌 | partial | 1..10 子集 |
| 空当接龙 | stub | 规则与空闲格 — planned |
| 红心大战 | stub | planned |
| 国际象棋 / 麻将 / Purble / Internet 游戏 | planned | 资源与网络就绪后排期 |

## 文件与桌面

| 应用 | 状态 | 说明 |
|------|------|------|
| 资源管理器 | partial | 见上文 **Explorer checklist** |
| 桌面小工具 | n/a（内核） | 仅宿主 `gadgets.zig`；见上文 |
| Windows 搜索 | partial | 菜单过滤 + 搜索框；无索引服务 |

## 安全

| 应用 | 状态 | 说明 |
|------|------|------|
| Defender / 防火墙 / Update | stub | 文案引用 [Microsoft Learn — Windows 安全](https://learn.microsoft.com/windows/security/) 与 WDK/WFP **概念**（无后端包过滤） |
| BitLocker | stub | 企业说明；与 `src/se/token.zig`、令牌提升文档交叉引用 |
| UAC | stub | 模拟提示流；同上 Se/令牌设计 |

## 版权与每 PR 审查（review-copyright）

每次合并与发布前：

1. 确认无 Windows/ReactOS/Wine 源码片段。  
2. 新增资源符合 [Assets.md](Assets.md)。  
3. **更新本文件与英文版对应表格的状态列**与本节日期。  

（持续流程；以 PR 模板与人工审查为准。）

---

**最后更新**：2026-03-28 — 与 `builtin_apps.zig`、`startmenu.zig`、`display.zig` 同批次对齐。
