// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/ecam_layout.zig
// Purpose: PCIe ECAM（MCFG）配置空间 MMIO 字节偏移计算 — 无 MMIO 访问，供 `acpi_pci_early` 与主机单测共用。
//
// This is an independent clean-room implementation.
// Reference: PCI Express Base Specification — Enhanced Configuration Access Mechanism; ACPI MCFG.

/// 段内总线号 `bus_within_segment` 须已减去 MCFG 条目的 `StartBusNumber`（与 `acpi_pci_early.configRead32` 一致）。
/// `register` 为 PCI 配置空间字节偏移；返回值为相对 ECAM 物理基址的字节偏移（dword 对齐）。
pub fn pciConfigDwordOffset(bus_within_segment: u8, device: u8, function: u8, register: u8) u64 {
    const r = register & 0xfc;
    return (@as(u64, bus_within_segment) << 20) |
        (@as(u64, device & 0x1f) << 15) |
        (@as(u64, function & 7) << 12) |
        @as(u64, r);
}

const std = @import("std");

test "ECAM pciConfigDwordOffset bus0 dev0" {
    try std.testing.expectEqual(@as(u64, 0), pciConfigDwordOffset(0, 0, 0, 0));
}

test "ECAM pciConfigDwordOffset device stride" {
    try std.testing.expectEqual(@as(u64, 0x8000), pciConfigDwordOffset(0, 1, 0, 0));
}

test "ECAM pciConfigDwordOffset dword-aligns register" {
    try std.testing.expectEqual(pciConfigDwordOffset(0, 0, 0, 4), pciConfigDwordOffset(0, 0, 0, 5));
}
