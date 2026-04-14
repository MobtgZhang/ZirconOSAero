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

//! 实验性探测（计划 D1）：默认 **不写 MMIO**；仅配合 `amd_kms_experimental` 做表面登记。
//! 真寄存器只读需按 ASIC 填偏移表；盲目读可能挂死部分平台。

const klog = @import("../../../../rtl/klog.zig");
const types = @import("types.zig");

pub fn logHandoffDiagnostics(family: types.AmdGpuFamily, mmio_virt: usize, kms_experimental: bool) void {
    if (!kms_experimental) return;
    if (family == .unknown) return;
    if (klog.DEBUG_MODE) {
        klog.info("AMD MMIO probe: family=%u mmio_virt=0x%x (handoff-only; no MMIO reads)", .{
            @intFromEnum(family),
            mmio_virt,
        });
    }
}
