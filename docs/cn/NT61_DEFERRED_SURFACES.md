# NT 6.1 目标下明确延后的表面（内核里程碑不阻塞项）

本文档与 [docs/en/Roadmap.md](../en/Roadmap.md) 第 6 节 **Deferred surfaces** 一致，说明在 **MM / SMP / 进程隔离 / I/O 基线** 稳定之前，**不**作为内核主里程碑阻塞的跟踪项。实现须保持 clean-room（仅 MS Learn、WDK 公开描述与硬件规范）。

## 延后项列表

| 跟踪项 | 说明 |
|--------|------|
| 完整 WDDM / GPU 离屏合成 | 当前为 CPU 帧缓冲与软件合成演示路径；不声称与 Windows 7 显示驱动模型等价；可选里程碑见 `virtio_gpu` / `HAL_USB_NET_ROADMAP.md` 中的显示加速条目。 |
| 完整 Win32 / user32 / gdi32 | 子系统与壳在 `src/subsystems/win32/`、`src/desktop/aero/`；在内核对象与 VM 语义收紧后扩展。 |
| 完整 WOW64 | 32→64 服务表与 SysWOW64 对齐为长期项；见 `wow64/` 与 `ssdt_nt61.zig`。 |
| NT 32 级优先级与完整 boost | 调度器为文档语义的近似；见 [SCHEDULER_API.md](SCHEDULER_API.md)。 |
| 完整 TCP / 生产级网络栈 | IPv4/UDP 等为路线图原型；见 [HAL_USB_NET_ROADMAP.md](HAL_USB_NET_ROADMAP.md)。 |
| ACPI AML 解释器 | 无 AML 时依赖静态表与 QEMU 路径；引入 AML 须单独里程碑与审计。 |

## 维护

调整延后边界时，同步更新本文件、[NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)、根 [README.md](../../README.md) / [README_cn.md](../../README_cn.md) 的 Design 表述，以及 [docs/en/Subsystems.md](../en/Subsystems.md)、[docs/cn/Subsystems.md](Subsystems.md) 中的子系统状态列。
