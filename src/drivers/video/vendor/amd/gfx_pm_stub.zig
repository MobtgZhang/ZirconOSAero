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

//! 图形命令提交与电源管理占位（计划 G1–G3）。
//!
//! **G1** CP ring、PM4、IB、fence — 参考 `amdgpu` `gfx_v8_0`。
//! **G2** D0/D3hot、动态频率与系统休眠协调。
//! **G3** 用户态 API（WDDM / 自研 ioctl）单独立项。

const types = @import("types.zig");

pub fn registerGfxHandoffPath(family: types.AmdGpuFamily) void {
    _ = family;
}
