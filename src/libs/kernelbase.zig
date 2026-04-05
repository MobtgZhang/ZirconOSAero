// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/libs/kernelbase.zig
// Purpose: KernelBase.dll 等价入口层（NT 6.1 上大量 kernel32 API 转发至此）。
// C4：`kernel32.zig` 侧重 Win32 路径/字符串/错误映射；本模块承载 `GetLastError`/`SetLastError` 等与 Native 边界的薄分层（随里程碑扩展转发至 `ntdll`）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://learn.microsoft.com/windows/win32/api/winbase/

const klog = @import("../rtl/klog.zig");
const ntdll = @import("ntdll.zig");

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

/// C4：`kernel32` 与合成 DLL 经本模块集中调用 **Native** 关闭路径（与商业 `kernel32`→`KernelBase`→`ntdll` 分层同向）。
pub fn NtClose(handle: ntdll.HANDLE) ntdll.NTSTATUS {
    return ntdll.NtClose(handle);
}

/// C4：进程创建 — 由 `kernel32.CreateProcessA` 等转发。
pub fn NtCreateProcess(
    process_handle: *ntdll.HANDLE,
    desired_access: u32,
    object_attributes: ?*const anyopaque,
    parent_process: ntdll.HANDLE,
) ntdll.NTSTATUS {
    return ntdll.NtCreateProcess(process_handle, desired_access, object_attributes, parent_process);
}

/// C4：进程终止 — 由 `kernel32.TerminateProcess` 转发。
pub fn NtTerminateProcess(process_handle: ntdll.HANDLE, exit_status: ntdll.NTSTATUS) ntdll.NTSTATUS {
    return ntdll.NtTerminateProcess(process_handle, exit_status);
}
