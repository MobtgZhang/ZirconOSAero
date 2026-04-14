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

//! 桌面帧缓冲解析：`main.zig` 唯一入口。顺序：龙芯（LoongArch 有效）→ NVIDIA → Intel → AMD → GOP 原样。

const loongson_igpu = @import("../loongson_igpu.zig");
const nvidia_gpu = @import("../nvidia_gpu.zig");
const intel_igpu = @import("../intel_igpu.zig");
const amd_igpu = @import("../amd_igpu.zig");

pub const DesktopFb = intel_igpu.DesktopFb;

pub fn resolveDesktopFramebuffer(boot: DesktopFb) DesktopFb {
    const a = loongson_igpu.resolveDesktopFramebuffer(boot);
    const b = nvidia_gpu.resolveDesktopFramebuffer(a);
    const c = intel_igpu.resolveDesktopFramebuffer(b);
    return amd_igpu.resolveDesktopFramebuffer(c);
}
