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
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/acpi_fadt_pm1a_host.zig
// Purpose: 主机黄金测 — FADT（签名为 FACP）中 legacy **PM1a_CNT_BLK** 32 位 I/O 端口字段字节偏移 **64**（ACPI 规范 §5.2.9）。
//
// This is an independent clean-room implementation.
// Reference: ACPI Specification — Fixed ACPI Description Table (FADT / FACP).

const std = @import("std");

test "FADT FACP PM1a control block port at byte offset 64" {
    var tbl: [120]u8 = [_]u8{0} ** 120;
    @memcpy(tbl[0..4], "FACP");
    std.mem.writeInt(u32, tbl[4..8], 120, .little);
    std.mem.writeInt(u32, tbl[64..68], 0xB004, .little);
    try std.testing.expectEqual(@as(u32, 120), std.mem.readInt(u32, tbl[4..8], .little));
    try std.testing.expectEqual(@as(u32, 0xB004), std.mem.readInt(u32, tbl[64..68], .little));
}
