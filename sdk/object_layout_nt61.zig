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
// Module: sdk/object_layout_nt61.zig
// Purpose: 用户态可见 **PEB/TEB** 等稳定字段偏移的文档化常量（NT 6.1 x64）；供 ntdll 桩与 comptime 测试对齐。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/en-us/windows/win32/api/winternl/ns-winternl-peb
//      https://learn.microsoft.com/en-us/windows/win32/api/winternl/ns-winternl-teb

/// `PEB.BeingDebugged`（x64 下偏移固定，用户态调试器与反调试常见探测点）。
pub const peb_being_debugged_offset_x64: usize = 0x02;

/// `PEB.ImageBaseAddress`（x64 下常见文档偏移；与构建版本相关时以本仓库测试锁定为准）。
pub const peb_image_base_address_offset_x64: usize = 0x10;

/// `TEB.NtTib.ExceptionList` 起点即 TEB 首域；`TEB` 自身位于 GS 基址（x64）。
pub const teb_self_offset_x64: usize = 0x30;
