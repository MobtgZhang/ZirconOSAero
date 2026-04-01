# 存储驱动与 I/O 栈路线图（AHCI / NVMe）

## 目标

- 在 **IRP 框架**（`src/io/`）下接入真实块设备，供 VFS / FAT32 / NTFS 使用。
- QEMU 优先：**AHCI**（`ich9-ahci` / `ahci`）与 **VirtIO blk**（若已存在则统一入口）。

## 阶段

1. **AHCI MVP**：端口实现寄存器读写、命令表、IDENTIFY、PIO/DMA 读扇区（单队列）。  
2. **集成**：`IRP_MJ_READ` / `IRP_MJ_WRITE` 完成例程与 VFS 缓冲。  
3. **NVMe**：队列对、CAP/MQES 探测、Admin + I/O 完成队列（长期）。

## 合规

- 仅依据 **AHCI 规范**、**NVMe 规范** 与 Microsoft Learn 上存储栈 **行为描述** 实现寄存器级驱动；不参考 Windows/ReactOS 驱动源码。

## 验证

- QEMU：`make run` + 挂载 FAT 镜像；CI 可扩展 `zig build test` 主机侧解析测试（不启动 QEMU）。
