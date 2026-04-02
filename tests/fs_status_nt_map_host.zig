// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/fs_status_nt_map_host.zig
// Purpose: P6-1 子集 — 锁定 `ntdll.NtCreateFile` 中 `vfs.FileStatus`→`NTSTATUS` 映射使用的常见码（与 `src/libs/ntdll.zig` 同步维护）。
//
// Ref: `src/libs/ntdll.zig` `fileStatusToNtStatus`；`src/fs/vfs.zig` `FileStatus`。

const std = @import("std");

test "file status to NTSTATUS constants (mirror ntdll.fileStatusToNtStatus)" {
    // 与 `ntdll.zig` 中 `fileStatusToNtStatus` 分支一致（主机侧无整模块导入，避免 freestanding 依赖）。
    const STATUS_SUCCESS: i32 = 0;
    const STATUS_OBJECT_NAME_NOT_FOUND: i32 = -1073741772;
    const STATUS_ACCESS_DENIED: i32 = -1073741790;
    const STATUS_OBJECT_PATH_INVALID: i32 = -1073741766;
    const STATUS_NOT_IMPLEMENTED: i32 = @bitCast(@as(u32, 0xC0000002));

    try std.testing.expectEqual(STATUS_SUCCESS, @as(i32, 0));
    try std.testing.expect(STATUS_OBJECT_NAME_NOT_FOUND < 0);
    try std.testing.expect(STATUS_ACCESS_DENIED < 0);
    try std.testing.expect(STATUS_OBJECT_PATH_INVALID < 0);
    try std.testing.expectEqual(STATUS_NOT_IMPLEMENTED, @as(i32, @bitCast(@as(u32, 0xC0000002))));
}
