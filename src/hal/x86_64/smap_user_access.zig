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

// SPDX-License-Identifier: MIT OR Apache-2.0
// SMAP：在 syscall 分发期间临时允许内核解引用用户 VA（`stac`/`clac`）。见 Intel SDM Vol.3 4.6。
const builtin = @import("builtin");
const mitigations = @import("mitigations.zig");

pub fn syscallEnterAllowUserMemory() void {
    if (builtin.cpu.arch != .x86_64) return;
    if (!mitigations.smapEnabled()) return;
    asm volatile ("stac"
        :
        :
        : .{ .memory = true });
}

pub fn syscallExitRestoreSmap() void {
    if (builtin.cpu.arch != .x86_64) return;
    if (!mitigations.smapEnabled()) return;
    asm volatile ("clac"
        :
        :
        : .{ .memory = true });
}
