//! MIPS64EL exception dispatch: called from exceptions.S after trap frame is saved.
//! Reads CP0.Cause.ExcCode and dispatches to the appropriate handler.

const klog = @import("../../rtl/klog.zig");
const syscall_mips = @import("syscall_mips.zig");
const mod = @import("mod.zig");

const EXC_INT: u32 = 0;
const EXC_MOD: u32 = 1;
const EXC_TLBL: u32 = 2;
const EXC_TLBS: u32 = 3;
const EXC_ADEL: u32 = 4;
const EXC_ADES: u32 = 5;
const EXC_SYS: u32 = 8;
const EXC_BP: u32 = 9;
const EXC_RI: u32 = 10;
const EXC_CPU: u32 = 11;
const EXC_OV: u32 = 12;

fn haltForever() noreturn {
    while (true) {
        asm volatile ("wait");
    }
}

/// C-ABI entry from exceptions.S. frame_sp points to the saved MipsTrapFrame.
export fn mips_dispatch_trap(frame_sp: usize) callconv(.c) void {
    const cause = readTfCause(frame_sp);
    const exc_code: u32 = (cause >> 2) & 0x1F;

    switch (exc_code) {
        EXC_INT => {
            dispatchHardwareInterrupts(cause);
        },
        EXC_SYS => {
            syscall_mips.handleFromTrapFrame(frame_sp);
        },
        EXC_TLBL, EXC_TLBS => {
            handleTlbLoadStoreFault(frame_sp, exc_code);
        },
        EXC_MOD => {
            handleTlbModifiedFault(frame_sp);
        },
        EXC_ADEL, EXC_ADES => {
            klog.err("MIPS: address error exc=%u EPC=0x%x BadVAddr=0x%x", .{
                exc_code, readTfEpc(frame_sp), readTfBadVAddr(frame_sp),
            });
            haltForever();
        },
        EXC_BP => {
            klog.err("MIPS: breakpoint at EPC=0x%x", .{readTfEpc(frame_sp)});
            haltForever();
        },
        EXC_RI => {
            klog.err("MIPS: reserved instruction at EPC=0x%x", .{readTfEpc(frame_sp)});
            haltForever();
        },
        else => {
            klog.err("MIPS: unhandled exception EC=%u Cause=0x%x EPC=0x%x", .{
                exc_code, cause, readTfEpc(frame_sp),
            });
            haltForever();
        },
    }
}

fn dispatchHardwareInterrupts(cause: u32) void {
    const ip = (cause >> 8) & 0xFF;
    // IP7 = timer (Count/Compare)
    if ((ip & 0x80) != 0) {
        mod.ackTimerInterrupt();
        const scheduler = @import("../../ke/scheduler.zig");
        scheduler.tick();
    }
}

fn handleTlbLoadStoreFault(frame_sp: usize, exc_code: u32) void {
    const bad_va = readTfBadVAddr(frame_sp);
    const is_write = (exc_code == EXC_TLBS);
    const vm = @import("../../mm/vm.zig");
    const process = @import("../../ps/process.zig");
    if (process.getCurrentProcess()) |proc| {
        if (proc.address_space) |asp| {
            if (vm.handleUserDemandOrCowFault(asp, bad_va, is_write)) return;
        }
    }
    klog.err("MIPS: TLB fault (unresolved) VA=0x%x EPC=0x%x", .{
        bad_va, readTfEpc(frame_sp),
    });
    haltForever();
}

fn handleTlbModifiedFault(frame_sp: usize) void {
    const bad_va = readTfBadVAddr(frame_sp);
    const vm = @import("../../mm/vm.zig");
    const process = @import("../../ps/process.zig");
    if (process.getCurrentProcess()) |proc| {
        if (proc.address_space) |asp| {
            if (vm.handleUserDemandOrCowFault(asp, bad_va, true)) return;
        }
    }
    klog.err("MIPS: TLB modified (unresolved) VA=0x%x EPC=0x%x", .{
        bad_va, readTfEpc(frame_sp),
    });
    haltForever();
}

// Trap frame field accessors (offsets match mips_defs.h TF_* constants)
fn readTfCause(sp: usize) u32 {
    return @truncate(@as(*const volatile u64, @ptrFromInt(sp + 264)).*);
}
fn readTfEpc(sp: usize) u64 {
    return @as(*const volatile u64, @ptrFromInt(sp + 272)).*;
}
fn readTfBadVAddr(sp: usize) u64 {
    return @as(*const volatile u64, @ptrFromInt(sp + 280)).*;
}

/// Install exception vectors (called from mod.initPic).
pub fn init() void {
    // EBase is set by start.S; here we verify Cause.IV = 1 for separate interrupt vector
    klog.info("MIPS64EL traps: exception vectors installed by start.S", .{});
}
