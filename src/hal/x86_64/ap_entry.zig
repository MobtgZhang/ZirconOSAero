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
// Module: src/hal/x86_64/ap_entry.zig
// Purpose: AP 跳板第二阶段与 `apKernelEntry`；每核栈、GDT/TSS、`IA32_KERNEL_GS_BASE`、LAPIC software enable、调度器空闲循环。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM Vol.3 / ACPI MADT（行为描述）；`docs/cn/VM_ISOLATION.md`。

const std = @import("std");
const klog = @import("../../rtl/klog.zig");
const kpcr = @import("../../ke/kpcr.zig");
const lapic_smp = @import("lapic_smp.zig");
const gdt_mod = @import("gdt.zig");
const idt_mod = @import("../../arch/x86_64/idt.zig");
const percpu_mod = @import("percpu.zig");
const scheduler = @import("../../ke/scheduler.zig");
const madt = @import("madt.zig");

/// 已进入 `apKernelEntry` 的 AP 数量；供 TLB IPI 等判断。
var g_ap_kernel_entry_count = std.atomic.Value(u32).init(0);

/// AP 内核栈（16KiB×7）；与 `scheduler` `MAX_SCHED_CPUS=8` 一致。
const ap_stack_bytes: usize = 16 * 1024;
const ApStackSlot = struct {
    buf: [ap_stack_bytes]u8 align(16) = undefined,
};
var ap_stack_slots: [7]ApStackSlot = undefined;

/// SIPI 前由 `smp_boot` 填写：`ap_kernel_stack_tops[i]` 为第 `i` 个 AP（`cpu_index=i+1`）的初始 RSP。
pub var ap_kernel_stack_tops: [7]u64 = @splat(0);

/// `apTrampolineIntermediate` 中 `fetchAdd` 得到序号 0..AP-1。
pub var g_ap_boot_seq = std.atomic.Value(u32).init(0);

pub fn apKernelEntryCount() u32 {
    return g_ap_kernel_entry_count.load(.monotonic);
}

pub fn resetApBootSequence() void {
    g_ap_boot_seq.store(0, .release);
}

/// 准备 AP 栈顶并写入 `gdt.tss_by_cpu[cpu_index].rsp0`（`cpu_index` 1..7）。
pub fn prepareApStacksAndTssRsp0() void {
    const n = madt.logical_cpu_count;
    if (n <= 1) return;
    const ap_n: u32 = @min(n - 1, 7);
    var i: u32 = 0;
    while (i < ap_n) : (i += 1) {
        const top = @intFromPtr(&ap_stack_slots[i].buf) + ap_stack_bytes;
        ap_kernel_stack_tops[i] = top;
        gdt_mod.setApKernelRsp0(i + 1, top);
    }
}

/// 长模式跳板尾跳转到此符号：恒等映射下与 BSP 共用内核映像。
export fn apTrampolineIntermediate() callconv(.c) noreturn {
    const seq = g_ap_boot_seq.fetchAdd(1, .acq_rel);
    const slot: usize = @intCast(seq);
    const ap_count: u32 = madt.logical_cpu_count -| 1;
    if (slot >= ap_count or slot >= ap_kernel_stack_tops.len) {
        while (true) {
            asm volatile ("hlt" ::: .{ .memory = true });
        }
    }
    const cpu_index: u32 = @intCast(slot + 1);
    const rsp = ap_kernel_stack_tops[slot];
    asm volatile ("mov %[r], %%rsp"
        :
        : [r] "r" (rsp),
        : .{ .memory = true });

    // J4c：与 BSP 相同的内核 GDT/IDT（映像内只读/数据副本由硬件表指针共享）。
    gdt_mod.reloadKernelGdt();
    if (@import("build_options").enable_idt) {
        idt_mod.reloadKernelIdt();
    }
    gdt_mod.loadTaskRegisterForCpu(cpu_index);

    // J4d：LAPIC software enable。IF：此处仍 cli；在 `apKernelEntry` 经 `scheduler.apProcessorIdleLoop` 再 sti，
    // 避免在 per-CPU GS/TSS 未绑定时响应向量 IPI。
    lapic_smp.ensureLocalApicSoftwareEnabled();
    if (@import("build_options").enable_idt) {
        @import("lapic_timer_tick.zig").attachPeriodicOnApplicationProcessor();
    }

    var block = &percpu_mod.ap_percpu_blocks[slot];
    block.* = .{};
    block.kernel_rsp0 = rsp;
    block.processor_number = cpu_index;
    block.current_thread_index = -1;
    percpu_mod.publishApPerCpuBlock(block);

    apKernelEntry(cpu_index);
}

pub fn apTrampolineIntermediateRip() usize {
    return @intFromPtr(&apTrampolineIntermediate);
}

/// AP 入口：KPCR/GS 已与 `percpu` 一致；进入每核 **sti;hlt** 空闲循环（可被 PIT/IOAPIC 或 IPI 唤醒）。
pub export fn apKernelEntry(cpu_index: u32) callconv(.c) noreturn {
    _ = g_ap_kernel_entry_count.fetchAdd(1, .monotonic);
    kpcr.setProcessorNumber(cpu_index);
    kpcr.setCurrentThreadIndex(-1);
    klog.info("SMP: AP cpu_index=%u online (GDT/TSS/IDT/LAPIC GS; idle=stihlt)", .{cpu_index});
    scheduler.apProcessorIdleLoop();
}
