// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/registry/hive.zig
// Purpose: Windows RegF / hive 持久化加载与保存（占位与公开布局研究入口）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: https://learn.microsoft.com/windows/win32/sysinfo/registry-hives

const ntdll = @import("../libs/ntdll.zig");

/// 自 VFS 路径加载 hive 到内存树（`registry.zig`）；未实现。
pub fn loadHiveFromFile(_: []const u8) ntdll.NTSTATUS {
    return ntdll.STATUS_NOT_IMPLEMENTED;
}

/// 将当前内存树序列化为 RegF 兼容子集；未实现。
pub fn saveHiveToFile(_: []const u8) ntdll.NTSTATUS {
    return ntdll.STATUS_NOT_IMPLEMENTED;
}
