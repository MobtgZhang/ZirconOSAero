# NT 6.1 图形与 Win32k 脚手架说明

本页对应实施计划中的 **Phase B / C / D / F** 增量落地（clean-room，仅公开文档行为）。

**未完成项总表**（滚动）：[NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md)。

## Phase B — `gpu_device.zig`

- [`src/drivers/video/core/gpu_device.zig`](../../src/drivers/video/core/gpu_device.zig) 提供 `GpuDevice` + `VTable`，当前为 **ramfb 占位**。
- [`src/drivers/video/virtio/virtio_gpu_spec.zig`](../../src/drivers/video/virtio/virtio_gpu_spec.zig) 为 VirtIO-GPU **命令与头布局**（公开规范常量）；[`virtio_gpu_pci.zig`](../../src/drivers/video/virtio/virtio_gpu_pci.zig) 在 PCI 枚举到 **1af4:1050** 时探针并打日志，控制队列与 scanout 接线仍待里程碑完成。
- 后续在 `gpu_device` 上实现命令子集（`RESOURCE_CREATE_2D`、`SET_SCANOUT`、`FLUSH` 等），参考 [VirtIO 1.2 规范](https://docs.oasis-open.org/virtio/virtio-v1.2-csd01/virtio-v1.2-csd01.html)。
- 内核构建禁用 SIMD：像素混合与模糊须用 **标量** 或架构允许的替代实现（见项目规则）。

## Phase C — `win32k/mod.zig`

- [`src/subsystems/win32k/mod.zig`](../../src/subsystems/win32k/mod.zig) 提供 `HWND` / `Window` 表、Z 序遍历与 **每线程消息队列** 的最小实现（`PostMessage` / `peekMessage`）；与 `input_hub` 的完整路由仍待办。

## Phase D — 合成器与事件驱动

- 桌面主循环默认 `desktop_idle_spin` 的演进方向：**VSync/输入/surface 脏标记** 唤醒，减少空转（见 [`AeroDesktopRuntime.md`](AeroDesktopRuntime.md)）。`display_flip_journal.zig` 记录 `present` 世代并在空闲 streak 下 **降低** `input_hub` 尾部轮询密度（在保持默认可靠性的前提下减轻 CPU 空转；IRQ 路径完善后可进一步关短自旋）。
- Aero 模糊：多遍 box blur 近似高斯，性能不足时降级为半透明填充。

## Phase F — 调度与 SMP

- 以 [`docs/cn/NT61_CONTRACT_MATRIX.md`](NT61_CONTRACT_MATRIX.md) 与 `src/ke/scheduler.zig` 为准；**Priority Boost / Decay、前台配额** 等待办见 `tests/nt61_phase_f_scheduler_gap.zig` 注释。

## QEMU 窗口与分辨率

- 见 [`AeroDesktopRuntime.md`](AeroDesktopRuntime.md) §4.2.2 与 `build.conf` / `make sync-resolution`。**默认** `QEMU_GTK_ZOOM=zoom-to-fit=off`（1:1）；需要缩放进窗口时用 `make run-qemu-zoom-fit`；x86 对照宿主缩放可用 `make run-qemu-sdl`（SDL）。
