// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - Unified HAL interrupt dispatch

const builtin = @import("builtin");

const X86Dispatch = @import("../arch/x86_64/interrupt.zig");
const StubDispatch = @import("../ke/interrupt_stub.zig");

pub const Dispatch = switch (builtin.target.cpu.arch) {
    .x86_64 => X86Dispatch,
    else => StubDispatch,
};
