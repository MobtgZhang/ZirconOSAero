// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ob/cleanup_hooks.zig
// Purpose: 在 `ObjectHeader` 引用计至零时调用类型专属回收，避免 `object.zig` ↔ `mm/section.zig` 循环依赖。
//
// This is an independent clean-room implementation.

/// 最后一道引用释放且对象类型为 Section 时由 `HandleTable.closeHandle` 调用。
pub var section_last_reference: ?*const fn (object_ptr: u64) void = null;

pub fn invokeSectionLastReference(object_ptr: u64) void {
    if (section_last_reference) |cb| cb(object_ptr);
}
