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

//! 探测失败时的 BDF + BAR 转储（计划 D3）。

const klog = @import("../../../../rtl/klog.zig");
const pcie = @import("../../../bus/pcie.zig");

pub fn logDeviceDump(dev: *const pcie.DisplayGfxPciInfo, reason: []const u8) void {
    klog.warn("AMD display: %s — BDF %u:%u:%u VID=0x%x DID=0x%x rev=0x%x class=0x%x", .{
        reason,
        dev.loc.bus,
        dev.loc.dev,
        dev.loc.func,
        dev.vendor_id,
        dev.device_id,
        dev.revision_id,
        dev.class_code,
    });
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const bar = dev.bars[i];
        if (bar.size == 0 and bar.base == 0) continue;
        klog.warn("AMD BAR[%u] base=0x%x size=0x%x io=%u pf=%u", .{
            i,
            bar.base,
            bar.size,
            @intFromBool(bar.is_io),
            @intFromBool(bar.prefetchable),
        });
    }
}
