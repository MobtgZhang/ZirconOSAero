//! MIPS64EL TLB flush helpers — aligned with x86/LoongArch SMP broadcast interface.

const paging = @import("../../arch/mips64el/paging.zig");

var pending_global_shootdown: bool = false;

pub fn notePendingGlobalShootdown() void {
    pending_global_shootdown = true;
}

pub fn pendingShootdownHint() bool {
    const was = pending_global_shootdown;
    pending_global_shootdown = false;
    return was;
}

pub fn noteUserMappingInvalidatedSmp(_va: u64) void {
    // SMP TLB shootdown: on multi-core, send IPI to other cores.
    // Single-core stub — local invalidation only.
    paging.invtlbAddrVa(_va);
}

pub fn requestGlobalFlushStub() void {
    paging.invtlbAll();
    pending_global_shootdown = false;
}
