// SPDX-License-Identifier: MIT OR Apache-2.0
// LoongArch64：进程页表释放与多映射拆除后的本地 TLB 一致性占位。
// 当前 QEMU virt 目标无 x86 式 MADT/AP 在线表；与 `hal/x86_64/tlb_broadcast.zig` 接口形状对齐，便于 SMP 扩展。

const builtin = @import("builtin");
const std = @import("std");

var pending_shootdown_hint: std.atomic.Value(u32) = .init(0);

pub fn notePendingGlobalShootdown() void {
    _ = pending_shootdown_hint.fetchAdd(1, .monotonic);
}

pub fn pendingShootdownHint() u32 {
    return pending_shootdown_hint.load(.monotonic);
}

/// 记录用户映射失效提示；多核就绪后触发跨核 TLB 一致性。
pub fn noteUserMappingInvalidatedSmp() void {
    _ = pending_shootdown_hint.fetchAdd(1, .monotonic);
    const n = @import("cpu_topology.zig").logicalCpuCount();
    if (n > 1) {
        smp_ipi.broadcastFullTlbShootdownStub();
    }
}

fn invtlbAll() void {
    if (builtin.os.tag != .freestanding) return;
    asm volatile ("invtlb 0x0, $zero, $zero" ::: .{ .memory = true });
}

const smp_ipi = @import("smp_ipi.zig");

/// 释放用户地址空间后刷新 **当前 CPU** 全 TLB；多核就绪后在此插入 IPI 与 `invtlb` 策略。
pub fn requestGlobalFlushStub() void {
    smp_ipi.broadcastFullTlbShootdownStub();
    invtlbAll();
    pending_shootdown_hint.store(0, .monotonic);
}

pub const requestGlobalSmpCoherentFlushBestEffort = requestGlobalFlushStub;
