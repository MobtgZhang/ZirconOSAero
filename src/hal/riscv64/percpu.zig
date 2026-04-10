// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/riscv64/percpu.zig
// Purpose: RISC-V64 per-CPU 数据访问接口。
//
// This is an independent clean-room implementation.

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");
const cpu_topo = @import("cpu_topology.zig");
const fdt = @import("fdt.zig");

/// Per-CPU 数据结构（来自 kpcr.PerCpu，保持 40 字节布局）
pub const PerCpu = @import("../../ke/kpcr.zig").PerCpu;

/// 最大 CPU 数（与 fdt.MAX_HARTS 对齐）
const MAX_CPUS: usize = 64;

/// per-CPU 存储（静态数组，与 x86_64 GS_BASE 和 ARM64 TPIDR_EL1 策略等效）
var percpu_storage: [MAX_CPUS]PerCpu align(64) = undefined;

/// 每个 hart 的 per-CPU 数据指针（由 initPerCpu 在 SMP 启动时设置）
var percpu_ptrs: [MAX_CPUS]*PerCpu align(64) = undefined;

/// 当前 hart 的 per-CPU 指针（用于快速访问）
threadlocal var current_percpu: ?*PerCpu = null;

/// 当前 hart 是否已注册其 per-CPU 数据
var percpu_registered: [MAX_CPUS]bool align(64) = undefined;

/// 初始化指定 CPU 的 per-CPU 数据
pub fn initPerCpu(cpu_index: u32) *PerCpu {
    if (cpu_index >= MAX_CPUS) {
        klog.err("RISC-V percpu: cpu_index %u >= MAX_CPUS", .{cpu_index});
        return &percpu_storage[0];
    }

    percpu_storage[cpu_index] = PerCpu{
        .processor_number = cpu_index,
        .current_thread_index = 0,
        .kernel_sp = 0,
        .self_pointer = 0,
    };
    percpu_storage[cpu_index].self_pointer = @intFromPtr(&percpu_storage[cpu_index]);
    percpu_ptrs[cpu_index] = &percpu_storage[cpu_index];
    percpu_registered[cpu_index] = true;

    // 如果是当前 hart，设置 threadlocal
    const hart = cpu_topo.currentHartId();
    if (hart == cpu_index) {
        current_percpu = &percpu_storage[cpu_index];
        klog.info("RISC-V percpu: registered CPU%u @ 0x%x", .{
            cpu_index,
            @intFromPtr(&percpu_storage[cpu_index]),
        });
    }

    return &percpu_storage[cpu_index];
}

/// 获取当前 CPU 的 per-CPU 数据指针
/// 在初始化前返回 BSP 的 per-CPU 数据作为默认值
pub fn getCurrentPerCpu() *PerCpu {
    if (builtin.cpu.arch != .riscv64) return &percpu_storage[0];
    if (current_percpu) |pc| return pc;
    // 初始化前返回 BSP 的 per-CPU 数据
    return &percpu_storage[0];
}

/// 获取当前 CPU 编号
/// 初始化前通过 hart ID 查找逻辑 CPU 编号
pub fn currentProcessorNumber() u32 {
    if (builtin.cpu.arch != .riscv64) return 0;
    if (current_percpu) |pc| return pc.processor_number;
    // 初始化前通过 hart ID 查找对应的逻辑 CPU 编号
    const hart = cpu_topo.currentHartId();
    return getCpuIndexFromHartId(hart);
}

/// 设置当前 CPU 编号
pub fn setProcessorNumber(n: u32) void {
    if (builtin.cpu.arch != .riscv64) return;
    if (current_percpu) |pc| {
        pc.processor_number = n;
    }
}

/// 获取当前线程索引
pub fn currentThreadIndex() i32 {
    if (builtin.cpu.arch != .riscv64) return 0;
    if (current_percpu) |pc| return pc.current_thread_index;
    return 0;
}

/// 设置当前线程索引
pub fn setCurrentThreadIndex(idx: i32) void {
    if (builtin.cpu.arch != .riscv64) return;
    if (current_percpu) |pc| {
        pc.current_thread_index = idx;
    }
}

/// 获取指定 CPU 的 per-CPU 数据
pub fn getPerCpu(cpu_index: u32) ?*PerCpu {
    if (cpu_index >= MAX_CPUS) return null;
    if (percpu_registered[cpu_index]) return percpu_ptrs[cpu_index];
    return null;
}

/// 根据 hart ID 查找对应的逻辑 CPU 编号
/// 用于初始化前获取正确的 CPU 编号
fn getCpuIndexFromHartId(hart_id: u32) u32 {
    // 遍历 hart_ids 数组查找匹配的 hart ID
    for (0..fdt.MAX_HARTS) |i| {
        if (fdt.hart_ids[i] == hart_id) {
            return @as(u32, @intCast(i));
        }
    }
    // 未找到匹配则返回 0（默认 BSP）
    return 0;
}
