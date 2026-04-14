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
// Purpose: **KPCR 等价物**最小子集（当前处理器索引）；x86_64 下与 `hal/x86_64/percpu.zig` 中 `IA32_KERNEL_GS_BASE` 块同步。
//
// This is an independent clean-room implementation.
// Reference: docs/cn/SCHEDULER_API.md、docs/cn/VM_ISOLATION.md — 每 CPU 状态与 NT 概念对齐为路线图。

const builtin = @import("builtin");
const std = @import("std");

comptime {
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        const P = @import("../hal/x86_64/percpu.zig").PerCpu;
        std.debug.assert(@offsetOf(P, "processor_number") == 8);
        std.debug.assert(@offsetOf(P, "current_thread_index") == 12);
    }
}

/// Per-CPU structure accessible via TPIDR_EL1 on AArch64, GS on x86_64, or CSR 0x30 on LoongArch64.
pub const PerCpu = extern struct {
    processor_number: u32,
    _pad0: u32 = 0,
    current_thread_index: i32,
    _pad1: u32 = 0,
    kernel_sp: u64,
    self_pointer: u64,
    /// LoongArch64 当前 ASID（CSR 0x5）；由 tlb_flush.zig 维护。
    /// 其他架构不使用此字段（默认为 0）。
    current_asid: u8 = 0,
    _pad2: [7]u8 = @splat(0),
};

comptime {
    if (@sizeOf(PerCpu) != 40) @compileError("PerCpu must be 40 bytes");
}

/// Non-x86_64 or host fallback storage.
var g_processor_number: u32 = 0;
var g_current_thread_index: i32 = -1;

/// AArch64: per-CPU storage for up to 256 CPUs (aligned cache line)
var aarch64_percpu_storage: [256]PerCpu align(64) = undefined;

/// LoongArch64: per-CPU storage for up to 256 CPUs (aligned cache line)
/// 使用 CSR 0x30 (tpid) 存储 per-CPU 指针
var loongarch64_percpu_storage: [256]PerCpu align(64) = undefined;

pub fn setProcessorNumber(cpu: u32) void {
    if (builtin.cpu.arch == .x86_64) {
        // x86_64 freestanding 模式使用 GS 段寄存器存储 per-CPU 数据
        if (builtin.os.tag == .freestanding) {
            asm volatile ("movl %[v], %%gs:8"
                :
                : [v] "r" (cpu),
            );
        } else {
            // host 模式：使用全局变量（GS 段未初始化）
            g_processor_number = cpu;
        }
    } else if (builtin.cpu.arch == .loongarch64) {
        g_processor_number = cpu;
        // 如果 LoongArch64 per-CPU 已初始化，更新对应条目
        const tp = loongarchReadTpid();
        if (tp != 0) {
            const cpu_ptr: *PerCpu = @ptrFromInt(tp);
            cpu_ptr.processor_number = cpu;
        }
    } else {
        g_processor_number = cpu;
    }
}

pub fn currentProcessorNumber() u32 {
    if (builtin.cpu.arch == .x86_64) {
        // x86_64 freestanding 模式使用 GS 段寄存器
        if (builtin.os.tag == .freestanding) {
            return asm volatile ("movl %%gs:8, %[out]"
                : [out] "=r" (-> u32),
            );
        } else {
            // host 模式：GS 段未初始化，使用全局变量
            return g_processor_number;
        }
    }
    if (builtin.cpu.arch == .loongarch64) {
        const tp = loongarchReadTpid();
        if (tp != 0) {
            const cpu_ptr: *PerCpu = @ptrFromInt(tp);
            return cpu_ptr.processor_number;
        }
        return g_processor_number;
    }
    if (builtin.cpu.arch == .aarch64) {
        const tp: u64 = asm volatile ("mrs %[v], tpidr_el1"
            : [v] "=r" (-> u64),
        );
        if (tp == 0) return g_processor_number;
        const cpu_ptr: *PerCpu = @ptrFromInt(tp);
        return cpu_ptr.processor_number;
    }
    return g_processor_number;
}

