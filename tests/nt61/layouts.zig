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

//! Layout checks for NT 6.1–style structures (host `zig test`; no kernel imports).
const std = @import("std");

/// x64 `PROCESS_BASIC_INFORMATION` (MSDN).
const ProcessBasicInformation = extern struct {
    exit_status: i32,
    _pad0: u32,
    peb_base_address: u64,
    affinity_mask: u64,
    base_priority: i32,
    _pad1: u32,
    unique_process_id: u64,
    inherited_from_unique_process_id: u64,
};

test "PROCESS_BASIC_INFORMATION x64 is 48 bytes" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(ProcessBasicInformation));
}

// KEY_VALUE_PARTIAL_INFORMATION fixed header before Data[1].
test "KEY_VALUE_PARTIAL_INFORMATION header is 12 bytes" {
    try std.testing.expectEqual(@as(usize, 12), 3 * @sizeOf(u32));
}

/// `SECTION_BASIC_INFORMATION`（winternl / 查询类 0 子集）；x64 对齐与 Learn 公开布局一致。
const SectionBasicInformation = extern struct {
    BaseAddress: ?*anyopaque,
    AllocationAttributes: u32,
    _pad0: u32,
    MaximumSize: i64,
};

test "SECTION_BASIC_INFORMATION x64 is 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(SectionBasicInformation));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SectionBasicInformation, "BaseAddress"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(SectionBasicInformation, "AllocationAttributes"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SectionBasicInformation, "MaximumSize"));
}
