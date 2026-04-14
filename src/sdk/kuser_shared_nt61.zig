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
// Module: src/sdk/kuser_shared_nt61.zig
// Purpose: `KUSER_SHARED_DATA` 用户态固定 VA 与内核填充所用公开字段偏移（x64）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows-hardware/drivers/ddi/ntddk/ns-ntddk-kuser_shared_data

const std = @import("std");

/// x64 用户态只读共享页基址（与 NT 用户空间约定一致；须避免与其他映像重叠）。
pub const KUSER_SHARED_DATA_VA_X64: u64 = 0x7FFE0000;

/// `KSYSTEM_TIME` — 三 ULONG 分量（WDK 公开描述）。
pub const KSystemTime = extern struct {
    LowPart: u32 = 0,
    High1Time: u32 = 0,
    High2Time: u32 = 0,
};

/// 页内前缀：与 WDK 中 `KUSER_SHARED_DATA` 起始字段顺序一致（仅实现引导所需长度）。
pub const KuserSharedDataPrefix = extern struct {
    TickCountLowDeprecated: u32 = 0,
    TickCountMultiplier: u32 = 0,
    InterruptTime: KSystemTime = .{},
    SystemTime: KSystemTime = .{},
    TimeZoneBias: KSystemTime = .{},
};

comptime {
    std.debug.assert(@sizeOf(KuserSharedDataPrefix) == 4 + 4 + 12 + 12 + 12);
}

/// `NtMajorVersion` / `NtMinorVersion`（WDK 公开结构中的 ULONG 槽位；完整中间字段见 DDI）。
/// 完整布局见 WDK DDI；此处仅固定 **版本 ULONG** 的字节偏移供 `mm/kuser_shared.zig` 写入。
pub const kuser_nt_major_version_offset: usize = 0x26c;
pub const kuser_nt_minor_version_offset: usize = 0x270;

test "KUSER_SHARED_DATA_VA is canonical user low half" {
    try std.testing.expect(KUSER_SHARED_DATA_VA_X64 < 0x0000_8000_0000_0000);
    try std.testing.expect((KUSER_SHARED_DATA_VA_X64 & 0xFFF) == 0);
}

test "kuser version offsets are ordered" {
    try std.testing.expect(kuser_nt_major_version_offset < kuser_nt_minor_version_offset);
}
