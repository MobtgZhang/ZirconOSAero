# 未完成项滚动清单（对照实现状态与图形脚手架）

本文对照 [IMPLEMENTATION_STATUS_NT61.md](IMPLEMENTATION_STATUS_NT61.md)、[PROCESS_NT61.md](PROCESS_NT61.md)、[NT61_GRAPHICS_SCAFFOLD.md](NT61_GRAPHICS_SCAFFOLD.md) 与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)，列出**尚未按规范完整实现**的能力。已实现部分见契约矩阵与 `zig build test`。

**版权**：仅 MSDN/WDK/硬件与 VirtIO 等公开规范；禁止 Windows/ReactOS/Wine 源码。

---

## A 类（构建与基础）— 部分已做，仍可持续加固


| 项                   | 状态                    | 备注                                                                                             |
| ------------------- | --------------------- | ---------------------------------------------------------------------------------------------- |
| A0 完成度叙事            | 持续                    | 以 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)、[MVT_NT61.md](MVT_NT61.md) 为准更新 README/矩阵 |
| A1 MBR/VBR/Stage2   | 已修主干                  | 继续用 `make build-zbm-bios` / 烟测回归                                                               |
| A2 桌面包 freestanding | 部分                    | `zig build desktop-aero-freestanding`；**全量** `root.zig` 依赖链与内核 HAL 对接仍待办                       |
| A3 资源/依赖            | 部分                    | `fetch-assets` 占位图；真壁纸与字体流程可再自动化                                                               |
| A4 RISC-V UEFI 入口   | 已加 `main_riscv64.zig` | GNU-EFI 链接与真机验证仍依赖社区路径                                                                         |
| A5 Zig 版本           | 已对齐 CI                | 升级 Zig 时同步 `build.zig.zon` + workflow                                                          |


---

## P / Q 类（PowerShell / QEMU）— 内核侧已完成

- PowerShell / ZirconShell：已从内核与菜单路径移除；契约矩阵 §5.2、BuiltinApps 路线图标明 **用户态 .NET**（仓库外）。
- QEMU 窗口与分辨率：**默认** `QEMU_GTK_ZOOM=zoom-to-fit=off`（1:1，与 `build.conf` `RESOLUTION` 一致）；缩放模式见 `make run-qemu-zoom-fit`；文档 §4.2.2；**SDL 后端**见 `make run-qemu-sdl`。

---

## Phase B — 图形基础（大量待办）

- **B1** 双缓冲、脏矩形、VSync 节拍与现有 `framebuffer`/`display` 深度整合（非仅注释）。
- **B2** VirtIO-GPU（1af4:1050）2D：**已有** PCI/MMIO、队列 bring-up、`SET_SCANOUT`、`RESOURCE_ATTACH_BACKING`（单段或多 mem_entry）、`present` 后 `RESOURCE_FLUSH`、主机单测（[virtio_gpu_spec.zig](../../src/drivers/video/virtio/virtio_gpu_spec.zig)）、呈现后端（[display_backend.zig](../../src/drivers/video/core/display_backend.zig)）。**仍待办 / Phase4-Plus**：第二平面离屏 resource、非空 `SUBMIT_3D` 载荷、用户态提交边界（见 [VirtioVirglMVP.md](VirtioVirglMVP.md)、[PHASE4_HARDWARE_SYSTEM_INTEGRATION.md](PHASE4_HARDWARE_SYSTEM_INTEGRATION.md)）。
- **B3** 标量 2D：混合、圆角、box-blur 近似（遵守内核无 SIMD 规则）。

---

## Phase C — Win32k 向窗口与消息

- **C1** 窗口表、Z 序、`CreateWindowEx`/`SetWindowPos` 等与 [win32k/mod.zig](../../src/subsystems/win32k/mod.zig) 扩展。
- **C2** 每线程消息队列、`PostMessage`/`GetMessage`、与 [input_hub](../../src/drivers/input/input_hub.zig) 路由。
- **C3** `WM_NCPAINT` / 命中测试骨架。
- **C4** `HDC`、`WM_PAINT` 无效区。
- **C5** 字体：stb_truetype 类或等价，避免一上来绑 FreeType。

---

## Phase D — 合成器（DWM 向）

- **D1–D4** 离屏 surface、场景图、Aero 模糊、动画调度与 [dwm_compositor](../../src/drivers/video/core/dwm_compositor.zig) 对齐。
- **D5** 桌面循环事件驱动，默认降低对 `desktop_idle_spin` 的依赖（先修 IRQ 路径再改默认）。

---

## Phase E — Shell（Explorer 等价）

按你的方向：**用户态 .NET**，不在本内核仓库实现。内核侧仅保留 **syscall / Section / LPC** 等支撑（随 Phase F）。

---

## Phase F — 集成

- **F1** Win32k 进内核、句柄校验、与用户态 syscall 表对齐（公开文档行为）。
- **F2** 真 SMP：APIC、IPI、per-CPU（超越 `smp_atomic_host` 单测）。
- **F3** 调度：Priority Boost/Decay、前台配额（对照现有 [scheduler.zig](../../src/ke/scheduler.zig) 与矩阵，避免重复实现已存在策略）。
- **F4** QEMU E2E：截图或串口断言进 CI。
- **F5** 文档与「仅 aero 主题」叙事持续与 Makefile/build 一致。

---

## 建议下一迭代优先级（工程顺序）

1. **B2 前沿**：PCI 枚举到 VirtIO-GPU → MMIO + 队列初始化 → 单模式 scanout（可先 x86_64 QEMU）。
2. **B1 + D5**：双缓冲与桌面唤醒路径（降低 spin）绑定同一里程碑，避免只改一半。
3. **C1 + C2**：最小 `HWND` 表 + 单队列演示，再扩多线程。
4. **F3**：在主机单测中增加可计算的 boost/decay 公式用例，再进内核路径。

