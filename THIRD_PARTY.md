# 第三方与参考来源（合规备忘）

本文件记录仓库内 **非原创** 或 **需单独遵守许可** 的材料，以及「仅文档/行为参考、无代码复制」的说明。**不构成法律意见**；贡献前请自行核对许可与商标。

## 字体与明确第三方许可

| 组件 | 路径 | 许可证 |
|------|------|--------|
| Source Sans Pro | [`src/fonts/western/SourceSansPro/`](src/fonts/western/SourceSansPro/) | 见同目录 `LICENSE.md`（SIL Open Font License） |

## 上游与品牌

| 来源 | 关系 |
|------|------|
| [ZirconOS](https://github.com/MobtgZhang/ZirconOS) | 设计谱系与目录结构对齐；本仓库独立演进。 |

## 文档级参考（代码须原创）

以下名称仅出现在注释或 Markdown 中，用于说明 **架构或行为类比**，**不表示** 对应源码被复制进本仓库。若未来从以 **GPL** 许可的项目（如 ReactOS）移植代码，须在对应文件中保留许可证头并满足该许可证的分发义务。

| 参考指向 | 典型文件 |
|----------|----------|
| ReactOS 目录/模块说明 | [`src/registry/registry.zig`](src/registry/registry.zig)、[`src/drivers/video/vga.zig`](src/drivers/video/vga.zig)、[`src/drivers/video/hdmi.zig`](src/drivers/video/hdmi.zig)、[`src/drivers/mod.zig`](src/drivers/mod.zig)、[`src/desktop/aero/src/root.zig`](src/desktop/aero/src/root.zig) 等 |
| Microsoft Learn / WDM 概念 | [`docs/cn/DesktopManagerSpec.md`](docs/cn/DesktopManagerSpec.md)、部分显示栈注释 |

## LGPL-2.1 与 Win32 兼容层（分发备忘）

本仓库许可证为 **LGPL-2.1**（见根目录 `COPYING`）时：若以 **动态链接** 方式向第三方提供与 ntdll/kernel32 同类的兼容库，LGPL 可能对 **修改后的库本身** 及 **链接机制** 提出源码可得性等要求；**不构成法律意见**。若项目目标包含与闭源应用「随意静态链接」并存，建议维护者另行评估 **许可证策略**（如 LGPL 例外、双许可或独立用户态仓库），并在发行说明中写明链接方式。

## 合规自检（维护者）

1. **禁止**：粘贴 Windows 泄漏源码、未授权 SDK 片段、对闭源二进制反汇编后「抄写」实现。  
2. **允许**：依据公开文档描述行为，独立编写实现。  
3. **资源**：桌面素材政策见 [`docs/cn/Assets.md`](docs/cn/Assets.md)。  
4. **自动化建议**：发布前对新增大段第三方代码运行 `git diff` 审查与许可证头检查；可运行 [`scripts/verify-compliance.sh`](scripts/verify-compliance.sh) 做源码内可疑短语粗扫（**不能**替代人工审查）。
