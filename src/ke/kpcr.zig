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
// Module: src/ke/kpcr.zig
// Purpose: **KPCR 等价物**最小子集（当前处理器索引）；由 HAL percpu 层统一同步。
//
// This is an independent clean-room implementation.
// Reference: docs/cn/SCHEDULER_API.md、docs/cn/VM_ISOLATION.md — 每 CPU 状态与 NT 概念对齐为路线图。

const hal_runtime = @import("../hal/percpu_runtime.zig");

/// Per-CPU structure accessible via the platform's thread pointer register.
pub const PerCpu = hal_runtime.PerCpu;

pub fn setProcessorNumber(cpu: u32) void {
    hal_runtime.setProcessorNumber(cpu);
}

pub fn currentProcessorNumber() u32 {
    return hal_runtime.currentProcessorNumber();
}

pub fn setCurrentThreadIndex(idx: i32) void {
    hal_runtime.setCurrentThreadIndex(idx);
}

pub fn currentThreadIndex() i32 {
    return hal_runtime.currentThreadIndex();
}
pub const initPerCpu = hal_runtime.initPerCpu;
pub const setCurrentAsid = hal_runtime.setCurrentAsid;
pub const getCurrentAsid = hal_runtime.getCurrentAsid;
