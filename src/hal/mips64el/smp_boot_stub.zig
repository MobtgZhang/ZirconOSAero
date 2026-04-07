//! MIPS64EL SMP boot stub — AP wake-up framework for Loongson 3A multi-core.
//! Current implementation: single-core only. Multi-core requires platform-specific
//! IPI/Mailbox mechanisms (GCR on Loongson 3A4000, spin-table on older models).

const cpu_topology = @import("cpu_topology.zig");

pub fn wakeApplicationProcessorsStub() void {
    // Loongson 3A multi-core wake-up would use GCR mailbox registers:
    //   - Write AP entry address to IPI_SEND mailbox
    //   - Send IPI to wake each AP
    // Stub: no-op until SMP is fully implemented.
}

pub fn initSmpTopology() void {
    cpu_topology.initTopology();
}
