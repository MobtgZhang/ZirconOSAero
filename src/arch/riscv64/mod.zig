pub const boot = @import("boot.zig");
pub const paging = @import("paging.zig");
pub const framebuffer = @import("../../hal/riscv64/framebuffer.zig");
const uart = @import("../../hal/riscv64/uart.zig");
const plic = @import("../../hal/riscv64/plic.zig");

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
    // stvec：在完整 trap 框架前，异常时 UART 输出 `>` 并停机，避免无声崩溃
    asm volatile ("csrw stvec, %[p]"
        :
        : [p] "r" (@intFromPtr(&riscv_early_trap_entry)),
        : .{ .memory = true }
    );
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
        : [result] "=r" (-> u64)
    );
    sie |= (1 << 5);
    asm volatile ("csrw sie, %[val]"
        :
        : [val] "r" (sie)
    );
}

pub fn initPic() void {
    plic.init();
}

pub fn unmaskIrq(irq: u8) void {
    plic.enableIrq(@as(u32, irq));
}

pub fn enableInterrupts() void {
    asm volatile ("csrsi sstatus, 0x2");
}

pub fn disableInterrupts() void {
    asm volatile ("csrci sstatus, 0x2");
}
