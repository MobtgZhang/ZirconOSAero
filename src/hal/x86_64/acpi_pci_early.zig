// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/acpi_pci_early.zig
// Purpose: 自 `acpi_core` 已解析的 **MCFG** 提供 PCIe ECAM `configRead32`；PCI 枚举与 `pcie.zig` 统一。
//
// This is an independent clean-room implementation.
// Reference: ACPI MCFG; PCI Express ECAM. 表遍历见 `acpi_core.zig`。

const ecam_layout = @import("ecam_layout.zig");
const klog = @import("../../rtl/klog.zig");
const acpi_core = @import("acpi_core.zig");

var ecam_base_phys: u64 = 0;
var ecam_segment: u16 = 0;
var ecam_bus_lo: u8 = 0;
var ecam_bus_hi: u8 = 0;

/// 在 `acpi_core.initFromRsdp` 之后调用，将 MCFG 快照复制到本模块（供 ECAM MMIO 读）。
pub fn loadFromAcpiCore() void {
    const m = acpi_core.g_mcfg;
    ecam_base_phys = m.base_phys;
    ecam_segment = m.segment;
    ecam_bus_lo = m.bus_lo;
    ecam_bus_hi = m.bus_hi;
}

/// 兼容入口：`acpi_core.initFromRsdp` + `loadFromAcpiCore` + PCI 烟测。
pub fn initFromRsdp(rsdp_phys: usize) void {
    acpi_core.initFromRsdp(rsdp_phys);
    loadFromAcpiCore();
    if (acpi_core.pm1aControlIoPort() != 0) {
        klog.info("ACPI/PCI: FADT PM1a_CNT_BLK I/O port=0x%x (S5 见 acpi_pm.zig)", .{
            acpi_core.pm1aControlIoPort(),
        });
    }
    if (ecam_base_phys == 0) {
        klog.info("ACPI/PCI: MCFG not found or unusable (ECAM disabled)", .{});
        return;
    }
    klog.info("ACPI/PCI: ECAM base=0x%x seg=%u buses %u..%u", .{
        ecam_base_phys,
        ecam_segment,
        ecam_bus_lo,
        ecam_bus_hi,
    });
    const id_lo = configRead32(0, 0, 0, 0);
    klog.info("ACPI/PCI: cfg[0:0.0] vendor=0x%x device=0x%x", .{
        @as(u16, @truncate(id_lo & 0xffff)),
        @as(u16, @truncate(id_lo >> 16)),
    });
    if (DEBUG_MODE) logBus0Function0Snapshot();
    noteVirtioDevicesOnBus0();
}

pub fn pm1aControlIoPort() u16 {
    return acpi_core.pm1aControlIoPort();
}

/// 总线 0 快速扫描：通知 VirtIO 块设备等占位驱动（不依赖 DEBUG_MODE）。
fn noteVirtioDevicesOnBus0() void {
    const virtio_blk_pci = @import("../../drivers/storage/virtio_blk_pci.zig");
    var d: u8 = 0;
    while (d < 32) : (d += 1) {
        const id = configRead32(0, d, 0, 0);
        const ven = @as(u16, @truncate(id & 0xffff));
        if (ven == 0xffff) continue;
        const did = @as(u16, @truncate(id >> 16));
        virtio_blk_pci.noteVirtioBlkIfPresent(ven, did);
    }
}

const DEBUG_MODE = @import("build_options").debug;

fn logBus0Function0Snapshot() void {
    var present: u32 = 0;
    var d: u8 = 0;
    while (d < 32) : (d += 1) {
        const id = configRead32(0, d, 0, 0);
        const ven = @as(u16, @truncate(id & 0xffff));
        if (ven == 0xffff) continue;
        present += 1;
        if (present <= 12) {
            klog.debug("ACPI/PCI: bus0 dev%u func0 vid=0x%x did=0x%x", .{
                d,
                ven,
                @as(u16, @truncate(id >> 16)),
            });
        }
    }
    klog.debug("ACPI/PCI: bus0 function0 present count=%u (up to 12 logged)", .{present});
}

pub fn configRead32(bus: u8, dev: u8, func: u8, reg: u16) u32 {
    if (ecam_base_phys == 0) return 0xffff_ffff;
    if (bus < ecam_bus_lo or bus > ecam_bus_hi) return 0xffff_ffff;
    if (reg > 0x0FFC) return 0xffff_ffff;
    const off = ecam_layout.pciConfigDwordOffset(bus - ecam_bus_lo, dev, func, reg);
    const addr = ecam_base_phys + off;
    const ptr: *align(1) const volatile u32 = @ptrFromInt(@as(usize, @truncate(addr)));
    return ptr.*;
}

pub fn configWrite32(bus: u8, dev: u8, func: u8, reg: u16, value: u32) void {
    if (ecam_base_phys == 0) return;
    if (bus < ecam_bus_lo or bus > ecam_bus_hi) return;
    if (reg > 0x0FFC) return;
    const off = ecam_layout.pciConfigDwordOffset(bus - ecam_bus_lo, dev, func, reg);
    const addr = ecam_base_phys + off;
    const ptr: *align(1) volatile u32 = @ptrFromInt(@as(usize, @truncate(addr)));
    ptr.* = value;
}

pub fn hasEcam() bool {
    return ecam_base_phys != 0;
}
