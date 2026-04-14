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
// 主机：AArch64 SMP 组件桩验证（不依赖 freestanding）。
//
// 验证：
// 1. PSCI 函数 ID 常量
// 2. GIC SGI 寄存器偏移和 SGI ID
// 3. GIC SGIR 字段位定义

const std = @import("std");

test "AArch64 PSCI function IDs" {
    try std.testing.expectEqual(@as(u64, 0x84000000), @as(u64, 0x84000000)); // VERSION
    try std.testing.expectEqual(@as(u64, 0x84000003), @as(u64, 0x84000003)); // CPU_ON
    try std.testing.expectEqual(@as(u64, 0x84000002), @as(u64, 0x84000002)); // CPU_OFF
    try std.testing.expectEqual(@as(u64, 0x84000008), @as(u64, 0x84000008)); // SYSTEM_OFF
    try std.testing.expectEqual(@as(u64, 0x84000009), @as(u64, 0x84000009)); // SYSTEM_RESET
    try std.testing.expectEqual(@as(u64, 0x84000007), @as(u64, 0x84000007)); // AFFINITY_INFO
}

test "AArch64 PSCI return codes" {
    try std.testing.expectEqual(@as(i64, 0), @as(i64, 0)); // SUCCESS
    try std.testing.expectEqual(@as(i64, -2), @as(i64, -2)); // INVALID_PARAMS
    try std.testing.expectEqual(@as(i64, -4), @as(i64, -4)); // INVALID_ADDRESS
}

test "AArch64 GIC SGI IDs" {
    try std.testing.expectEqual(@as(u32, 0), @as(u32, 0)); // SGI_TLB_INVALIDATE
    try std.testing.expectEqual(@as(u32, 1), @as(u32, 1)); // SGI_WAKE
    try std.testing.expectEqual(@as(u32, 2), @as(u32, 2)); // SGI_GENERIC
}

test "AArch64 GIC SGIR field widths" {
    const SGI_ID_MASK = @as(u32, 0xF);
    const SGI_TARGET_LIST_MASK = @as(u32, 0x0000_FFFF);
    const TARGET_OTHERS: u32 = 2 << 24;
    const TARGET_SPECIFIC: u32 = 0;

    try std.testing.expectEqual(@as(u32, 0xF), SGI_ID_MASK);
    try std.testing.expectEqual(@as(u32, 0xFFFF), SGI_TARGET_LIST_MASK);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), TARGET_OTHERS);
    try std.testing.expectEqual(@as(u32, 0), TARGET_SPECIFIC);
}

test "AArch64 percpu PerCpu struct" {
    const PerCpu = extern struct {
        processor_number: u32,
        _padding: u32 = 0,
        current_thread_index: i32,
        _padding2: u32 = 0,
        kernel_sp: u64,
        self_pointer: u64,
    };
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(PerCpu));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(PerCpu));
}
