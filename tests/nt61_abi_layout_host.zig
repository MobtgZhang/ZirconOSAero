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
// Module: tests/nt61_abi_layout_host.zig
// Purpose: 主机断言 `TEB`/`KUSER_SHARED_DATA` 契约与 Phase1（ABI-1.4/1.5）文档一致。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.

const std = @import("std");
const teb = @import("teb");
const peb = @import("peb");
const kuser = @import("kuser");

test "TEB x64 LastErrorValue offset 0x68" {
    try std.testing.expectEqual(@as(usize, 0x60), @offsetOf(teb.TebNt61X64, "ProcessEnvironmentBlock"));
    try std.testing.expectEqual(@as(usize, 0x68), @offsetOf(teb.TebNt61X64, "LastErrorValue"));
}

test "PEB x64 ImageBaseAddress offset 0x10" {
    try std.testing.expectEqual(@as(usize, 0x10), @offsetOf(peb.PebNt61X64, "ImageBaseAddress"));
    try std.testing.expectEqual(@as(usize, 0x18), @offsetOf(peb.PebNt61X64, "Ldr"));
    try std.testing.expectEqual(@as(usize, 0x20), @offsetOf(peb.PebNt61X64, "ProcessParameters"));
}

test "KUSER_SHARED_DATA VA and version field offsets" {
    try std.testing.expectEqual(@as(u64, 0x7FFE0000), kuser.KUSER_SHARED_DATA_VA_X64);
    try std.testing.expect(kuser.kuser_nt_major_version_offset < 4096);
    try std.testing.expect(kuser.kuser_nt_minor_version_offset < 4096);
}

/// 与 `ntdll.zig` `ProcessImageFileName` 写出布局一致（x64 `UNICODE_STRING`）。
const UNICODE_STRING_NATIVE = extern struct {
    length: u16,
    maximum_length: u16,
    _reserved: u32 = 0,
    buffer: u64,
};
const KERNEL_USER_TIMES = extern struct {
    create_time: i64,
    exit_time: i64,
    kernel_time: i64,
    user_time: i64,
};

test "UNICODE_STRING_NATIVE 16 bytes for ProcessImageFileName buffer header" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(UNICODE_STRING_NATIVE));
}

test "KERNEL_USER_TIMES 32 bytes for ThreadTimes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(KERNEL_USER_TIMES));
}
