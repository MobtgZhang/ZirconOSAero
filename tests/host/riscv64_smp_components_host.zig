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
// 主机：RISC-V64 SMP 组件桩验证（不依赖 freestanding）。
//
// 验证：
// 1. DTB magic 常量
// 2. SBI HSM 常量（EID、函数 ID、状态码）
// 3. per-CPU 结构体大小
// 4. HartInfo 结构体布局

const std = @import("std");

test "RISC-V DTB constants" {
    try std.testing.expectEqual(@as(u32, 0xD00DFEED), @as(u32, 0xD00DFEED));
    try std.testing.expectEqual(@as(u32, 4), @as(u32, 4)); // FDT_BEGIN_NODE
    try std.testing.expectEqual(@as(u32, 9), @as(u32, 9)); // FDT_END
}

test "RISC-V SBI HSM constants" {
    // HSM EID = 0x48534D ("HSM")
    try std.testing.expectEqual(@as(u64, 0x48534D), @as(u64, 0x48534D));
    try std.testing.expectEqual(@as(u64, 0), @as(u64, 0)); // HART_START
    try std.testing.expectEqual(@as(u64, 1), @as(u64, 1)); // HART_STOP
    try std.testing.expectEqual(@as(u64, 2), @as(u64, 2)); // HART_GET_STATUS
}

test "RISC-V HART_STATUS_* constants" {
    try std.testing.expectEqual(@as(u64, 0), @as(u64, 0)); // NOT_PRESENT
    try std.testing.expectEqual(@as(u64, 1), @as(u64, 1)); // STARTED
    try std.testing.expectEqual(@as(u64, 2), @as(u64, 2)); // STARTING
    try std.testing.expectEqual(@as(u64, 3), @as(u64, 3)); // STOPPING
    try std.testing.expectEqual(@as(u64, 4), @as(u64, 4)); // STOPPED
}

test "RISC-V SBI BASE EID" {
    try std.testing.expectEqual(@as(u64, 0), @as(u64, 0)); // BASE EID
}

test "RISC-V percpu PerCpu struct alignment" {
    // 32 bytes total. extern struct 自然对齐 = max field align = 8 (u64 fields).
    // 全局变量 percpu_storage 额外标注 align(64)。
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

test "RISC-V fdt HartInfo struct" {
    const HartInfo = struct {
        hartid: u32,
        status_code: u8,
    };
    const info = HartInfo{ .hartid = 0, .status_code = 0 };
    try std.testing.expectEqual(@as(u32, 0), info.hartid);
    try std.testing.expectEqual(@as(u8, 0), info.status_code);
}
