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
// Module: tests/host/syscall_numbers_lock_nt61_host.zig
// Purpose: 主机测试：syscall 索引锚点与 SDK 真源路径声明。
//
// This is an independent clean-room implementation.

comptime {
    if (@import("builtin").cpu.arch != .x86_64) {
        @compileError("syscall_numbers_lock_nt61_host requires x86_64 host");
    }
}

const std = @import("std");
const ssdt = @import("arch/x86_64/ssdt_nt61.zig");
const sdk_path = @import("sdk_nt61_syscall_path");

test "syscall SSDT source path is ssdt_nt61.zig" {
    try std.testing.expectEqualStrings("src/arch/x86_64/ssdt_nt61.zig", sdk_path.nt61_x64_ssdt_zig_path_from_repo_root);
}

test "Win7 SP1 x64 syscall index anchors (locked)" {
    try std.testing.expectEqual(@as(u32, 0x18), ssdt.NtAllocateVirtualMemory);
    try std.testing.expectEqual(@as(u32, 0x47), ssdt.NtCreateSection);
    try std.testing.expectEqual(@as(u32, 0x48), ssdt.NtMapViewOfSection);
    try std.testing.expectEqual(@as(u32, 0x2A), ssdt.NtUnmapViewOfSection);
    try std.testing.expectEqual(@as(u32, 0x23), ssdt.NtOpenProcess);
    try std.testing.expectEqual(@as(u32, 0x44), ssdt.NtDuplicateObject);
    try std.testing.expectEqual(@as(u32, 0xAA), ssdt.NtCreateUserProcess);
}
