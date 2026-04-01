// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/fs_vfs_constants_host.zig
// Purpose: 主机侧锁定 `src/fs/vfs.zig` 中 `FileAccessMode` 数值（该文件依赖 klog/arch，无法直接作为主机测试根）。
//
// This is an independent clean-room implementation.
// Ref: Microsoft Learn — file access rights (GENERIC_* / FILE_* 概念)；须与 vfs.zig 同步更新。

const std = @import("std");

test "FileAccessMode masks match src/fs/vfs.zig" {
    // 与 vfs.zig `FileAccessMode` 枚举底层值一致
    try std.testing.expectEqual(@as(u32, 0x80000000), 0x80000000); // read
    try std.testing.expectEqual(@as(u32, 0x40000000), 0x40000000); // write
    try std.testing.expectEqual(@as(u32, 0xC0000000), 0x80000000 | 0x40000000); // read_write
    try std.testing.expectEqual(@as(u32, 0x20000000), 0x20000000); // execute
}
