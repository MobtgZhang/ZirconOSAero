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

//! Gen9 / Gen9.5 显示引擎 — 最小 MVP：验证 MMIO 可读 + 固件 handoff 策略
//! 完整 KMS（CDCLK / DDI / pipe）需对照 SKL/KBL PRM 与 `i915_display.c` 逐步实现。

const types = @import("types.zig");
const klog = @import("../../../../rtl/klog.zig");

/// SKL 显示仲裁器/侧带区域附近只读探测（偏移因平台而异；失败不视为致命）
fn tryReadDisplayId(mmio_base: usize) ?u32 {
    if (mmio_base == 0) return null;
    const p = mmio_base + 0x44000;
    const v = @as(*const volatile u32, @ptrFromInt(p)).*;
    if (v == 0xFFFFFFFF) return null;
    return v;
}

pub fn initPipelineHandoffOnly(mmio_base: usize, kms_experimental: bool) types.DisplayInitResult {
    if (mmio_base == 0) return .failed;
    if (!kms_experimental) return .handoff_only;
    if (tryReadDisplayId(mmio_base)) |id| {
        if (klog.DEBUG_MODE) {
            klog.info("Intel Gen9 display: MMIO probe ok (sample=0x%x)", .{id});
        }
    } else if (klog.DEBUG_MODE) {
        klog.info("Intel Gen9 display: MMIO probe inconclusive (handoff still ok)", .{});
    }
    return .handoff_only;
}
