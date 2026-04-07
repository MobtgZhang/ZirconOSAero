// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/ioapic_route.zig
// Purpose: I/O APIC **重定向表**编程里程碑与诊断（QEMU q35 常见 `IOAPIC` MMIO 见 MADT；完整 IRQ 路由见 K2.5）。
//
// This is an independent clean-room implementation.
// Reference: Intel MultiProcessor Specification / ACPI MADT I/O APIC; https://wiki.osdev.org/IOAPIC

const klog = @import("../../rtl/klog.zig");
const madt = @import("madt.zig");

/// 典型默认物理基址（MADT 未解析时的参考；实际以 `madt.ioapic_mmio_phys` 为准）。
pub const ioapic_mmio_phys_typical: u32 = 0xFEC0_0000;

/// ACPI 解析后打印 IOAPIC 基址；**IOREDTBL** 编程须保证该 MMIO 窗口已映射（常高于 512MiB identity 窗口，需显式 `mapDeviceMmioIdentity`）。
/// **SCI（System Control Interrupt）**：GSIV 与极性/触发在 **FADT**（`acpi_core.g_fadt.sci_interrupt`）与 **MADT** 中给出；向 Local APIC / IOAPIC **I/O 重定向表** 编程为 K2.5 长期项。
/// 当前关机路径经 **PM1_CNT** 写 `SLP_EN`（`acpi_pm.zig`）**不依赖** SCI 投递；若实现 SCI，应在此模块或专用路由表中写入 IOREDTBL，并保证 MMIO 已 `mapDeviceMmioIdentity`。
pub fn logIoApicRedirectionMilestone() void {
    if (madt.ioapic_mmio_phys != 0) {
        klog.info("IOAPIC: MMIO phys=0x%x (redirect table + IRQ migration: milestone K2.5)", .{
            madt.ioapic_mmio_phys,
        });
    } else if (klog.DEBUG_MODE) {
        klog.debug("IOAPIC: no MADT type-1 entry (typical 0x%x)", .{ioapic_mmio_phys_typical});
    }
}
