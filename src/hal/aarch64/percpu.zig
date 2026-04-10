// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: hal/aarch64/percpu.zig
// Purpose: AArch64 per-CPU 数据访问接口。PerCpu 定义来自 kpcr.PerCpu。
//
// Clean-room: per-CPU 存储使用 ARM TPIDR_EL1 寄存器。

/// Per-CPU 数据结构（来自 kpcr.PerCpu，保持 40 字节布局）
pub const PerCpu = @import("../../ke/kpcr.zig").PerCpu;

/// 最大 CPU 数量
const MAX_CPUS: usize = 64;

/// Per-CPU 存储数组（64 字节对齐，确保跨架构一致性）
var percpu_storage: [MAX_CPUS]PerCpu align(64) = undefined;

/// Set TPIDR_EL1 to point to the current CPU's PerCpu structure.
pub fn setTpidrEl1(cpu: *PerCpu) void {
    asm volatile ("msr tpidr_el1, %[v]"
        :
        : [v] "r" (@intFromPtr(cpu)),
        : .{ .memory = true }
    );
}

/// Read TPIDR_EL1.
fn getTpidrEl1() *PerCpu {
    return @ptrFromInt(asm volatile ("mrs %[v], tpidr_el1"
        : [v] "=r" (-> u64),
    ));
}

/// Get current processor number.
pub fn currentProcessorNumber() u32 {
    return getTpidrEl1().processor_number;
}

/// Set current processor number.
pub fn setProcessorNumber(cpu: u32) void {
    getTpidrEl1().processor_number = cpu;
}

/// Get current thread index.
pub fn currentThreadIndex() i32 {
    return getTpidrEl1().current_thread_index;
}

/// Set current thread index.
pub fn setCurrentThreadIndex(idx: i32) void {
    getTpidrEl1().current_thread_index = idx;
}

/// Get current per-CPU data pointer via TPIDR_EL1.
/// Returns pointer to current CPU's PerCpu structure.
pub fn getCurrentPerCpu() *PerCpu {
    return getTpidrEl1();
}
