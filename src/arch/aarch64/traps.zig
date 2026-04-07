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
        EC_DABT_SAME, EC_IABT_SAME => {
            klog.err("AArch64: kernel abort ELR=0x%x FAR=0x%x ESR=0x%x", .{
                frame.elr, frame.far, frame.esr,
            });
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

/// Synchronous exception from lower EL (user mode: SVC, page faults).
export fn aarch64_dispatch_sync_lower(frame: *TrapFrame) callconv(.c) void {
    const ec: u32 = @truncate((frame.esr & ESR_EC_MASK) >> ESR_EC_SHIFT);
    switch (ec) {
        EC_SVC_A64 => {
            const syscall_a64 = @import("syscall_dispatch.zig");
            frame.x0 = syscall_a64.dispatch(frame);
            frame.elr += 4;
        },
        EC_DABT_LOWER, EC_IABT_LOWER => {
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
