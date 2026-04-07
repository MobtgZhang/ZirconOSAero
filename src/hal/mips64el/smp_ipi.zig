//! MIPS64EL IPI (Inter-Processor Interrupt) stub for Loongson 3A platforms.
//! Loongson 3A uses platform-specific mailbox registers, not standard MIPS mechanism.

const paging = @import("../../arch/mips64el/paging.zig");

pub fn broadcastFullTlbShootdownStub() void {
    // Single-core: local TLB flush only.
    paging.invtlbAll();
}

pub fn clearLocalIpi() void {
    // Stub: Loongson IPI clear would write to platform-specific MMIO register.
}

pub fn handleIpiInterrupt() void {
    // On receiving IPI from another core: flush local TLB.
    paging.invtlbAll();
    clearLocalIpi();
}
