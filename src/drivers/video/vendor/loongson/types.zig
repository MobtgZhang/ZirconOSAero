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

pub const LoongsonGpuGeneration = enum(u8) {
    unknown = 0,
    vivante_ls2k1000 = 1,
    vivante_7a1000 = 2,
    lg100_7a2000 = 3,
    lg200 = 4,
};

pub const DisplayInitResult = enum(u8) {
    failed = 0,
    /// 仅与 UEFI GOP / ramfb handoff 对齐，不做模式集
    handoff_only = 1,
};
