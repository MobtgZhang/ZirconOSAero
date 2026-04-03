# 软件合成器、Aero 与 WDDM（诚实说明）

## 当前定位

- **本仓库的 Aero**：主要为 **CPU / 帧缓冲** 路径上的窗口合成与主题资源（见 `src/drivers/video/root.zig` 聚合导出、`core/dwm.zig`、`desktop/renderer_aero.zig`）。  
- **Windows 7 的 DWM**：依赖 **WDDM** 用户态与内核协作、GPU 命令缓冲与桌面合成 — **本仓库未实现 WDDM 驱动模型**。

## MVP 软件合成器（路线）

1. **图层栈**：全屏桌面 → 壁纸 → 窗口 back-buffer → 光标（Z-order 与 `DesktopManagerSpec` 对齐）。  
2. **脏矩形**：在 `compositor_config_epoch` 与显示路径上减少全屏 blit（已有部分 trace / 握手位）。  
3. **与 user32 边界**：user32 负责单窗消息与 NC；合成器负责跨窗 Z-order 与 damage 聚合。

## GPU 路线（QEMU / 真机）

- **Virtio-GPU**：作为可移植的 **非 WDDM** 加速台阶（VirtIO 规范 + 本内核 PCI 枚举）。  
- 真机 **Intel/AMD/NVIDIA** 的 KMS 类路径为独立里程碑，与 NT 显示驱动 **无源码级对齐义务**。

## 阶段 4：呈现后端与合成器后端（Phase4-Core）

- **`display_backend.BackendKind`**：`gop_linear`（固件/GOP 线性帧缓冲）与 `virtio_scanout`（VirtIO `SET_SCANOUT` 路径）。`syncFromVirtioScanout` 在 bring-up 成功后切换；**`-Dforce_gop_present=true`** 时保持 GOP，便于对照实验（见 [PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md)）。
- **`wddm_abstraction.CompositorBackend`**：`cpu_full` / `cpu_with_virtio_present` / `future_gpu_assist` — 仅描述 **合成责任**划分，**不是** WDDM DDI。
- **DWM**：盒式模糊仍以 CPU 预算为主；仅当 VirGL 委托路径真实成功（Phase4-Plus）时才可减轻 CPU 模糊。

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

与 [REPRODUCE_BUILD.md](../REPRODUCE_BUILD.md) 一致：设备出现后串口应出现 **scratch `TRANSFER_FROM_HOST_2D` / `TRANSFER_TO_HOST_2D` 自检**；帧缓冲 32bpp 就绪时可出现 **4×4（或更小）display↔scratch 往返 ok**（`compositorTryRoundTripFramebufferRect`，仅诊断）。

**Scanout（非 WDDM）**：当 `pitch == width×4` 时，`bringupMmioIfProbed` 可建立 **`CMD_SET_SCANOUT`**（resource 2）：优先 **单段** 物理连续 `RESOURCE_ATTACH_BACKING`；否则按 4KiB 页拆成 **多枚 `virtio_gpu_mem_entry`**（`core/framebuffer.zig` 的 `fillFrontBufferVirtioBackingEntries`）。`virtio_gpu_spec.zig` 中 **`max_virtio_backing_mem_entries` / `max_attach_backing_wire_bytes`** 与 `build.conf` 注释表最大档 **3840×2160×32** 对齐（最坏每页一条 entry），`virtio_gpu_pci.zig` 的 `gpu_attach_blob` 与栈上 entry 表与此同源，避免 4K scanout 下 attach 缓冲溢出。每次 `present` 的 `flip`/`flipDirty` 之后发 **`CMD_RESOURCE_FLUSH`**（整屏或 `peekDirtyUnionPx` 脏外包）。`core/display_flip_journal.zig` 的 `noteVirtioResourceFlush` 统计整幅/局部 flush 次数；`noteVirtioPresentFlushBatch` 累计单次 present 内 flush 次数（当前单 scanout 资源为 1，第二平面落地后可 >1）。**不**免除 CPU 离屏合成与 back→front memcpy。**不做项**：大块 Aero 盒式模糊在 GPU 执行、WDDM 等价驱动 — 矩阵 §4.1 **Partial** 与此一致。VirGL：`CMD_SUBMIT_3D` **空提交** bring-up 见 [VirtioVirglMVP.md](VirtioVirglMVP.md) 与 `WddmRuntimePhase.virgl_submit3d_noop_ok`；**不**表示模糊卸载已接。

## 离屏缓冲与高分档位（`BACK_BUF_MAX`）

- `core/framebuffer.zig` 中 **`BACK_BUF_MAX = 10 MiB`** 的 **静态离屏槽** 约覆盖 **1920×1080@32bpp** 及以下的双/三缓冲决策（见 `applyBufferingFromDims`）。  
- **高于该像素量**（如 2560×1440、3840×2160）时，离屏/多缓冲改走 **伙伴堆连续物理页** 路径；成功与否取决于内核分配器与可用 RAM，**不再**由静态槽保证。  
- **QEMU / 客体 RAM**：4K 下若启用双缓冲或三缓冲，除屏前与离屏外仍有内核与其它子系统占用；若 `-m` 过小可能出现分配失败或合成降级。建议 **`QEMU_MEM` 不低于 512M** 做 smoke，长期开发可保持 `build.conf` 默认 **8G** 或按机器调大。

**上界变更纪律（问题三 P3-3）**：若变更 scanout attach 规则或 flush 语义，须 **同时** 更新本节、契约矩阵 §4.1 对应行、`core/display.zig` / `virtio/virtio_gpu_pci.zig` / `core/framebuffer.zig` / `virtio/virtio_gpu_spec.zig` 中的注释与单一来源常量；**禁止**只改代码不更新文档与矩阵。

## 参考

Microsoft Learn — Desktop Window Manager **概述**（概念）；算法与代码须原创。
