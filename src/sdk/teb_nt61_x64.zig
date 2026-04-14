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
// Module: src/sdk/teb_nt61_x64.zig
// Purpose: x64 `TEB` 前缀布局（至 `LastErrorValue`），供内核/加载器与主机单测对齐公开 ABI。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/api/winternl/ns-winnt-teb
//            (TEB 未完整展开；`LastErrorValue` 偏移与调试器/调用约定实践一致。)

const std = @import("std");

/// x64 `NT_TIB` 前缀（至 `Self`）。
pub const NtTibX64 = extern struct {
    ExceptionList: u64 = 0,
    StackBase: u64 = 0,
    StackLimit: u64 = 0,
    SubSystemTib: u64 = 0,
    FiberData: u64 = 0,
    ArbitraryUserPointer: u64 = 0,
    Self: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(NtTibX64) == 0x38);
}

/// 与 NT 6.1 x64 用户态 `GetLastError`（`gs:[0x68]`）对齐的 `TEB` 前缀。
pub const TebNt61X64 = extern struct {
    NtTib: NtTibX64 = .{},
    EnvironmentPointer: u64 = 0,
    ClientIdUniqueProcess: u64 = 0,
    ClientIdUniqueThread: u64 = 0,
    ActiveRpcHandle: u64 = 0,
    ThreadLocalStoragePointer: u64 = 0,
    ProcessEnvironmentBlock: u64 = 0,
    LastErrorValue: u32 = 0,
    CountOfOwnedCriticalSections: u32 = 0,
};

comptime {
    std.debug.assert(@offsetOf(TebNt61X64, "ProcessEnvironmentBlock") == 0x60);
    std.debug.assert(@offsetOf(TebNt61X64, "LastErrorValue") == 0x68);
}

test "TebNt61X64 LastErrorValue at x64 offset 0x68" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TebNt61X64, "NtTib"));
    try std.testing.expectEqual(@as(usize, 0x38), @sizeOf(NtTibX64));
    try std.testing.expectEqual(@as(usize, 0x60), @offsetOf(TebNt61X64, "ProcessEnvironmentBlock"));
    try std.testing.expectEqual(@as(usize, 0x68), @offsetOf(TebNt61X64, "LastErrorValue"));
}
