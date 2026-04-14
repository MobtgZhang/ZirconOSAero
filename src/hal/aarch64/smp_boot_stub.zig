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
// Module: src/hal/aarch64/smp_boot_stub.zig
// Purpose: AArch64 SMP 多核启动框架。通过 PSCI cpu_on 启动 AP。
//
// This is an independent clean-room implementation.
// Reference: ARM DEN 0022D — PSCI Specification; ARM IHI 0048B — GICv2.

const builtin = @import("builtin");
const klog = @import("../../rtl/klog.zig");
const cpu_topo = @import("cpu_topology.zig");
const psci = @import("psci.zig");
const scheduler = @import("../../ke/scheduler.zig");

/// AP 栈大小（16KiB，与其他架构一致）
const AP_STACK_SIZE: usize = 16384;

/// 最大 CPU 数
const MAX_CPUS: usize = 64;

/// AP 栈表（.bss，16KiB 对齐）
var ap_stacks: [MAX_CPUS][AP_STACK_SIZE]u8 align(16384) = undefined;
var ap_started: [MAX_CPUS]bool align(64) = undefined;

/// AP 入口桩（由 src/arch/aarch64/ap_entry.S 提供）
extern fn aarch64_ap_entry() void;

/// AP 异常向量表（由 src/arch/aarch64/exception_vector.S 提供）
extern fn aarch64_exception_vectors() align(2048) void;

/// 构造 QEMU virt 机器类型的 MPIDR
/// QEMU virt: Aff0 = CPU ID, Aff1 = Cluster(0), MT = 0
/// 真实硬件应从 ACPI MADT (GIC CPU Interface) 获取 MPIDR
fn buildQemuVirtMpidr(cpu_index: u32) u64 {
    return @as(u64, cpu_index);
}

/// AP 初始化函数（由 AP trampoline 调用）
export fn aarch64_ap_init() void {
    if (builtin.cpu.arch != .aarch64) return;
    if (builtin.os.tag != .freestanding) return;

    const cpu_num = cpu_topo.currentMpidrAffinity();
    klog.info("AArch64 SMP: AP%u initializing (MPIDR=0x%x)", .{ cpu_num, cpu_num });

    // 初始化 per-CPU 数据（KPCR）
    const kpcr = @import("../../ke/kpcr.zig");
    const kpcr_ptr = kpcr.initPerCpu(@as(u32, @truncate(cpu_num)));
    klog.info("AArch64 SMP: AP%u KPCR at 0x%x", .{ cpu_num, @intFromPtr(kpcr_ptr) });

    // 设置 TPIDR_EL1（per-CPU 数据指针）
    asm volatile ("msr tpidr_el1, %[ptr]" :: [ptr] "r" (@intFromPtr(kpcr_ptr)));

    // 设置 trap vector（VBAR_EL1），指向 BSP 的异常向量表
    const vbar = @intFromPtr(&aarch64_exception_vectors);
    asm volatile ("msr vbar_el1, %[v]" :: [v] "r" (vbar));
    asm volatile ("isb");

    // 标记 AP 已启动
    markApStarted(@as(u32, @truncate(cpu_num)));

    // 启用中断
    asm volatile ("msr daifclr, #0xF");

    klog.info("AArch64 SMP: AP%u ready, entering idle loop", .{cpu_num});

    // 进入调度器 idle 循环（noreturn）
    scheduler.apProcessorIdleLoop();
    // 永远不会执行到这里
}

/// 获取 AP 栈顶地址
pub fn getApStackTop(cpu_index: u32) u64 {
    if (cpu_index >= MAX_CPUS) return 0;
    return @intFromPtr(&ap_stacks[cpu_index]) + AP_STACK_SIZE;
}

/// 标记 AP 已启动
pub fn markApStarted(cpu_index: u32) void {
    if (cpu_index < MAX_CPUS) ap_started[cpu_index] = true;
}

/// 初始化 AP 启动环境
pub fn initApBootEnvironment() void {
    if (builtin.cpu.arch != .aarch64) return;

    const cpu_count = cpu_topo.logicalCpuCount();
    if (cpu_count <= 1) return;

    klog.info("AArch64 SMP: initializing boot environment for %u APs", .{cpu_count - 1});

    for (0..MAX_CPUS) |i| {
        ap_started[i] = false;
    }

    // 记录 AP 入口地址（符号引用）
    const ap_entry: u64 = @intFromPtr(&aarch64_ap_entry);
    klog.info("AArch64 SMP: AP entry va=0x%x stacks allocated", .{ap_entry});
}

/// 通过 PSCI cpu_on 启动单个 AP
fn startCpu(cpu_index: u32, mpidr: u64) void {
    if (cpu_index >= MAX_CPUS) return;

    const ap_entry: u64 = @intFromPtr(&aarch64_ap_entry);
    const stack_top: u64 = getApStackTop(cpu_index);

    klog.debug("AArch64 SMP: starting CPU%u mpidr=0x%x entry=0x%x stack=0x%x", .{
        cpu_index, mpidr, ap_entry, stack_top,
    });

    // AP 入口必须是 4KiB 对齐
    if (ap_entry & 0xFFF != 0) {
        klog.err("AArch64 SMP: AP entry not 4KiB-aligned", .{});
        return;
    }

    const result = psci.cpuOn(mpidr, ap_entry, stack_top);
    if (result == psci.PSCI_SUCCESS) {
        markApStarted(cpu_index);
        klog.info("AArch64 SMP: CPU%u started (mpidr=0x%x)", .{ cpu_index, mpidr });
    } else {
        klog.warn("AArch64 SMP: CPU%u start failed (PSCI err=%d)", .{ cpu_index, result });
    }
}

/// 启动所有 AP
pub fn wakeApplicationProcessorsStub() void {
    if (builtin.cpu.arch != .aarch64) return;
    if (builtin.os.tag != .freestanding) return;

    const cpu_count = cpu_topo.logicalCpuCount();
    if (cpu_count <= 1) return;

    initApBootEnvironment();

    klog.info("AArch64 SMP: waking %u APs via PSCI", .{cpu_count - 1});

    const bsp_mpidr = cpu_topo.currentMpidrAffinity();
    for (1..@min(cpu_count, MAX_CPUS)) |i| {
        // QEMU virt: Aff0 = CPU index; 真实硬件需从 ACPI MADT/GIC CPU Interface 获取 MPIDR
        const mpidr = buildQemuVirtMpidr(@as(u32, @intCast(i)));
        if (mpidr != bsp_mpidr) {
            startCpu(@as(u32, @intCast(i)), mpidr);
        }
    }

    klog.info("AArch64 SMP: all APs dispatched via PSCI", .{});
}

pub fn initSmpTopology() void {
    @import("cpu_topology.zig").initTopology();
}

/// 标记当前 CPU 是否为 BSP（MPIDR = 0 为 BSP）
pub fn isBsp() bool {
    return cpu_topo.currentMpidrAffinity() == 0;
}

