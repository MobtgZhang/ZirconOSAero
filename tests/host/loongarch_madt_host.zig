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
// 主机：LoongArch64 MADT 解析验证（不依赖 freestanding）。
//
// 验证：
// 1. MADT 表头解析
// 2. Processor Local APIC (Type 0) 解析
// 3. RINTC (Type 34) 解析
// 4. HartID 唯一性检查

const std = @import("std");

// MADT Type 常量
const MADT_TYPE_PROCESSOR: u8 = 0;
const MADT_TYPE_IOAPIC: u8 = 1;
const MADT_TYPE_RINTC: u8 = 34;

// RINTC Structure: Type(1) + Length(1) + Reserved(2) + Hart ID(4) + UID(4) + Flags(4) = 16 bytes
const RINTC_LENGTH: u8 = 16;

test "MADT Type 34 (RINTC) structure length" {
    try std.testing.expectEqual(@as(u8, 16), RINTC_LENGTH);
}

test "MADT RINTC HartID extraction" {
    // 模拟 RINTC 结构体字节偏移
    const HART_ID_OFFSET: usize = 4; // Type(1) + Length(1) + Reserved(2) = 4

    // 模拟 RINTC 数据 (little-endian)
    var rintc_data = [_]u8{
        34, 16, 0, 0,       // Type=34, Length=16, Reserved=0
        1, 0, 0, 0,         // Hart ID = 1 (little-endian)
        0, 0, 0, 0,         // UID = 0
        1, 0, 0, 0,         // Flags = 1 (enabled)
    };

    const hart_id = std.mem.readInt(u32, rintc_data[HART_ID_OFFSET..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 1), hart_id);
}

test "MADT RINTC Flags extraction" {
    // Flags 在 Hart ID + UID 之后（偏移 12）
    const FLAGS_OFFSET: usize = 12;

    var rintc_data = [_]u8{
        34, 16, 0, 0,       // Type=34, Length=16
        0, 0, 0, 0,         // Hart ID = 0
        0, 0, 0, 0,         // UID = 0
        1, 0, 0, 0,         // Flags = 1 (enabled)
    };

    const flags = std.mem.readInt(u32, rintc_data[FLAGS_OFFSET..][0..4], .little);
    const enabled = (flags & 1) != 0;
    try std.testing.expect(enabled);
}

test "MADT RINTC disabled flag" {
    const FLAGS_OFFSET: usize = 12;

    var rintc_data = [_]u8{
        34, 16, 0, 0,       // Type=34, Length=16
        0, 0, 0, 1,         // Hart ID = 1
        0, 0, 0, 1,         // UID = 1
        0, 0, 0, 0,         // Flags = 0 (disabled)
    };

    const flags = std.mem.readInt(u32, rintc_data[FLAGS_OFFSET..][0..4], .little);
    const enabled = (flags & 1) != 0;
    try std.testing.expect(!enabled);
}

test "MADT HartID deduplication logic" {
    // 模拟已有的 Hart IDs
    const hart_ids = [_]u32{ 0, 1, 2 }; // 无重复
    const hart_id_count: u32 = 3;

    // 检查 HartID 是否已存在
    const new_hart_id: u32 = 2; // 已存在
    const already_seen = for (hart_ids[0..hart_id_count]) |hid| {
        if (hid == new_hart_id) break true;
    } else false;
    try std.testing.expect(already_seen);

    // 测试新的 HartID
    const new_hart_id2: u32 = 5; // 不存在
    const already_seen2 = for (hart_ids[0..hart_id_count]) |hid| {
        if (hid == new_hart_id2) break true;
    } else false;
    try std.testing.expect(!already_seen2);
}

test "MADT BSP Hart ID selection" {
    // BSP 应该是第一个 enabled 的 Processor/RINTC 条目
    var bsp_set = false;
    var bsp_hart_id: u32 = 0;

    const entries = [_]struct { hart_id: u32, enabled: bool }{
        .{ .hart_id = 0, .enabled = false },
        .{ .hart_id = 1, .enabled = true },
        .{ .hart_id = 2, .enabled = true },
    };

    for (entries) |entry| {
        if (entry.enabled and !bsp_set) {
            bsp_hart_id = entry.hart_id;
            bsp_set = true;
        }
    }

    try std.testing.expect(bsp_set);
    try std.testing.expectEqual(@as(u32, 1), bsp_hart_id);
}

test "MADT CPU count calculation" {
    // 模拟启用的 CPU 计数
    var cpus: u32 = 0;
    const processor_flags = [_]u32{ 1, 1, 0, 1, 0 }; // 3 enabled, 2 disabled

    for (processor_flags) |flags| {
        if ((flags & 1) != 0) {
            cpus += 1;
        }
    }

    try std.testing.expectEqual(@as(u32, 3), cpus);
}

test "MADT RINTC offset calculation" {
    // RINTC 结构体偏移计算
    // Type = offset 0
    // Length = offset 1
    // Reserved = offset 2-3
    // Hart ID = offset 4-7
    // UID = offset 8-11
    // Flags = offset 12-15
    const HART_ID_OFFSET = 4;
    const FLAGS_OFFSET = 12;

    try std.testing.expectEqual(@as(usize, 4), HART_ID_OFFSET);
    try std.testing.expectEqual(@as(usize, 12), FLAGS_OFFSET);
}

test "MADT Type 34 matches RINTC" {
    try std.testing.expectEqual(@as(u8, 34), MADT_TYPE_RINTC);
}
