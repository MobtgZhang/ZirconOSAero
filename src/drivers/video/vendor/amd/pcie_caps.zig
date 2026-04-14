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

//! PCI 标准能力链表遍历与 ROM BAR 快照（计划 B3–B4，只读配置空间）。
//! x86_64 I/O CF8/CFC 仅保证 256B 传统配置空间；扩展能力在 ECAM 架构上可读。

const klog = @import("../../../../rtl/klog.zig");
const pcie = @import("../../../bus/pcie.zig");

fn capIdName(id: u8) []const u8 {
    return switch (id) {
        0x01 => "PM",
        0x02 => "AGP",
        0x03 => "VPD",
        0x04 => "SlotID",
        0x05 => "MSI",
        0x06 => "CHSWP",
        0x07 => "PCIX",
        0x08 => "HT",
        0x09 => "Vendor",
        0x0A => "Debug",
        0x0B => "CRC",
        0x0D => "HotPlug",
        0x0E => "SSVID",
        0x10 => "PCIe",
        0x11 => "MSI-X",
        0x12 => "SATA",
        else => "Other",
    };
}

/// 遍历偏移 0x34 起的标准 capability 链表（type 0 设备头）。
pub fn logStandardCapabilities(loc: pcie.PciLoc) void {
    if (!klog.DEBUG_MODE) return;
    var off: u16 = @as(u16, pcie.readConfigByte(loc.bus, loc.dev, loc.func, 0x34)) & 0xFC;
    if (off < 0x40) return;
    var guard: u32 = 0;
    while (off != 0 and guard < 48) : (guard += 1) {
        const id = pcie.readConfigByte(loc.bus, loc.dev, loc.func, off);
        const next = @as(u16, pcie.readConfigByte(loc.bus, loc.dev, loc.func, off + 1)) & 0xFC;
        klog.info("AMD PCI cap: off=0x%x id=0x%x (%s)", .{ off, id, capIdName(id) });
        if (next == off or next < 0x40) break;
        off = next;
    }
}

/// 配置空间 0x30：Expansion ROM Base Address（只读日志；映像由固件/驱动策略决定）。
pub fn logExpansionRomRegister(loc: pcie.PciLoc) void {
    if (!klog.DEBUG_MODE) return;
    const rom = pcie.readConfigDword(loc.bus, loc.dev, loc.func, 0x30);
    klog.info("AMD PCI expansion ROM register raw=0x%x", .{rom});
}

/// 链路命令字（0x04）中的 Bus Master / Memory Space 状态。
pub fn logPciCommandSummary(loc: pcie.PciLoc) void {
    if (!klog.DEBUG_MODE) return;
    const cmd = pcie.readConfigWord(loc.bus, loc.dev, loc.func, 0x04);
    klog.info("AMD PCI command reg=0x%x (mem=%u bus_master=%u)", .{
        cmd,
        @intFromBool((cmd & 2) != 0),
        @intFromBool((cmd & 4) != 0),
    });
}
