pub const boot = @import("boot.zig");
pub const fb = @import("../../drivers/video/core/framebuffer.zig");
pub const paging = @import("paging.zig");
pub const framebuffer = @import("../../hal/riscv64/framebuffer.zig");
pub const traps = @import("traps.zig");
pub const thread_switch = @import("thread_switch.zig");
const uart = @import("../../hal/riscv64/uart.zig");
const plic = @import("../../hal/riscv64/plic.zig");
const sbi = @import("../../hal/riscv64/sbi.zig");

extern fn riscv_early_trap_entry() align(4) void;

pub const name: []const u8 = "riscv64";
pub const PAGE_SIZE: usize = 4096;

pub fn initFramebuffer(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    framebuffer.init(addr, width, height, pitch, bpp);
}

pub fn consoleWrite(s: []const u8) void {
    uart.write(s);
}

pub fn consoleClear() void {}

pub fn initSerial() void {
    uart.init();
    asm volatile ("csrw stvec, %[p]"
        :
        : [p] "r" (@intFromPtr(&riscv_early_trap_entry)),
        : .{ .memory = true });
}

pub fn serialWrite(s: []const u8) void {
    uart.write(s);
}

pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

pub fn standby() noreturn {
    halt();
}

pub fn shutdown() noreturn {
    asm volatile ("ecall"
        :
        : [a0] "{a0}" (@as(u64, 0)),
          [a1] "{a1}" (@as(u64, 0)),
          [a6] "{a6}" (@as(u64, 0)),
          [a7] "{a7}" (@as(u64, 0x53525354)),
    );
    halt();
}

pub fn reset() noreturn {
    asm volatile ("ecall"
        :
        : [a0] "{a0}" (@as(u64, 1)),
          [a1] "{a1}" (@as(u64, 0)),
          [a6] "{a6}" (@as(u64, 0)),
          [a7] "{a7}" (@as(u64, 0x53525354)),
    );
    halt();
}

pub fn sendEoi(irq: u8) void {
    plic.complete(@as(u32, irq));
}

pub fn initTimer() void {
    var sie: u64 = asm ("csrr %[result], sie"
        : [result] "=r" (-> u64),
    );
    sie |= (1 << 5); // STIE — S-mode timer interrupt enable
    sie |= (1 << 9); // SEIE — S-mode external interrupt enable
    asm volatile ("csrw sie, %[val]"
        :
        : [val] "r" (sie),
    );
    sbi.setTimer(sbi.readTime() + 100_000);
}

pub fn initPic() void {
    plic.init();
}

pub fn unmaskIrq(irq: u8) void {
    if (irq == 0) return;
    plic.enableIrq(@as(u32, irq));
}

pub fn enableInterrupts() void {
    asm volatile ("csrsi sstatus, 0x2");
}

pub fn disableInterrupts() void {
    asm volatile ("csrci sstatus, 0x2");
}

/// `sstatus.SIE` (bit 1): 1 means S-mode interrupts were enabled.
/// Ref: RISC-V Privileged Spec — sstatus.
pub fn saveAndDisableInterrupts() bool {
    const s: usize = asm volatile ("csrr %[r], sstatus"
        : [r] "=r" (-> usize),
    );
    asm volatile ("csrci sstatus, 0x2" ::: .{ .memory = true });
    return (s & 0x2) != 0;
}

pub fn restoreInterrupts(were_enabled: bool) void {
    if (were_enabled) {
        asm volatile ("csrsi sstatus, 0x2" ::: .{ .memory = true });
    }
}

pub fn linkerKernelEndExclusive() usize {
    const end_ptr: *const u8 = &@extern(*const u8, .{ .name = "_kernel_end" });
    return @intFromPtr(end_ptr);
}

/// AP (Application Processor) 入口点，从汇编代码调用
export fn riscv_ap_init(hartid: u64) noreturn {
    _ = hartid; // 目前未使用hartid参数，后续SMP实现会用到
    // 初始化S模式中断
    asm volatile ("csrw stvec, %[p]"
        :
        : [p] "r" (@intFromPtr(&riscv_early_trap_entry)),
        : .{ .memory = true });

    // 启用中断
    enableInterrupts();

    // 目前先让AP核进入休眠，后续完善SMP支持
    while (true) {
        asm volatile ("wfi");
    }
}
