// SPDX-License-Identifier: MIT OR Apache-2.0
// AArch64: TLB consistency stubs after process page table release / multi-mapping teardown.
// Interface shape aligned with `hal/x86_64/tlb_broadcast.zig` and `hal/loongarch64/tlb_flush.zig`.

const builtin = @import("builtin");
const std = @import("std");

var pending_shootdown_hint: std.atomic.Value(u32) = .init(0);

pub fn notePendingGlobalShootdown() void {
    _ = pending_shootdown_hint.fetchAdd(1, .monotonic);
}

pub fn pendingShootdownHint() u32 {
    return pending_shootdown_hint.load(.monotonic);
}

pub fn noteUserMappingInvalidatedSmp() void {
    _ = pending_shootdown_hint.fetchAdd(1, .monotonic);
    const n = @import("cpu_topology.zig").logicalCpuCount();
    if (n > 1) {
        broadcastTlbiStub();
    }
}

fn tlbiVmalle1() void {
    if (builtin.os.tag != .freestanding) return;
    asm volatile ("tlbi vmalle1\ndsb sy\nisb" ::: .{ .memory = true });
}

/// GICv2 SGI-based IPI for TLB shootdown (placeholder for SMP).
fn broadcastTlbiStub() void {
    // When SMP is enabled, send SGI to all other cores requesting TLBI.
    // For now, just flush the local TLB.
    tlbiVmalle1();
}

pub fn requestGlobalFlushStub() void {
    broadcastTlbiStub();
    tlbiVmalle1();
    pending_shootdown_hint.store(0, .monotonic);
}

pub const requestGlobalSmpCoherentFlushBestEffort = requestGlobalFlushStub;
