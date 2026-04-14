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

//! QEMU `loongarch` virt：PCH PIC MMIO @ VIRT_PCH_REG_BASE（见 QEMU `include/hw/loongarch/virt.h`）。
//! EXTIOI 经 pch 汇聚后上报为 CPU HWI；边沿 IRQ 需在 PCH_PIC_INT_CLEAR 清 pending。

const vm = @import("../../mm/vm.zig");
const klog = @import("../../rtl/klog.zig");

/// 与 QEMU `VIRT_PCH_REG_BASE` 一致
pub const VIRT_PCH_REG_BASE: usize = 0x10000000;
pub const VIRT_PCH_REG_SIZE: usize = 0x400;

const OFF_MASK: usize = 0x20;
const OFF_EDGE: usize = 0x60;
const OFF_CLEAR: usize = 0x80;
const OFF_STATUS: usize = 0x3A0;

var mapped: bool = false;

fn mmio64(off: usize) *volatile u64 {
    return @ptrFromInt(VIRT_PCH_REG_BASE + off);
}

pub fn ensureMapped() void {
    if (mapped) return;
    if (!vm.mapDeviceMmioIdentity(VIRT_PCH_REG_BASE, VIRT_PCH_REG_SIZE)) {
        klog.warn("LoongArch PCH: mapDeviceMmioIdentity failed @0x%x", .{VIRT_PCH_REG_BASE});
        return;
    }
    mapped = true;
}

pub fn init() void {
    ensureMapped();
    if (!mapped) return;
    mmio64(OFF_MASK).* = 0;
    klog.info("LoongArch PCH: unmasked (MMIO 0x%x)", .{VIRT_PCH_REG_BASE});
}

/// 清边沿类 pending（QEMU `PCH_PIC_INT_CLEAR`）；电平型由设备拉低后自动清。
pub fn ackPchPending() void {
    if (!mapped) return;
    const pending = mmio64(OFF_STATUS).*;
    if (pending == 0) return;
    const edge = mmio64(OFF_EDGE).*;
    var bits = pending;
    while (bits != 0) {
        const i = @ctz(bits);
        const bit: u64 = @as(u64, 1) << @intCast(i);
        if ((edge & bit) != 0) {
            mmio64(OFF_CLEAR).* = bit;
        }
        bits &= ~bit;
    }
}
