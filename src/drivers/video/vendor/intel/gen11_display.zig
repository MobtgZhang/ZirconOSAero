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

//! Gen11（Ice Lake 等）— 显示寄存器块与 Gen9 有差异；当前与 handoff 路径共用探测骨架

const types = @import("types.zig");
const gen9 = @import("gen9_display.zig");
const klog = @import("../../../../rtl/klog.zig");

pub fn initPipelineHandoffOnly(mmio_base: usize, kms_experimental: bool) types.DisplayInitResult {
    const r = gen9.initPipelineHandoffOnly(mmio_base, kms_experimental);
    if (klog.DEBUG_MODE) {
        klog.info("Intel Gen11 display: using Gen11 init path (handoff)", .{});
    }
    return r;
}
