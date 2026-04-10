//! RISC-V 64 S-mode trap dispatcher.
//! Called from trap.S with a pointer to the TrapFrame on the kernel stack.

const klog = @import("../../rtl/klog.zig");
const scheduler = @import("../../ke/scheduler.zig");
const sbi = @import("../../hal/riscv64/sbi.zig");
const plic = @import("../../hal/riscv64/plic.zig");

extern fn riscv_trap_entry() align(4) void;

/// Must match the layout in trap.S (34 x u64, 272 bytes).
pub const TrapFrame = extern struct {
    x1_ra: u64,
    x3_gp: u64,
    x4_tp: u64,
    x5_t0: u64,
    x6_t1: u64,
    x7_t2: u64,
    x8_s0: u64,
    x9_s1: u64,
    x10_a0: u64,
    x11_a1: u64,
    x12_a2: u64,
    x13_a3: u64,
    x14_a4: u64,
    x15_a5: u64,
    x16_a6: u64,
    x17_a7: u64,
    x18_s2: u64,
    x19_s3: u64,
    x20_s4: u64,
    x21_s5: u64,
    x22_s6: u64,
    x23_s7: u64,
    x24_s8: u64,
    x25_s9: u64,
    x26_s10: u64,
    x27_s11: u64,
    x28_t3: u64,
    x29_t4: u64,
    x30_t5: u64,
    x31_t6: u64,
    sepc: u64,
    sstatus: u64,
    scause: u64,
};

const SCAUSE_INTERRUPT: u64 = 1 << 63;
const SCAUSE_S_TIMER: u64 = SCAUSE_INTERRUPT | 5;
const SCAUSE_S_EXTERNAL: u64 = SCAUSE_INTERRUPT | 9;
const SCAUSE_ECALL_U: u64 = 8;
const SCAUSE_INST_PAGE_FAULT: u64 = 12;
const SCAUSE_LOAD_PAGE_FAULT: u64 = 13;
const SCAUSE_STORE_PAGE_FAULT: u64 = 15;

/// Approximate QEMU virt timebase frequency (10 MHz typical).
/// Replaced by sbi_timebase.getTimebase() at runtime when available.
const TIMER_FREQ: u64 = 10_000_000;
const TIMER_HZ: u64 = 100;

fn armNextTimer() void {
    const sbi_timebase_mod = @import("../../hal/riscv64/sbi_timebase.zig");
    const freq = sbi_timebase_mod.getTimebase();
    const now = sbi.readTime();
    sbi.setTimer(now + freq / TIMER_HZ);
}

/// Install the real stvec (replaces the early trap handler from start.S/mod.zig).
pub fn init() void {
    const vec_addr = @intFromPtr(&riscv_trap_entry);
    asm volatile ("csrw stvec, %[v]"
        :
        : [v] "r" (vec_addr),
        : .{ .memory = true });
    armNextTimer();
}

/// 分发 IRQ 给对应的处理程序
fn dispatchIrq(irq: u32) void {
    switch (irq) {
        // QEMU virt: virtio-net = IRQ 1 (common assignment varies, log for now)
        1 => {
            klog.debug("riscv64: virtio-net IRQ %u", .{irq});
        },
        // QEMU virt: RTC = IRQ 22
        22 => {
            klog.debug("riscv64: RTC IRQ %u", .{irq});
        },
        // Console/serial (polled mode, no handler needed)
        else => {
            klog.debug("riscv64: unhandled IRQ %u", .{irq});
        },
    }
}

/// Entry from trap.S — exported as C symbol for the assembly `call`.
export fn riscv_dispatch_trap(frame: *TrapFrame) callconv(.c) void {
    const cause = frame.scause;

    if (cause == SCAUSE_S_TIMER) {
        armNextTimer();
        scheduler.tick();
        klog.notifyTimerTick();
        return;
    }

    if (cause == SCAUSE_S_EXTERNAL) {
        const irq = plic.claim();
        if (irq != 0) {
            dispatchIrq(irq);
            plic.complete(irq);
        }
        return;
    }

    if (cause == SCAUSE_ECALL_U) {
        frame.sepc += 4;
        handleEcallSyscall(frame);
        return;
    }

    if (cause == SCAUSE_LOAD_PAGE_FAULT or
        cause == SCAUSE_STORE_PAGE_FAULT or
        cause == SCAUSE_INST_PAGE_FAULT)
    {
        const stval: u64 = asm volatile ("csrr %[r], stval"
            : [r] "=r" (-> u64),
        );
        const fault_va = stval;
        const pc = frame.sepc;
        const is_user = (frame.sstatus & (1 << 18)) != 0; // SSTATUS.SUM bit

        if (is_user) {
            const is_write = (cause == SCAUSE_STORE_PAGE_FAULT);
            const process = @import("../../ps/process.zig");
            if (process.getCurrentProcess()) |proc| {
                if (proc.address_space) |asp| {
                    const vm = @import("../../mm/vm.zig");
                    if (vm.handleUserDemandOrCowFault(asp, fault_va, is_write)) {
                        return;
                    }
                    _ = process.terminateProcess(proc.pid, 0xC0000005);
                    klog.err("riscv64: user page fault ACCESS_VIOLATION (va=0x%x cause=0x%x) PID=%u",
                        .{ fault_va, cause, proc.pid });
                    @import("../riscv64/mod.zig").halt();
                }
            }
        }

        klog.err("riscv64: page fault cause=0x%x sepc=0x%x stval=0x%x", .{
            cause, pc, fault_va,
        });
        @import("../riscv64/mod.zig").halt();
    }

    klog.err("riscv64: unhandled trap scause=0x%x sepc=0x%x", .{ cause, frame.sepc });
    @import("../riscv64/mod.zig").halt();
}

fn handleEcallSyscall(frame: *TrapFrame) void {
    const syscall_rv = @import("syscall_dispatch.zig");
    frame.x10_a0 = @bitCast(syscall_rv.dispatch(frame));
}
