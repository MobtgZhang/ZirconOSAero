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

//! GOP / 固件帧缓冲 handoff；与 `amd/display_handoff.zig` 同级语义：默认不编程显示管道。

const types = @import("types.zig");
const chip_class = @import("chip_class.zig");
const klog = @import("../../../../rtl/klog.zig");

pub fn initForFamily(family: types.NvidiaGpuFamily, mmio_virt: usize, kms_experimental: bool) types.DisplayInitResult {
    chip_class.logExperimentalMmioPeek(mmio_virt, kms_experimental);

    if (kms_experimental) {
        if (family == .unknown) {
            if (klog.DEBUG_MODE) klog.info("NVIDIA: experimental path skipped (family=unknown)", .{});
            return .handoff_only;
        }
        if (klog.DEBUG_MODE) {
            klog.info("NVIDIA: nvidia_kms_experimental — no engine writes; handoff only (family=%u)", .{
                @intFromEnum(family),
            });
        }
    }
    return .handoff_only;
}
