# 驱动与 HAL 里程碑（NT 6.1 语义，公开文档驱动）

`desktop-src` 对内核驱动覆盖很少；实现以 **WDK** 与 **硬件厂商公开编程手册** 为准。

## USB

- **xHCI**：优先完善 `[src/drivers/usb/usb_core.zig](../../src/drivers/usb/usb_core.zig)` 与 HID 路径（QEMU 验证）。
- **EHCI**：`[src/drivers/usb/ehci.zig](../../src/drivers/usb/ehci.zig)` 当前为 stub；按 WDK USB 文档实现调度器（QH/qTD）或明确仅支持 xHCI 平台。

## 网络

- `[src/drivers/net/ndis.zig](../../src/drivers/net/ndis.zig)` 为 **NDIS 小端口语义** 的占位；OID 与状态码命名保持公开文档一致，实现自研。

## 显示 / GPU

- Intel / AMD / NVIDIA / Loongson 路径以 **GOP handoff** 与公开寄存器文档为主；WDDM 用户态驱动协议不在此里程碑内。
- 分芯片维护 `*_stub.zig` 与实验性 KMS 开关（见 `build.zig` 选项）。

### VirtIO-GPU PCI（1af4:1050）— 独立里程碑（非 AArch64/RISC-V 默认桌面前提；含「GTK 主窗必显 1920」）

当前 **Aero 桌面在 QEMU AArch64/RISC-V 默认配置**（`Makefile` 中 `**AARCH64_QEMU_VIRTIO_GPU=0`** / `**RISCV64_QEMU_VIRTIO_GPU=0**`）下依赖 **UEFI GOP 线性缓冲** 与/或 `**ramfb` + `fw_cfg`**，**不要求** 本驱动。下列工作仅在需要 **GTK 主窗口绑定 virtio-gpu** 或 **无 ramfb 的纯 GPU 显示** 时启动：

1. **PCI 枚举**：在现有 PCI 框架中识别 **1af4:1050**，映射 **BAR（MMIO）**。
2. **Virtqueues 与协议**：按 **VirtIO GPU 设备规范**（公开 virtio 文档）实现控制队列、资源创建、2D/3D 能力探测的最小子集。
3. **Scanout 路径**：将资源 **flush** 到 QEMU 可见 scanout，或与现有 `[src/drivers/video/framebuffer.zig](../../src/drivers/video/framebuffer.zig)` / **DWM** 合成输出对接。
4. **Makefile**：在驱动可演示前，保持 `**AARCH64_QEMU_VIRTIO_GPU=0`** / `**RISCV64_QEMU_VIRTIO_GPU=0**` 为默认；启用 `**=1**` 仅用于驱动开发与固件 GOP 实验，并预期 **「Display not active」** 类现象直至 scanout 打通。

**LoongArch64 / 高分辨率 GTK**：若要求 **QEMU 主窗口必显与 `build.conf` 一致的 1920 等桌面**（而非仅串口证明 ramfb 已提交首帧），通常需在 virtio-gpu 上实现 **ResourceFlush / SetScanout**（或等价）并与合成输出对接；为独立工作量。在此之前以 **ramfb + 串口验收** 为准（见 [`AeroDesktopRuntime.md`](AeroDesktopRuntime.md) **正式验收标准**）。

参考实现边界：clean-room，不复制 Linux `virtio_gpu` / QEMU 内含实现源码。

## 定时器与中断

- 非 x86_64 架构下 `[src/ke/interrupt.zig](../../src/ke/interrupt.zig)` 可能使用 stub；若简化 IRQL 模型，须在 `docs/en/Kernel.md` 中声明。

