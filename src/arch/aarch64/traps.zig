//! AArch64 EL1 trap dispatcher.
//! Installs VBAR_EL1 pointing at `exception_vector.S`; dispatches synchronous
//! exceptions (SVC, data abort, instruction abort) and IRQs (GIC timer, peripherals).
//! Ref: ARM DDI 0487 — Exception handling at EL1.

const klog = @import("../../rtl/klog.zig");
const scheduler = @import("../../ke/scheduler.zig");
const gic = @import("../../hal/aarch64/gic.zig");
const arm_timer = @import("../../hal/aarch64/timer.zig");
const arch = @import("../../arch.zig");

extern fn aarch64_exception_vectors() align(2048) void;

/// Must match layout in exception_vector.S (36 x u64, 288 bytes).
pub const TrapFrame = extern struct {
    x0: u64,
    x1: u64,
    x2: u64,
    x3: u64,
    x4: u64,
    x5: u64,
    x6: u64,
    x7: u64,
    x8: u64,
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
    x29: u64, // FP
    x30: u64, // LR
    saved_sp: u64,
    elr: u64,
    spsr: u64,
    esr: u64,
    far: u64,
};

// ESR_EL1 Exception Class field [31:26]
const ESR_EC_SHIFT: u6 = 26;
const ESR_EC_MASK: u64 = 0x3F << ESR_EC_SHIFT;

const EC_SVC_A64: u32 = 0x15;
const EC_IABT_LOWER: u32 = 0x20;
const EC_IABT_SAME: u32 = 0x21;
const EC_DABT_LOWER: u32 = 0x24;
const EC_DABT_SAME: u32 = 0x25;
const EC_SP_ALIGN: u32 = 0x26;
const EC_BRK: u32 = 0x3C;

// GIC PPI timer IRQ (ARM Generic Timer physical timer)
const TIMER_PPI_IRQ: u32 = 30;
const SPURIOUS_IRQ: u32 = 1023;

fn haltForever() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

/// Synchronous exception from EL1 (kernel fault).
export fn aarch64_dispatch_sync_el1_sp0(frame: *TrapFrame) callconv(.c) void {
    aarch64_dispatch_sync_el1(frame);
}

/// Synchronous exception from EL1 with SP_ELx.
export fn aarch64_dispatch_sync_el1(frame: *TrapFrame) callconv(.c) void {
    const ec: u32 = @truncate((frame.esr & ESR_EC_MASK) >> ESR_EC_SHIFT);
    switch (ec) {
        EC_DABT_SAME => {
            decodeAndLogDAbort(frame, "kernel", frame.elr, frame.far, frame.esr);
            haltForever();
        },
        EC_IABT_SAME => {
            decodeAndLogIAbort(frame, "kernel", frame.elr, frame.far, frame.esr);
            haltForever();
        },
        EC_SP_ALIGN => {
            klog.err("AArch64: SP alignment fault ELR=0x%x", .{frame.elr});
            haltForever();
        },
        EC_BRK => {
            klog.err("AArch64: BRK in kernel ELR=0x%x", .{frame.elr});
            haltForever();
        },
        else => {
            klog.err("AArch64: unhandled kernel sync EC=0x%x ELR=0x%x ESR=0x%x", .{
                ec, frame.elr, frame.esr,
            });
            haltForever();
        },
    }
}

/// Decode ISS fields for Data Abort (EC=0x24/0x25) and print diagnostic.
/// ISS[10] = WnR (0=read, 1=write), ISS[6] = S1PTW, ISS[5:2] = AR.
fn decodeAndLogDAbort(frame: *TrapFrame, comptime ctx: []const u8, elr: u64, far: u64, esr: u64) void {
    const iss = esr & 0x1FFF_FFFF;
    const wnr = (iss >> 10) & 1;
    const s1ptw = (iss >> 6) & 1;
    const dfsc = iss & 0x3F;
    klog.err("AArch64: Data Abort [%s] ELR=0x%x FAR=0x%x", .{ ctx, elr, far });
    klog.err("  ESR=0x%x ISS=0x%x WnR=%u S1PTW=%u DFSC=0x%x", .{
        esr, iss, wnr, s1ptw, dfsc,
    });
    klog.err("  DFSC meaning: 0x%02X — %s", .{ dfsc, dfscMeaning(dfsc) });
    _ = frame;
}

/// Decode ISS fields for Instruction Abort (EC=0x20/0x21) and print diagnostic.
fn decodeAndLogIAbort(frame: *TrapFrame, comptime ctx: []const u8, elr: u64, far: u64, esr: u64) void {
    const iss = esr & 0x1FFF_FFFF;
    const ifsc = iss & 0x3F;
    klog.err("AArch64: Instruction Abort [%s] ELR=0x%x FAR=0x%x", .{ ctx, elr, far });
    klog.err("  ESR=0x%x ISS=0x%x IFSC=0x%x", .{
        esr, iss, ifsc,
    });
    klog.err("  IFSC meaning: 0x%02X — %s", .{ ifsc, dfscMeaning(ifsc) });
    _ = frame;
}

