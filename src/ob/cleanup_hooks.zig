// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

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
