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
// Host-only：`NtRequestWaitReplyPort` 用户指针探测失败时返回的 NTSTATUS 锚点，
// 与 `src/arch/x86_64/syscall_nt_extras.zig` `dispatchNtRequestWaitReplyPort` 一致。
// Ref: docs/cn/NT61_CONTRACT_MATRIX.md §2.2 B1

const std = @import("std");

test "LPC syscall negative: unprobed reply buffer maps to STATUS_ACCESS_VIOLATION" {
    // 与 `ntdll.STATUS_ACCESS_VIOLATION` / Win32 `0xC0000005` 同源冻结值
    const STATUS_ACCESS_VIOLATION: i32 = -1073741819;
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xC0000005))), STATUS_ACCESS_VIOLATION);
}

test "LPC syscall negative: null reply pointer maps to STATUS_INVALID_PARAMETER" {
    const STATUS_INVALID_PARAMETER: i32 = -1073741811;
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xC000000D))), STATUS_INVALID_PARAMETER);
}