/// Human-readable translation fault / address size fault description.
/// Ref: ARM DDI 0487 §D10-3760 / §C5.1.30 DFSC / IFSC.
fn dfscMeaning(dfsc: u64) []const u8 {
    return switch (dfsc) {
        0x00 => "Address size fault, L0",
        0x01 => "Address size fault, L1",
        0x02 => "Address size fault, L2",
        0x03 => "Address size fault, L3",
        0x04 => "Translation fault, L0",
        0x05 => "Translation fault, L1",
        0x06 => "Translation fault, L2",
        0x07 => "Translation fault, L3",
        0x09 => "Access flag fault, L1",
        0x0B => "Access flag fault, L2",
        0x0D => "Access flag fault, L3",
        0x0C => "Access flag fault, L0",
        0x08 => "Permission fault, L0",
        0x0E => "Permission fault, L1",
        0x10 => "Permission fault, L2",
        0x12 => "Permission fault, L3",
        0x11 => "External abort, L1 non-trans",
        0x13 => "External abort, L2 non-trans",
        0x15 => "External abort, L3 non-trans",
        0x14 => "External abort, L1 trans",
        0x16 => "External abort, L2 trans",
        0x18 => "External abort, L3 trans",
        0x19 => "Domain fault, L1",
        0x1B => "Domain fault, L2",
        0x1D => "Domain fault, L3",
        0x1C => "Domain fault, L0",
        0x1F => "TLB conflict abort",
        else => "unknown",
    };
}

/// Synchronous exception from lower EL (user mode: SVC, page faults).
export fn aarch64_dispatch_sync_lower(frame: *TrapFrame) callconv(.c) void {
    const ec: u32 = @truncate((frame.esr & ESR_EC_MASK) >> ESR_EC_SHIFT);
    switch (ec) {
        EC_SVC_A64 => {
            const syscall_a64 = @import("syscall_dispatch.zig");
            frame.x0 = syscall_a64.dispatch(frame);
            frame.elr += 4;
        },
        EC_DABT_LOWER => {
            decodeAndLogDAbort(frame, "user", frame.elr, frame.far, frame.esr);
            handleUserPageFault(frame, ec);
        },
        EC_IABT_LOWER => {
            decodeAndLogIAbort(frame, "user", frame.elr, frame.far, frame.esr);
            handleUserPageFault(frame, ec);
        },
        else => {
            klog.err("AArch64: unhandled lower sync EC=0x%x ELR=0x%x ESR=0x%x", .{
                ec, frame.elr, frame.esr,
            });
            haltForever();
        },
    }
}

fn handleUserPageFault(frame: *TrapFrame, ec: u32) void {
    const fault_addr = frame.far;
    const is_write = (ec == EC_DABT_LOWER) and ((frame.esr & (1 << 6)) != 0);

    const process = @import("../../ps/process.zig");
    if (process.getCurrentProcess()) |proc| {
        if (proc.address_space) |asp| {
            const vm = @import("../../mm/vm.zig");
            if (vm.handleUserDemandOrCowFault(asp, fault_addr, is_write)) {
                return;
            }
            const pid = proc.pid;
            _ = process.terminateProcess(pid, 0xC0000005);
            klog.err("AArch64: user page fault ACCESS_VIOLATION (addr=0x%x EC=0x%x) PID=%u — terminated", .{
                fault_addr, ec, pid,
            });
            haltForever();
        }
    }

    const bc = @import("../../ke/bugcheck.zig");
    bc.keBugCheckEx(.page_fault_in_nonpaged_area, fault_addr, 0, ec, 0);
}

/// IRQ handler for all exception levels.
export fn aarch64_dispatch_irq_el1(_: *TrapFrame) callconv(.c) void {
    const irq = gic.acknowledge();
    if (irq == SPURIOUS_IRQ) return;

    if (irq == TIMER_PPI_IRQ) {
        arm_timer.clearInterrupt();
        scheduler.tick();
        klog.notifyTimerTick();
        const hub = @import("../../drivers/input/input_hub.zig");
        hub.pollAll();
    } else {
        klog.debug("AArch64: IRQ %u", .{irq});
    }

    gic.endOfInterrupt(irq);
}

/// FIQ handler (not used, log and return).
export fn aarch64_dispatch_fiq_el1(_: *TrapFrame) callconv(.c) void {
    klog.warn("AArch64: unexpected FIQ", .{});
}

/// SError handler.
export fn aarch64_dispatch_serror_el1(frame: *TrapFrame) callconv(.c) void {
    klog.err("AArch64: SError ELR=0x%x ESR=0x%x", .{ frame.elr, frame.esr });
    haltForever();
}

/// Install exception vector table and configure MAIR/TCR for proper memory attributes.
pub fn init() void {
    arch.disableInterrupts();

    const vbar = @intFromPtr(&aarch64_exception_vectors);
    asm volatile ("msr vbar_el1, %[v]" :: [v] "r" (vbar));

    // MAIR_EL1: Attr0 = Normal WB (0xFF), Attr1 = Device-nGnRnE (0x00)
    const mair: u64 = 0x00000000000000FF;
    asm volatile ("msr mair_el1, %[m]" :: [m] "r" (mair));
    asm volatile ("isb");

    klog.info("AArch64 traps: VBAR_EL1=0x%x MAIR=0x%x", .{ vbar, mair });
}
