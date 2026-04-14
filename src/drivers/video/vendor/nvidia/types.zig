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

//! NVIDIA 显示路径 — 与 Intel `DisplayInitResult` 对齐，便于 handoff / 未来 KMS 分阶段。

pub const DisplayInitResult = @import("../intel/types.zig").DisplayInitResult;

/// PCI DID 粗分代（启发式，非完整 nouveau pci 表；日志与实验路径用）
pub const NvidiaGpuFamily = enum(u8) {
    unknown = 0,
    legacy = 1,
    kepler = 2,
    maxwell = 3,
    pascal = 4,
    volta = 5,
    turing = 6,
    ampere = 7,
    ada_lovelace = 8,
};
