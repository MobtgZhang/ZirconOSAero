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
//
// ZirconOSAero — PEB/TEB 稳定偏移与 `sdk/object_layout_nt61.zig` 对齐（NT 6.1 x64 主机断言）。
//
// This is an independent clean-room implementation.
// Ref: MS Learn — PEB / TEB（字段子集）；`teb` 模块见 `src/sdk/teb_nt61_x64.zig`。

const std = @import("std");
const lay = @import("object_layout_nt61");
const teb = @import("teb");

test "sdk PEB BeingDebugged offset matches MS Learn x64" {
    try std.testing.expectEqual(@as(usize, 0x02), lay.peb_being_debugged_offset_x64);
}

test "sdk PEB ImageBaseAddress offset documented x64" {
    try std.testing.expectEqual(@as(usize, 0x10), lay.peb_image_base_address_offset_x64);
}

test "TEB self pointer offset x64" {
    try std.testing.expectEqual(@as(usize, 0x30), lay.teb_self_offset_x64);
    try std.testing.expectEqual(@as(usize, 0x68), @offsetOf(teb.TebNt61X64, "LastErrorValue"));
}
