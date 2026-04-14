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

//! Intel iGPU driver — shared types

pub const IntelGpuGeneration = enum(u8) {
    unknown = 0,
    gen6 = 6,
    gen7 = 7,
    gen8 = 8,
    gen9 = 9,
    gen9_5 = 10,
    gen11 = 11,
    gen12_plus = 12,
};

pub const DisplayInitResult = enum(u8) {
    /// 仅使用固件/GOP 已建立的线性帧缓冲，不编程显示管道
    handoff_only = 0,
    /// 已尝试最小 KMS（未来）
    kms_partial = 1,
    failed = 2,
};
