//! MIPS64EL WoW64 translation engine stub.
//! Defines the interface for x86-32/x86-64 → MIPS64EL dynamic binary translation.
//! Currently returns STATUS_NOT_IMPLEMENTED; a JIT/interpreter can be plugged in later.
//!
//! Clean-room: no Microsoft code; interface designed independently for ZirconOSAero.

const klog = @import("../../../rtl/klog.zig");
const ntdll = @import("../../../libs/ntdll.zig");

pub const EngineState = enum {
    uninitialized,
    probing,
    not_available,
    dbt_ready,
};

var engine_state: EngineState = .uninitialized;

pub fn logBringUpStub() void {
    klog.info("wow64(mips64el): DBT engine stub loaded; software translation required", .{});
    klog.info("wow64(mips64el): Loongson 3A has no hardware x86 translation; pure-software DBT path", .{});
    engine_state = .not_available;
}

pub fn probeEngine() EngineState {
    // Loongson 3A1000-3A4000 MIPS64EL has no hardware binary translation.
    // A software DBT engine (x86 decoder + MIPS64 JIT codegen) would be needed.
    engine_state = .not_available;
    return engine_state;
}

pub fn translateAndExecute(x86_entry: u64, context_ptr: u64) ntdll.NTSTATUS {
    _ = x86_entry;
    _ = context_ptr;
    return ntdll.STATUS_NOT_IMPLEMENTED;
}

pub fn isEngineAvailable() bool {
    return engine_state == .dbt_ready;
}

pub fn getEngineState() EngineState {
    return engine_state;
}
