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
// Module: src/sdk/system_info_nt61.zig
// Purpose: `NtQuerySystemInformation` 用 `SYSTEM_*` / `RTL_PROCESS_MODULES` 布局真源（extern + comptime 断言）。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation

const std = @import("std");

/// Learn：`SYSTEM_BASIC_INFORMATION`（x64 上含尾部填充至 8 字节界）。
pub const SYSTEM_BASIC_INFORMATION_NT61_X64 = extern struct {
    Reserved1: [24]u8 = [_]u8{0} ** 24,
    Reserved2: [4]u64 = [_]u64{0} ** 4,
    NumberOfProcessors: u8 = 1,
    _pad_tail: [7]u8 = [_]u8{0} ** 7,
};

comptime {
    std.debug.assert(@sizeOf(SYSTEM_BASIC_INFORMATION_NT61_X64) == 64);
    std.debug.assert(@offsetOf(SYSTEM_BASIC_INFORMATION_NT61_X64, "NumberOfProcessors") == 56);
}

/// `SystemProcessorInformation`：公开 12 字节布局（Geoff Chappell / PH 文档与 Win7 一致子集）。
pub const SYSTEM_PROCESSOR_INFORMATION_NT61 = extern struct {
    ProcessorArchitecture: u16 = 0,
    ProcessorLevel: u16 = 0,
    ProcessorRevision: u16 = 0,
    Reserved: u16 = 0,
    ProcessorFeatureBits: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(SYSTEM_PROCESSOR_INFORMATION_NT61) == 12);
}

pub const UNICODE_STRING_SYSTEM_INFO = extern struct {
    Length: u16 = 0,
    MaximumLength: u16 = 0,
    _pad: u32 = 0,
    Buffer: u64 = 0,
};

/// Learn：`SYSTEM_PROCESS_INFORMATION`（至 `Reserved7`；不含后续可变映像名缓冲——由调用方在块尾追加 UTF-16）。
pub const SYSTEM_PROCESS_INFORMATION_NT61_X64 = extern struct {
    NextEntryOffset: u32 = 0,
    NumberOfThreads: u32 = 0,
    Reserved1: [48]u8 = [_]u8{0} ** 48,
    ImageName: UNICODE_STRING_SYSTEM_INFO = .{},
    BasePriority: i32 = 0,
    _pad_base_pri: u32 = 0,
    UniqueProcessId: u64 = 0,
    InheritedFromUniqueProcessId: u64 = 0,
    HandleCount: u32 = 0,
    SessionId: u32 = 0,
    Reserved3: u64 = 0,
    PeakVirtualSize: u64 = 0,
    VirtualSize: u64 = 0,
    Reserved4: u32 = 0,
    _pad_r4: u32 = 0,
    PeakWorkingSetSize: u64 = 0,
    WorkingSetSize: u64 = 0,
    Reserved5: u64 = 0,
    QuotaPagedPoolUsage: u64 = 0,
    Reserved6: u64 = 0,
    QuotaNonPagedPoolUsage: u64 = 0,
    PagefileUsage: u64 = 0,
    PeakPagefileUsage: u64 = 0,
    PrivatePageCount: u64 = 0,
    Reserved7: [6]i64 = [_]i64{0} ** 6,
};

comptime {
    std.debug.assert(@offsetOf(SYSTEM_PROCESS_INFORMATION_NT61_X64, "ImageName") == 56);
    std.debug.assert(@sizeOf(SYSTEM_PROCESS_INFORMATION_NT61_X64) == 256);
}

pub const CLIENT_ID_NT61_X64 = extern struct {
    UniqueProcess: u64 = 0,
    UniqueThread: u64 = 0,
};

/// Learn：`SYSTEM_THREAD_INFORMATION`。
pub const SYSTEM_THREAD_INFORMATION_NT61_X64 = extern struct {
    Reserved1: [3]i64 = [_]i64{0} ** 3,
    Reserved2: u32 = 0,
    _pad_r2: u32 = 0,
    StartAddress: u64 = 0,
    ClientId: CLIENT_ID_NT61_X64 = .{},
    Priority: i32 = 0,
    BasePriority: i32 = 0,
    Reserved3: u32 = 0,
    ThreadState: u32 = 0,
    WaitReason: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(SYSTEM_THREAD_INFORMATION_NT61_X64) == 80);
}

/// 单条内核模块项（WDK 公开形状；`FullPathName` 为 256 字节窄字符路径）。
pub const RTL_PROCESS_MODULE_INFORMATION_NT61_X64 = extern struct {
    Section: u64 = 0,
    MappedBase: u64 = 0,
    ImageBase: u64 = 0,
    ImageSize: u32 = 0,
    Flags: u32 = 0,
    LoadOrderIndex: u16 = 0,
    InitOrderIndex: u16 = 0,
    LoadCount: u16 = 0,
    OffsetToFileName: u16 = 0,
    FullPathName: [256]u8 = [_]u8{0} ** 256,
};

comptime {
    std.debug.assert(@sizeOf(RTL_PROCESS_MODULE_INFORMATION_NT61_X64) == 296);
}

pub const RTL_PROCESS_MODULES_HEADER_NT61_X64 = extern struct {
    NumberOfModules: u32 = 0,
    _pad: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(RTL_PROCESS_MODULES_HEADER_NT61_X64) == 8);
}

test "SYSTEM_BASIC_INFORMATION NumberOfProcessors offset 56" {
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(SYSTEM_BASIC_INFORMATION_NT61_X64, "NumberOfProcessors"));
}

test "SYSTEM_PROCESS_INFORMATION_NT61_X64 size 256" {
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(SYSTEM_PROCESS_INFORMATION_NT61_X64));
}
