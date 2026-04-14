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
// Module: tests/host/wow64_x64_semantic_alias_host.zig
// Purpose: 主机测试：WOW64 x86→x64 语义别名映射回归（见 `wow64/x64_semantic_alias.zig`）。
//
// This is an independent clean-room implementation.
// Ref: [docs/cn/PHASE_G_WOW64.md](../docs/cn/PHASE_G_WOW64.md)

const std = @import("std");
const alias = @import("subsystems/win32/wow64/x64_semantic_alias.zig");
const x86 = @import("subsystems/win32/wow64/ssdt_x86_win7_sp1.zig");
const ssdt64 = @import("arch/x86_64/ssdt_nt61.zig");

test "x64SsdtIndexForWin7Sp1X86 maps stub-list syscalls" {
    try std.testing.expectEqual(@as(?u32, ssdt64.NtClose), alias.x64SsdtIndexForWin7Sp1X86(x86.NtClose));
    try std.testing.expectEqual(@as(?u32, ssdt64.NtAllocateVirtualMemory), alias.x64SsdtIndexForWin7Sp1X86(x86.NtAllocateVirtualMemory));
    try std.testing.expectEqual(@as(?u32, ssdt64.NtConnectPort), alias.x64SsdtIndexForWin7Sp1X86(x86.NtConnectPort));
    try std.testing.expectEqual(@as(?u32, ssdt64.NtRequestWaitReplyPort), alias.x64SsdtIndexForWin7Sp1X86(x86.NtRequestWaitReplyPort));
    try std.testing.expectEqual(@as(?u32, ssdt64.NtTerminateThread), alias.x64SsdtIndexForWin7Sp1X86(x86.NtTerminateThread));
    try std.testing.expectEqual(@as(?u32, ssdt64.NtDelayExecution), alias.x64SsdtIndexForWin7Sp1X86(x86.NtDelayExecution));
    try std.testing.expectEqual(@as(?u32, null), alias.x64SsdtIndexForWin7Sp1X86(0xFFFF));
}

test "wow64SyscallStubReturnsSuccess entries have x64 semantic alias" {
    inline for (.{
        x86.NtAllocateVirtualMemory,
        x86.NtClose,
        x86.NtCreateEvent,
        x86.NtCreateFile,
        x86.NtCreatePort,
        x86.NtConnectPort,
        x86.NtCreateProcess,
        x86.NtCreateSection,
        x86.NtCreateThread,
        x86.NtFreeVirtualMemory,
        x86.NtMapViewOfSection,
        x86.NtOpenFile,
        x86.NtOpenProcess,
        x86.NtProtectVirtualMemory,
        x86.NtQueryInformationProcess,
        x86.NtQuerySystemInformation,
        x86.NtQueryVirtualMemory,
        x86.NtReadFile,
        x86.NtReadVirtualMemory,
        x86.NtRequestWaitReplyPort,
        x86.NtDelayExecution,
        x86.NtTerminateProcess,
        x86.NtTerminateThread,
        x86.NtWaitForSingleObject,
        x86.NtWriteFile,
        x86.NtWriteVirtualMemory,
    }) |svc| {
        try std.testing.expect(x86.wow64SyscallStubReturnsSuccess(svc));
        try std.testing.expect(alias.x64SsdtIndexForWin7Sp1X86(svc) != null);
    }
}
