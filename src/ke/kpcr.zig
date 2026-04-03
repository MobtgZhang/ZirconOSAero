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

const kpcr_use_gs: bool = builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding;

/// 非 x86_64 或主机单核回退。
var g_processor_number: u32 = 0;
var g_current_thread_index: i32 = -1;

pub fn setProcessorNumber(cpu: u32) void {
    if (kpcr_use_gs) {
        asm volatile ("movl %[v], %%gs:8"
            :
            : [v] "r" (cpu),
        );
    } else {
        g_processor_number = cpu;
    }
}

pub fn currentProcessorNumber() u32 {
    if (kpcr_use_gs) {
        return asm volatile ("movl %%gs:8, %[out]"
            : [out] "=r" (-> u32),
        );
    }
    return g_processor_number;
}

pub fn setCurrentThreadIndex(idx: i32) void {
    if (kpcr_use_gs) {
        asm volatile ("movl %[v], %%gs:12"
            :
            : [v] "r" (idx),
        );
    } else {
        g_current_thread_index = idx;
    }
}

pub fn currentThreadIndex() i32 {
    if (kpcr_use_gs) {
        return asm volatile ("movl %%gs:12, %[out]"
            : [out] "=r" (-> i32),
        );
    }
    return g_current_thread_index;
}
