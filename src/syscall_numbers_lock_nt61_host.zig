// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/syscall_numbers_lock_nt61_host.zig
// Purpose: 主机测试根在 `src/`：syscall 索引锚点与 SDK 真源路径声明。
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
}
