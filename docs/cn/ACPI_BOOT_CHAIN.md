# ACPI 表链引导叙述（阶段 I1–I4）

独立 clean-room 叙述；硬件行为以 ACPI 规范与固件表为准。

## 单一引导链（x86_64）

1. **RSDP**（`Rsdp`）：在 EBDA / UEFI 配置表 / 传统 BIOS 搜索得到，指向 **RSDT** 或 **XSDT**。
2. **XSDT / RSDT**：表头 + 若干 32/64 位物理指针，指向各 SSDT。
3. **常用子表**（本仓库解析/接线锚点）：
   - **FADT**（`FACP`）：固定硬件特性；关机/复位端口子集见 `hal/x86_64/acpi_pm.zig`（I3）。
   - **MADT**（`APIC`）：Local APIC、IOAPIC、处理器与中断重定向；见 `hal/x86_64/madt.zig`、SMP 启动 `smp_boot.zig`。
   - **MCFG**：PCIe ECAM；配置空间 MMIO 见 `hal/x86_64/acpi_pci_early.zig` 与 `drivers/bus/pcie.zig`（CF8/CFC 与 ECAM 统一经 `readConfigDword`）。
   - **HPET**：事件定时器 MMIO；与 `ke/timekeeping.zig`、`hal/x86_64/hpet.zig` 策略并列；**IRQ0 仍可由 PIT 提供 tick**，HPET 为可选主计时（I2）。

## I4：AML / 解释器

完整 **AML 执行与 DSDT 动态解析** 不在当前里程碑；非阻塞说明见 [NT61_DEFERRED_SURFACES.md](NT61_DEFERRED_SURFACES.md)。

## 参考

- ACPI 规范（UEFI Forum 公开发布）
- 本仓库：`acpi_core.zig`、`acpi_tables_parse.zig`、`acpi_pm.zig`、`hpet.zig`
