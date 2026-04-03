# 阶段 4：硬件加速与系统级集成（官方范围）

本文是 ZirconOSAero **Desktop / 显示 / csrss / WOW64 / 持久化** 在「阶段 4」的**唯一权威范围说明**（clean-room；知识来源：OASIS VirtIO、硬件公开手册、Microsoft Learn **行为级**描述）。个人笔记目录（如未入库的 `mdcs/`）**不是**契约来源。

## 目标与非目标

### Phase4-Core（必达，呈现与集成）

- **VirtIO-GPU 2D**：PCI 枚举、MMIO、队列、`SET_SCANOUT`、`RESOURCE_ATTACH_BACKING`（单段或多 mem_entry）、`RESOURCE_FLUSH`；无设备时静默回退 GOP/线性帧缓冲。
- **呈现后端策略**：`display_backend.zig` 在 `gop_linear` 与 `virtio_scanout` 间切换；`-Dforce_gop_present=true` 强制 GOP（诊断/对比）。
- **WDDM 关系**：仅 **`wddm_abstraction.zig` 概念分层**与 `WddmRuntimePhase` 遥测；**不**实现 Windows KMD/UMD 二进制 IOCTL 协议，不使用 `DxgkDdi*` 作为已实现 DDI 名称对外承诺。
- **合成器后端（CompositorBackend）**：CPU 全路径合成 + 可选「VirtIO 仅负责 scanout」；**不**把 Aero 盒式模糊默认卸载到 GPU。
- **csrss + LPC**：窗口站/桌面生命周期走 **`CsrApiNumber` + `LPC_NT61_HANDSHAKE.md` vNext** 固定布局；`user32` 为 API 层，与 `subsystem.handleApiCall` 对齐。
- **WOW64**：对 **DWM / user32 相关** 的 x86 服务路径给出 **显式** `STATUS_SUCCESS`（演示子集）或 **`STATUS_NOT_IMPLEMENTED`**，并在矩阵登记。
- **NTFS + ZOSH1**：在 **`D:\`** 卷上提供与 **`C:\`** 对称的 **ZOSH1 加载/导出路径常量**（小文件）；完整 RegF 仍为长期项。

### Phase4-Plus（可选，不与 Core 混为一谈）

- **VirGL / `CMD_SUBMIT_3D` 非空载荷**：自主编码命令流（不复制 Mesa 源码）；用户态提交边界见 `MM_Section_Roadmap.md`。
- **GPU 辅助模糊**：仅在 `tryVirglBlurBoxDelegation` 等路径**真实返回 true** 时由 `dwm` 减轻 CPU 盒式模糊；否则保持 `dwm_blur_budget` 模型。

## 6–8 周里程碑表（建议顺序）

| 周次 | 交付 | 验证 |
|------|------|------|
| 1 | `.gitignore` / `.cursorignore`；本文 + Roadmap + VirtioVirglMVP 范围对齐 | 文档 PR 审查 |
| 1–2 | `force_gop_present` + `display_backend` 策略日志 | QEMU 串口 + `zig build test` |
| 2–3 | `CompositorBackend` + `dwm` 读后端的模糊策略挂钩 | 主机 `dwm_blur_budget_host` 不回归 |
| 3–5 | LPC `open_desktop` / `switch_desktop` / `close_desktop` + `port.zig` 应答载荷 | `windowstation_lpc_host` |
| 4–6 | WOW64 DWM/user32 清单 + thunk/stub + 矩阵 | 新增主机测试 |
| 5–8 | `hive.zig` NTFS `D:\` ZOSH1 路径 + 引导加载顺序 | `ntfs_hive_minimum_host` 扩展 |
| 持续 | `NT61_CONTRACT_MATRIX.md` / `MVT_NT61.md` / `API_COMPAT_MATRIX.md` | CI `zig build test` |

## 交叉引用

- [VirtioVirglMVP.md](VirtioVirglMVP.md) — VirGL MVP 与 Phase4-Plus  
- [SOFTWARE_COMPOSITOR_WDDM.md](SOFTWARE_COMPOSITOR_WDDM.md) — 软件合成与呈现后端  
- [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) — LPC 载荷与版本  
- [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) — 完成度唯一事实来源  
