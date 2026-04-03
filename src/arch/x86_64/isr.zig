//! x86_64 ISR (Interrupt Service Routine) declarations
//! Stubs are defined in isr_common.s (assembly)
//! Address table (isr_table) is also in assembly (.rodata)

pub const STUB_COUNT: usize = 48;

/// 固定 IPI：TLB shootdown（`tlb_broadcast` / `lapic_smp.broadcastFixedIpiExcludingSelf`）；须在 IDT 登记专用桩。
pub const ipi_tlb_flush_vector: u8 = 254;

extern const isr_table: [STUB_COUNT]usize;
extern const isr_default_entry: usize;
extern fn isr_stub_254() void;

pub fn getStubAddr(idx: usize) usize {
    if (idx < STUB_COUNT) return isr_table[idx];
    return isr_default_entry;
}

pub fn getDefaultAddr() usize {
    return isr_default_entry;
}

pub fn ipiTlbFlushStubAddr() usize {
    return @intFromPtr(&isr_stub_254);
}

const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;

export fn isr_common_handler(frame: *InterruptFrame) callconv(.c) void {
    const interrupt = @import("../../ke/interrupt.zig");
    interrupt.handle(frame);
}
