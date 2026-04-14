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

//! GMC / VRAM 可见性与 GART 规划接口（计划 E1–E3）。
//!
//! **E1** CPU 可见 GOP 帧缓冲通常经 VRAM aperture 或固件映射；Polaris 完整路径需 GMC/VM L2。
//! **E2** 当前为 GOP handoff **no-op**；后续在此实现页表安装与 TLB flush，与 `GmcHandoffParams` 对齐。
//! **E3** 若内核引入 IOMMU/ATS，DMA 策略与此模块协同。

const klog = @import("../../../../rtl/klog.zig");

pub const GmcHandoffParams = struct {
    reg_mmio_phys: u64 = 0,
    vram_aperture_phys: u64 = 0,
    vram_aperture_size: u64 = 0,
    fb_phys: u64,
    fb_size: usize,
};

pub fn installFramebufferGmcStub(p: GmcHandoffParams) bool {
    if (klog.DEBUG_MODE) {
        klog.info("AMD GMC: GOP handoff stub reg_mmio=0x%x vram_ap=0x%x/0x%x fb=0x%x bytes=0x%x (E2 TLB no-op)", .{
            p.reg_mmio_phys,
            p.vram_aperture_phys,
            p.vram_aperture_size,
            p.fb_phys,
            p.fb_size,
        });
    }
    return true;
}
