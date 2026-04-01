# USB / 网络栈分阶段路线图（clean-room）

与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §2.1 交叉引用。实现仅依据 **USB 规范摘要、IEEE/IANA 公开编号、教材级网络分层**，不参考 Windows 网络驱动或 Linux 内核源码。

## 阶段 A — USB XHCI（QEMU）

1. 自 PCI 能力结构或 ACPI 定位 XHCI MMIO 基址（在 `acpi_pci_early` 之后扩展）。
2. 主机控制器初始化、命令环、事件环最小子集。
3. HID 启动键盘/鼠标 → 与现有 PS/2 路径并行的输入事件注入（长期统一消息队列）。

## 阶段 B — 最小 IPv4 数据面

1. 以太网帧解析（VirtIO-net 或 e1000 择一，与 QEMU 默认对齐）。
2. ARP 学习与应答；本机 IPv4 地址静态配置。
3. UDP 套接字语义子集；**TCP 推迟**到单独里程碑。

## 阶段 C — 与 Win32 栈的边界

- 用户态 `socket` / Winsock 完整兼容 **非** 当前目标；先在 **内核烟测**（如 ping 网关 ARP、UDP echo）验证。

## 占位代码

`src/drivers/net/minimal_stack.zig` 提供 IPv4 固定首部解析（RFC 791）、协议号常量与 `NetStackPhase`；主机回归见 `zig build test` → **minimal_net**。阶段 B 将在此之上接 ARP/UDP。

## 存储（AHCI / NVMe）

块设备驱动与 VirtIO-blk 以外的 **AHCI / NVMe** 里程碑见 [Roadmap.md](../en/Roadmap.md) Next steps；依赖 `acpi_pci_early` ECAM 枚举与 PCI 类码过滤（与阶段 A 同一总线路径）。