pub fn setCurrentThreadIndex(idx: i32) void {
    if (builtin.cpu.arch == .x86_64) {
        asm volatile ("movl %[v], %%gs:12"
            :
            : [v] "r" (idx),
        );
    } else if (builtin.cpu.arch == .loongarch64) {
        g_current_thread_index = idx;
        const tp = loongarchReadTpid();
        if (tp != 0) {
            const cpu_ptr: *PerCpu = @ptrFromInt(tp);
            cpu_ptr.current_thread_index = idx;
        }
    } else {
        g_current_thread_index = idx;
    }
}

pub fn currentThreadIndex() i32 {
    if (builtin.cpu.arch == .x86_64) {
        return asm volatile ("movl %%gs:12, %[out]"
            : [out] "=r" (-> i32),
        );
    }
    if (builtin.cpu.arch == .loongarch64) {
        const tp = loongarchReadTpid();
        if (tp != 0) {
            const cpu_ptr: *PerCpu = @ptrFromInt(tp);
            return cpu_ptr.current_thread_index;
        }
        return g_current_thread_index;
    }
    if (builtin.cpu.arch == .aarch64) {
        const tp: u64 = asm volatile ("mrs %[v], tpidr_el1"
            : [v] "=r" (-> u64),
        );
        if (tp == 0) return g_current_thread_index;
        const cpu_ptr: *PerCpu = @ptrFromInt(tp);
        return cpu_ptr.current_thread_index;
    }
    return g_current_thread_index;
}

/// Initialize per-CPU data for the given CPU index.
/// On AArch64: stores pointer in TPIDR_EL1 so currentThreadIndex/processorNumber work.
/// On LoongArch64: stores pointer in CSR 0x30 (tpid).
pub fn initPerCpu(cpu_index: u32) *PerCpu {
    if (builtin.cpu.arch == .aarch64) {
        const cpu_ptr = &aarch64_percpu_storage[cpu_index];
        cpu_ptr.* = .{
            .processor_number = cpu_index,
            .current_thread_index = -1,
            .kernel_sp = 0,
            .self_pointer = @intFromPtr(cpu_ptr),
        };
        asm volatile ("msr tpidr_el1, %[v]"
            :
            : [v] "r" (@intFromPtr(cpu_ptr)));
        return cpu_ptr;
    }
    if (builtin.cpu.arch == .loongarch64) {
        const cpu_ptr = &loongarch64_percpu_storage[cpu_index];
        cpu_ptr.* = .{
            .processor_number = cpu_index,
            .current_thread_index = -1,
            .kernel_sp = 0,
            .self_pointer = @intFromPtr(cpu_ptr),
        };
        // 使用 CSR 0x30 (tpid) 存储 per-CPU 指针
        loongarchWriteTpid(@intFromPtr(cpu_ptr));
        return cpu_ptr;
    }
    g_processor_number = cpu_index;
    return undefined;
}

/// Read LoongArch64 CSR 0x30 (tpid) - Thread Pointer ID
fn loongarchReadTpid() u64 {
    if (builtin.cpu.arch != .loongarch64) return 0;
    if (builtin.os.tag != .freestanding) return 0;
    return asm volatile ("csrrd %[o], 0x30"
        : [o] "=r" (-> u64),
    );
}

/// Write LoongArch64 CSR 0x30 (tpid) - Thread Pointer ID
fn loongarchWriteTpid(value: u64) void {
    if (builtin.cpu.arch != .loongarch64) return;
    if (builtin.os.tag != .freestanding) return;
    asm volatile ("csrwr %[v], 0x30"
        :
        : [v] "r" (value),
    );
}

/// Set the current ASID for the calling CPU.
/// On LoongArch64: updates both the per-CPU struct and CSR 0x5.
/// On other architectures: no-op.
pub fn setCurrentAsid(asid: u8) void {
    if (builtin.cpu.arch == .loongarch64) {
        const tp = loongarchReadTpid();
        if (tp != 0) {
            const cpu_ptr: *PerCpu = @ptrFromInt(tp);
            cpu_ptr.current_asid = asid;
        }
    }
}

/// Get the current ASID for the calling CPU.
/// Returns 0 if no ASID is set.
pub fn getCurrentAsid() u8 {
    if (builtin.cpu.arch == .loongarch64) {
        const tp = loongarchReadTpid();
        if (tp != 0) {
            const cpu_ptr: *PerCpu = @ptrFromInt(tp);
            return cpu_ptr.current_asid;
        }
    }
    return 0;
}
