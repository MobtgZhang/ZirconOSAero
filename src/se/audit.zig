// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/se/audit.zig
// Purpose: 安全相关审计日志占位（访问拒绝等）；扩展为缓冲 / 过滤策略时不改变调用点语义。
//
// This is an independent clean-room implementation.
// Reference: Microsoft Learn — auditing concepts (high level).

const klog = @import("../rtl/klog.zig");

/// 记录一次访问拒绝（DAC 或其它检查失败）；默认 notice 级，便于与 Release 日志级别协调。
pub fn logAccessDenied(comptime context: []const u8) void {
    klog.notice("SE audit: access_denied ({s})", .{context});
}

/// 对象打开/句柄授予路径上的失败（与 `STATUS_ACCESS_DENIED` 等配合，便于后续接入缓冲审计）。
pub fn logObjectOpenDenied(comptime context: []const u8) void {
    klog.notice("SE audit: object_open_denied ({s})", .{context});
}
