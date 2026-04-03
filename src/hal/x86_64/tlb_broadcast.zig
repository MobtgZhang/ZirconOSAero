// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/hal/x86_64/tlb_broadcast.zig
// Purpose: TLB shootdown 占位（BSP 本地刷新 + 未来 IPI 向量扩展）。
//
// This is an independent clean-room implementation.
// Reference: Intel SDM — INVLPG / TLB; MS Learn — multiprocessor TLB invalidation (conceptual).
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K2.5（IPI shootdown）。

const builtin = @import("builtin");
const std = @import("std");
const paging = @import("../../arch/x86_64/paging.zig");
const klog = @import("../../rtl/klog.zig");

/// SMP 就绪后由页表更新路径递增；当前仅占位，供诊断与将来 IPI 批处理。
var pending_shootdown_hint: std.atomic.Value(u32) = .init(0);

pub fn notePendingGlobalShootdown() void {
    _ = pending_shootdown_hint.fetchAdd(1, .monotonic);
}

pub fn pendingShootdownHint() u32 {
    return pending_shootdown_hint.load(.monotonic);
}

/// 用户区 `unmap` / `unmapRange` 后调用：本地已由 `invlpg`/全刷处理当前核，多核时其它逻辑 CPU 仍可能缓存旧 TLB；递增提示计数供诊断，完整 IPI shootdown 见 K2.5。
pub fn noteUserMappingInvalidatedSmp() void {
    if (builtin.cpu.arch != .x86_64) return;
    const madt = @import("madt.zig");
    if (madt.logical_cpu_count <= 1) return;
    _ = pending_shootdown_hint.fetchAdd(1, .monotonic);
}

pub fn flushLocal() void {
    paging.flushTlb();
}

/// 当前无在线 AP 时等价于 `flushLocal`。SMP 就绪后：在修改**内核共享**页表项后应经 IPI 触发各核 `INVLPG`/全 TLB 刷新（见 Intel SDM TLB 一致性；本函数暂为 BSP 占位）。固定投递助手见 `lapic_smp.broadcastFixedIpiExcludingSelf`（须登记专用 IDT 向量并在处理例程中 `flushLocal`）。
/// `vm.releaseProcessAddressSpace` / `unmapRange` 在拆除用户映射前后会调用 `notePendingGlobalShootdown` 与 `noteUserMappingInvalidatedSmp`（K2.5 与诊断计数）。
/// `vm.releaseProcessAddressSpace` 在释放他进程页表后调用本函数，避免当前核残留陈旧 global 项（与 PCID/INVPCID 策略见契约矩阵）。
///
/// **K2.5 安全说明（BSP-only 刷新）**：当 `logical_cpu_count > 1` 且 AP 已在实模式/长模式执行时，仅 BSP `flushLocal()` **不能**保证其它逻辑 CPU TLB 与用户页表一致；当前 AP 路径在 `0x8000` 实模式自旋，未加载进程页表，故 **Stale TLB 风险主要限于未来 AP 参与用户映射后**。上线 AP 调度前必须接线 IPI shootdown 或证明全局 TLB 一致性策略。
pub fn requestGlobalFlushStub() void {
    flushLocal();
    if (builtin.cpu.arch == .x86_64 and @import("build_options").smp_tlb_ipi) {
        const madt = @import("madt.zig");
        if (madt.logical_cpu_count > 1) {
            const isr = @import("../../arch/x86_64/isr.zig");
            @import("lapic_smp.zig").broadcastFixedIpiExcludingSelf(isr.ipi_tlb_flush_vector);
        }
    } else if (builtin.cpu.arch == .x86_64) {
        const madt = @import("madt.zig");
        if (madt.logical_cpu_count > 1 and @import("build_options").debug) {
            klog.debug("TLB: global flush BSP-local; set -Dsmp_tlb_ipi=true for IPI vector %u (unsafe if AP lacks IDT)", .{
                @import("../../arch/x86_64/isr.zig").ipi_tlb_flush_vector,
            });
        }
    }
    pending_shootdown_hint.store(0, .monotonic);
}

/// 与 `requestGlobalFlushStub` 同义；供页表释放路径语义化命名（将来可在此插入 IPI 批处理）。
pub const requestGlobalSmpCoherentFlushBestEffort = requestGlobalFlushStub;
