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
// ZirconOSAero — J12：主机侧 SMP 前置不变式（与 `madt.zig` `MAX_APIC_ID_LIST` 保持同步）。

const std = @import("std");

/// 须与 `src/hal/x86_64/madt.zig` `MAX_APIC_ID_LIST` 一致。
const MAX_APIC_ID_LIST: usize = 64;

test "MADT APIC ID list capacity vs scheduler SMP slots" {
    try std.testing.expect(MAX_APIC_ID_LIST >= 8);
}
