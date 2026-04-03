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

/// 当前无在线 AP 时等价于 `flushLocal`。多核时：`-Dsmp_tlb_ipi`（x86_64 默认开启）下对**其它逻辑 CPU** 广播固定向量 IPI，`interrupt_x86` 中登记的处理例程执行 `flushLocal` + `sendLocalEoi`（见 `isr.ipi_tlb_flush_vector`）。
/// `vm.releaseProcessAddressSpace` / `unmapRange` 在拆除用户映射前后会调用 `notePendingGlobalShootdown` 与 `noteUserMappingInvalidatedSmp`（诊断计数）。
/// `vm.releaseProcessAddressSpace` 在释放他进程页表后调用本函数，避免当前核残留陈旧 global 项（与 PCID/INVPCID 策略见契约矩阵）。
///
/// **SMP 说明**：AP 经 `apTrampolineIntermediate` / `apKernelEntry` 已加载与 BSP 共用的内核 IDT；未开启 `smp_tlb_ipi` 且 `logical_cpu_count>1` 时仅本地刷新**不足以**保证它核 TLB 与页表一致（见 Intel SDM TLB 一致性）。
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
