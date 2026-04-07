//! MIPS64EL: `syscall` instruction → ExcCode=8; read $v0 as service number from trap frame,
//! dispatch, write result back to $v0, advance EPC past the syscall instruction.

const klog = @import("../../rtl/klog.zig");
const build_options = @import("build_options");

/// Trap frame offsets matching mips_defs.h / exceptions.S
const TF_V0: usize = 16;
const TF_A0: usize = 32;
const TF_EPC: usize = 272;

fn readU64(frame_sp: usize, off: usize) u64 {
    return @as(*const volatile u64, @ptrFromInt(frame_sp + off)).*;
}

fn writeU64(frame_sp: usize, off: usize, v: u64) void {
    @as(*volatile u64, @ptrFromInt(frame_sp + off)).* = v;
}

/// Called from traps.zig when ExcCode == 8 (Syscall).
pub fn handleFromTrapFrame(frame_sp: usize) void {
    const svc = readU64(frame_sp, TF_V0);
    if (build_options.debug) {
        klog.debug("MIPS syscall: idx=0x%x a0=0x%x", .{
            @as(u32, @truncate(svc)), @as(u32, @truncate(readU64(frame_sp, TF_A0))),
        });
    }

    const syscall_dispatch = @import("syscall_dispatch.zig");
    const result = syscall_dispatch.dispatch(frame_sp);

    // Write return value to $v0 slot in trap frame
    writeU64(frame_sp, TF_V0, result);

    // Advance EPC by 4 to skip the `syscall` instruction
    const epc = readU64(frame_sp, TF_EPC);
    writeU64(frame_sp, TF_EPC, epc + 4);

    // Deliver kernel APCs before returning to user
    @import("../../ke/apc.zig").deliverKernelApcsForCurrentThread();

    // Re-activate process address space (may have changed during syscall)
    const process = @import("../../ps/process.zig");
    if (process.getCurrentProcess()) |proc| {
        if (proc.address_space) |asp| asp.activate();
    }
}
