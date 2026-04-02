// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/libs/kernelbase.zig
// Purpose: KernelBase.dll 等价入口层（NT 6.1 上大量 kernel32 API 转发至此）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/api/winbase/

const klog = @import("../rtl/klog.zig");

pub const DWORD = u32;

/// 线程末错误码。完整 NT 语义为 TEB+0x68；当前与 `kernel32` 历史行为一致，后续接 `TebNt61X64`。
var thread_last_error: DWORD = 0;

pub fn GetLastError() DWORD {
    return thread_last_error;
}

pub fn SetLastError(error_code: DWORD) void {
    thread_last_error = error_code;
}

pub fn init() void {
    thread_last_error = 0;
    if (klog.DEBUG_MODE) {
        klog.debug("kernelbase: LastError 入口（NT 6.1 KernelBase 分层桩）", .{});
    }
}
