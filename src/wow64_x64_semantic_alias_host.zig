// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/wow64_x64_semantic_alias_host.zig
// Purpose: 主机测试根在 `src/`，运行 WOW64 x86→x64 语义别名映射回归（见 `wow64/x64_semantic_alias.zig`）。
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
    try std.testing.expectEqual(@as(?u32, null), alias.x64SsdtIndexForWin7Sp1X86(x86.NtTerminateThread));
    try std.testing.expectEqual(@as(?u32, null), alias.x64SsdtIndexForWin7Sp1X86(0xFFFF));
}
