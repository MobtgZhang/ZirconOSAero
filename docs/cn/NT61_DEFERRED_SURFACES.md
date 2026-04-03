# NT 6.1 目标下明确延后的表面（内核里程碑不阻塞项）

本文档与 [docs/en/Roadmap.md](../en/Roadmap.md) 第 6 节 **Deferred surfaces** 一致，说明在 **MM / SMP / 进程隔离 / I/O 基线** 稳定之前，**不**作为内核主里程碑阻塞的跟踪项。实现须保持 clean-room（仅 MS Learn、WDK 公开描述与硬件规范）。

## 延后项列表

| 跟踪项 | 说明 |
|--------|------|
| 完整 WDDM / GPU 离屏合成 | 当前为 CPU 帧缓冲与软件合成演示路径；不声称与 Windows 7 显示驱动模型等价；可选里程碑见 `virtio_gpu` / `HAL_USB_NET_ROADMAP.md` 中的显示加速条目。 |
| 完整 Win32 / user32 / gdi32 | 子系统与壳在 `src/subsystems/win32/`、`src/desktop/aero/`；在内核对象与 VM 语义收紧后扩展。 |
| 完整 WOW64 / `wow64cpu` 类语义 | 阶段 G 已落地 **可测子集**（thunk、`marshal`、UTF-16 文件与 HKLM\SOFTWARE 重定向、`ProcessWow64Information`、ZOA 槽 `NtTerminateThread`）；**仍延后**：x86 用户态指令级仿真与 SEH32、商业 `ntdll32` 加载、**HKCR/HKCU** 等逻辑视图的完整镜像、`NtEnumerateKey`/`NtQueryValueKey` 相对 **OpenKey** 的额外重解析策略、与商业 SysWOW64 **逐 API 全量等价**。见 `wow64/`、`ssdt_nt61.zig`、`PHASE_G_WOW64.md`。 |
| NT 32 级优先级与完整 boost | 调度器为文档语义的近似；见 [SCHEDULER_API.md](SCHEDULER_API.md)。 |
| 完整 TCP / 生产级网络栈 | IPv4/UDP 等为路线图原型；见 [HAL_USB_NET_ROADMAP.md](HAL_USB_NET_ROADMAP.md)。 |
| ACPI AML 解释器 | 无 AML 时依赖静态表与 QEMU 路径；引入 AML 须单独里程碑与审计。 |
| ACPI S1–S4、`_PTS`/`_WAK`、嵌入式控制器（EC）全量睡眠 | **I10**：关机/复位可走 FADT 固定寄存器子集；**深度睡眠与 AML 状态机**与本里程碑解耦，不阻塞 I7/I8。 |

## 跨进程 HWND 与共享表面（非当前目标）

本仓库 **不** 将「进程 A 的线程直接操作进程 B 的 `HWND` 队列」或「内核 `RedirectedSurface` 跨进程共享 VM」作为 NT 6.1 子集验收项；与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §4.1「跨进程 HWND」行一致。

**未来草图（clean-room，无内部 NT 结构臆测）**：可通过 (1) 显式 **IOCTL** 或 **LPC 大消息** 携带「目标会话 + surface id + 能力令牌」；(2) 对象管理器侧 **句柄复制** 与桌面门闸扩展；(3) 节区视图映射用户位图到 **单一所有者进程** 的合成路径。落地前须 bump [LPC_NT61_HANDSHAKE.md](LPC_NT61_HANDSHAKE.md) 版本并增主机载荷布局测试。

## 维护

调整延后边界时，同步更新本文件、[NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md)、根 [README.md](../../README.md) / [README_cn.md](../../README_cn.md) 的 Design 表述，以及 [docs/en/Subsystems.md](../en/Subsystems.md)、[docs/cn/Subsystems.md](Subsystems.md) 中的子系统状态列。
