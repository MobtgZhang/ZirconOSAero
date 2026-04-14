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

//! 龙芯 PCI 显示控制器 DID 白名单（Vendor 0x0014，class 0x03）。
//! 参考 pci.ids / Linux DRM（Etnaviv on Loongson）及社区资料；**实机请以 `lspci -nn` 为准**。
//!
//! | DID   | 常见关联（资料级，非龙芯官方承诺） |
//! |-------|--------------------------------------|
//! | 0x7a05 | LS2K1000 等 SoC 侧 Vivante |
//! | 0x7a15 | 7A1000 桥片集显 |
//! | 0x7a25 | 7A2000 / LG100 一代 |
//! | LG200 | 具体 DID 需在目标板上确认后补入 `supported_display_dids` |

/// 当前驱动阶段一仅对下列 DID 建立 MMIO 映射；其余 0014:03 设备忽略以免误触未知硬件。
pub const supported_display_dids: []const u16 = &.{
    0x7a05,
    0x7a15,
    0x7a25,
};

pub fn isSupportedDisplayDid(did: u16) bool {
    for (supported_display_dids) |d| {
        if (d == did) return true;
    }
    return false;
}
