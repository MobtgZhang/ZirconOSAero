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

//! 龙芯显示：阶段一仅登记 handoff；KMS/扫描出见后续里程碑（对齐 Etnaviv/DRM 文档后再写 MMIO）。

const types = @import("types.zig");

pub fn initForGeneration(
    generation: types.LoongsonGpuGeneration,
    mmio_virt: usize,
    kms_experimental: bool,
) types.DisplayInitResult {
    _ = generation;
    _ = mmio_virt;
    _ = kms_experimental;
    return .handoff_only;
}
