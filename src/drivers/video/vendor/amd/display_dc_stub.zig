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

//! Display Core / KMS 占位（计划 F1–F4）。
//!
//! **F1** Polaris 上 DC 依赖 VBIOS 表、SMU、时钟与 PHY；应对照 Linux `amdgpu_dm`、`dc/core`。
//! **F2** 最小模式集：单 CRTC + 单平面，或 GOP 分辨率验证路径。
//! **F3** 与 `hdmi.zig` 的 `syncFramebufferMode` / 连接器元数据衔接（见 `amd_igpu.resolveDesktopFramebuffer`）。
//! **F4** EDID / 热插拔在 KMS 就绪后接 DDC/AUX。

const types = @import("types.zig");

pub fn registerDcHandoffPath(family: types.AmdGpuFamily) void {
    _ = family;
}
