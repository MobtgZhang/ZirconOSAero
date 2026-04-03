# 软件合成器、Aero 与 WDDM（诚实说明）

## 当前定位

- **本仓库的 Aero**：主要为 **CPU / 帧缓冲** 路径上的窗口合成与主题资源（见 `src/drivers/video/`、`dwm.zig`、`renderer_aero.zig`）。  
- **Windows 7 的 DWM**：依赖 **WDDM** 用户态与内核协作、GPU 命令缓冲与桌面合成 — **本仓库未实现 WDDM 驱动模型**。

## MVP 软件合成器（路线）

1. **图层栈**：全屏桌面 → 壁纸 → 窗口 back-buffer → 光标（Z-order 与 `DesktopManagerSpec` 对齐）。  
2. **脏矩形**：在 `compositor_config_epoch` 与显示路径上减少全屏 blit（已有部分 trace / 握手位）。  
3. **与 user32 边界**：user32 负责单窗消息与 NC；合成器负责跨窗 Z-order 与 damage 聚合。

## GPU 路线（QEMU / 真机）

- **Virtio-GPU**：作为可移植的 **非 WDDM** 加速台阶（VirtIO 规范 + 本内核 PCI 枚举）。  
- 真机 **Intel/AMD/NVIDIA** 的 KMS 类路径为独立里程碑，与 NT 显示驱动 **无源码级对齐义务**。

## CPU 盒式模糊预算与典型场景（问题三 / `nt61_aero_defaults`）

| 参数 / 行为 | 作用 | 典型触发场景 |
|-------------|------|----------------|
| `blur_budget_pixel_passes_per_frame` | 本帧 `宽×高×pass` 累加上限，耗尽则后续 `boxBlurRect` 跳过 | 高分 + 多窗 + 全宽任务栏条带 |
| `blur_max_single_rect_pixels` | 单次模糊面积上限 | 防止单块超大矩形占满预算 |
| `blur_max_rect_calls_per_frame` | 每帧 `boxBlurRect` 调用次数上限 | 标题栏多遍递减半径路径 |
| `blur_resolution_downgrade_pixel_threshold` + `glass_blur_radius_hd_cap` | 帧像素超阈值时下调半径/遍数 | ≥720p 类分辨率 |
| `glass_blur_radius_loongarch_cap` | LoongArch 等 CPU 更重时收紧 | `dwm.applyPlatformAndResolutionTuning` |
| `renderGlassTintOnly` / `setSkipGlassBoxBlur` / `setGlassLiteBlurEnabled` | 无盒式模糊或轻量单遍模糊 | 开始菜单/壳层打开、拖窗、首帧 |
| **诊断** | `-Ddwm_blur_stats=true`：`klog.debug` 每帧一行 `box_blur_calls` / `budget_denials` / `tint_only_calls` | 与 `-Ddesktop_bisect` 分帧日志配合；见 `dwm.flushBlurFrameStatsDebug` |

**帧内开关矩阵（审计用，不重复扣 `blur_budget`）**：`setSkipGlassBoxBlur` / `setGlassLiteBlurEnabled` 为 **布尔策略**，只影响是否走 `boxBlurRect` 或轻量路径；**像素·遍数预算**仅在 `dwm.tryConsumeBlurBudget` 成功且实际调用盒式模糊时扣减。`display.renderDesktopFrameEx` 在 `beginFrameBlurBudget` 之后对 **壳层** 调用 `setGlassLiteBlurEnabled(shell_glass_lite)`（开始菜单/托盘飞出等）；`syncAeroGlassFastPath`（`present` 前多处）再按 **首帧 / 拖窗** 叠加 `setSkipGlassBoxBlur` 与 `setGlassLiteBlurEnabled(during_drag && !first)`。**后者覆盖前者**在同一帧内是预期行为（拖窗 + 菜单打开时以较晚调用为准）。`renderGlassTintOnly` 走独立计数 `tint_only_calls`，**不**经盒式模糊预算。

成本模型与主机测试：`src/config/dwm_blur_budget.zig`（与 `dwm.tryConsumeBlurBudget` 同源）。

## 第七阶段验收（VirtIO-GPU，QEMU `1af4:1050`）

与 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) 一致：设备出现后串口应出现 **scratch `TRANSFER_FROM_HOST_2D` / `TRANSFER_TO_HOST_2D` 自检**；帧缓冲 32bpp 就绪时可出现 **4×4（或更小）display↔scratch 往返 ok**。`trySubmitFramebufferDirtyRect` 与上述往返 **同 VirtIO 命令路径**；**当前 PoC 硬顶**：单脏矩形外包 **≤32×32** 时 `display.present` 在 **flipDirty** 下 **尝试** GPU 路径（失败静默回退 CPU，不改变 `flipDirty` 语义）。

**Scanout（非 WDDM）**：当 `pitch == width×4` 且屏前缓冲 **4KiB 物理连续** 时，`bringupMmioIfProbed` 后可建立 **`CMD_SET_SCANOUT`**（resource 2）并在每次 `present` 的 `flip`/`flipDirty` 之后发 **`CMD_RESOURCE_FLUSH`**（整屏或脏外包），使设备从 guest RAM 取新像素；**不**免除 CPU 离屏合成与 back→front memcpy。**不做项**：大块 Aero 盒式模糊在 GPU 执行、WDDM 等价驱动 — 矩阵 §4.1 **Partial** 与此一致。

**上界变更纪律（问题三 P3-3）**：若将来放宽 **32×32** 硬顶或变更 scanout 条件，须 **同时** 更新本节、契约矩阵 §4.1 对应行、`display.zig` / `virtio_gpu_pci.zig` 中的常量与注释；**禁止**只改代码不更新文档与矩阵。

## 参考

Microsoft Learn — Desktop Window Manager **概述**（概念）；算法与代码须原创。
