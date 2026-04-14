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

//! DID → `AmdGpuFamily`。未知 DID 返回 `.unknown`（仍允许 PCI 探测 + GOP handoff）。

const types = @import("types.zig");
const dids = @import("dids.zig");

pub fn familyFromDeviceId(device_id: u16) types.AmdGpuFamily {
    // amdgpu 现代离散 / Navi / Vega（须在 0x6600–0x68FF legacy 桶之前）
    if (dids.classifyAmdgpuDiscrete(device_id)) |f| return f;

    // Stoney Ridge (amdgpu CHIP_STONEY; 常见 0x98Ex)
    if (device_id >= 0x98E0 and device_id <= 0x98FF) return .stoney;

    // Carrizo + Bristol Ridge
    if (device_id >= 0x9870 and device_id <= 0x987F) return .carrizo;

    // Raven / Renoir（Ryzen APU，DID 在 0x15xx / 0x16xx）
    switch (device_id) {
        0x15D8, 0x15DD => return .raven,
        0x15E7, 0x1636, 0x1638, 0x164C => return .renoir,
        else => {},
    }

    // Kaveri APU
    if (device_id >= dids.kaveri_range_first and device_id <= dids.kaveri_range_last) return .kaveri;

    // Kabini / Temash / Beema
    if (device_id >= dids.kabini_range_first and device_id <= dids.kabini_range_last) return .kabini;

    // Mullins
    if (device_id >= dids.mullins_range_first and device_id <= dids.mullins_range_last) return .mullins;

    // Trinity / Richland（扩展段）
    if (device_id >= 0x9900 and device_id <= 0x991F) return .trinity_richland;

    // Llano 及周边 APU
    if (device_id >= 0x9640 and device_id <= 0x964F) return .llano;

    // RS880 等北桥集显 / 老 IGP（片段）
    switch (device_id) {
        0x9710, 0x9712, 0x9713, 0x9714, 0x9715, 0x9802, 0x9803, 0x9804, 0x9805, 0x9806, 0x9807 => return .rs880_igp,
        else => {},
    }

    // GCN Southern Islands（Tahiti 等）— 与 Polaris 0x67C0+ 区分
    if (dids.isGcnSouthernIslands(device_id)) return .gcn_southern_islands;

    if (dids.isGcnHawaii(device_id)) return .gcn_hawaii;

    // 其它 Northern Islands / 老 SI 等（勿与 amdgpu 新 ASIC 寄存器混用）
    if (device_id >= 0x6600 and device_id <= 0x68FF) return .legacy_ni_si;

    return .unknown;
}
