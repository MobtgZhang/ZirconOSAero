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
// Module: src/ke/apc_object.zig
// Purpose: `KeApc` 链表节点类型（与 `scheduler.Thread` 解耦，避免 `apc` ↔ `scheduler` 类型环）。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/introduction-to-asynchronous-procedure-calls

/// 异步过程调用队列节点（最小子集：内核例程 + 用户 APC 占位）。
pub const KeApc = struct {
    next: ?*KeApc = null,
    kernel_routine: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    /// `true`：用户 APC（可告警等待路径可见；本阶段不模拟完整返用户交付）。
    is_user_apc: bool = false,
};
