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
// Module: src/ke/scheduler_stub.zig
// Purpose: 调度器占位符模块，用于解决与 klog/timekeeping 的循环依赖
//
// This is a placeholder module to fix circular dependency issues.

const std = @import("std");

/// 调度器线程状态
pub const ThreadState = enum {
    ready,
    running,
    blocked,
    terminated,
};

/// 调度器线程上下文（x64）
pub const ThreadContext = struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    rbx: u64 = 0,
    rbp: u64 = 0,
    rip: u64 = 0,
};

/// 线程信息
pub const Thread = struct {
    id: u32 = 0,
    state: ThreadState = .terminated,
    priority: u8 = 0,
};

/// 获取系统滴答数（stub）
pub fn getTicks() u64 {
    return 0;
}

/// 线程 ID 生成器
var next_thread_id: u32 = 1;

pub fn allocThreadId() u32 {
    const id = next_thread_id;
    next_thread_id += 1;
    return id;
}
