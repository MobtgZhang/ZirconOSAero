# NVMe 阶段 E2 — Partial 说明

本仓库 `src/drivers/storage/nvme_pci.zig` 已完成 **PCI 类 010802 发现** 与 **BAR0** 记录；**Admin 提交队列 / 完成队列、Identify Controller、NVMe Read LBA** 尚未接线至 `BlockDevVTable.read_blocks`（当前桩返回 `STATUS_NOT_IMPLEMENTED`）。

## 后续里程碑（clean-room）

- 映射 BAR0 MMIO，按 **NVMe Base Specification** 实现 Doorbell、CAP/MVSQ 探测。
- 建 Admin SQ/CQ，发 **Identify**，再建 IO SQ/CQ 与 **Read** 命令（与 `ahci.zig` 的 PRDT 路径类比）。
- 在 `pci_driver_bind.zig` 或存储探测文档中写明 **NVMe 与 AHCI 并存时的优先策略**（通常为 NVMe 优先）。

验收以 `zig build test` 与 QEMU 块设备烟测为准；本文件替代「空实现冒充完成」。
