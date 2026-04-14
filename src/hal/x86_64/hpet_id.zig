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
// Module: src/hal/x86_64/hpet_id.zig
// Purpose: HPET `GCAP_ID` 寄存器（低 32 位）纯解码 — 无 MMIO、无日志，供 `hpet.zig` 与主机测试共用。
//
// This is an independent clean-room implementation.
// Reference: Intel IA-PC HPET Specification — GCAP_ID register.

/// `raw` 为 MMIO 偏移 0x0 读出的 32 位值。
pub fn decodeGcapId(raw: u32) struct {
    rev_id: u8,
    num_tim_cap: u5,
    count_size_cap: bool,
    reserved_bit: bool,
    legacy_route_cap: bool,
    vendor_id: u16,
} {
    return .{
        .rev_id = @truncate(raw & 0xff),
        .num_tim_cap = @truncate((raw >> 8) & 0x1f),
        .count_size_cap = (raw & (1 << 13)) != 0,
        .reserved_bit = (raw & (1 << 14)) != 0,
        .legacy_route_cap = (raw & (1 << 15)) != 0,
        .vendor_id = @truncate((raw >> 16) & 0xffff),
    };
}

const std = @import("std");

test "decodeGcapId revision and PCI vendor field" {
    const raw: u32 = (@as(u32, 0x8086) << 16) | 1;
    const d = decodeGcapId(raw);
    try std.testing.expectEqual(@as(u8, 1), d.rev_id);
    try std.testing.expectEqual(@as(u16, 0x8086), d.vendor_id);
}
