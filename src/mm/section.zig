// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/section.zig
// Purpose: Section 对象与映射 — 路线图占位（DLL 共享 / 映射视图）；当前返回未实现。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: MSDN — Section Objects / Memory Management

const ntdll = @import("../libs/ntdll.zig");

/// 创建节对象（占位）；完整实现见 MM_Section_Roadmap。
pub fn NtCreateSection() ntdll.NTSTATUS {
    return ntdll.STATUS_NOT_IMPLEMENTED;
}

pub fn NtMapViewOfSection() ntdll.NTSTATUS {
    return ntdll.STATUS_NOT_IMPLEMENTED;
}
