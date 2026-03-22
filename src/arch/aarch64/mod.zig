pub const boot = @import("boot.zig");
pub const paging = @import("paging.zig");
const uart = @import("../../hal/aarch64/uart.zig");
const gic = @import("../../hal/aarch64/gic.zig");
const arm_timer = @import("../../hal/aarch64/timer.zig");

pub const name: []const u8 = "aarch64";
pub const PAGE_SIZE: usize = 4096;

extern fn kernel_main(magic: u32, info_addr: usize) callconv(.c) noreturn;

pub export fn _start() callconv(.c) noreturn {
    kernel_main(0, 0);
}

pub fn consoleWrite(s: []const u8) void {
    uart.write(s);
}

pub fn consoleClear() void {}

pub fn initSerial() void {
    uart.init();
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
    asm volatile ("hvc #0"
        :
        : [fid] "{x0}" (@as(u64, 0x84000008)),
    );
    halt();
}

pub fn reset() noreturn {
    asm volatile ("hvc #0"
        :
        : [fid] "{x0}" (@as(u64, 0x84000009)),
    );
    halt();
}

pub fn sendEoi(irq: u8) void {
    gic.endOfInterrupt(@as(u32, irq));
}

pub fn initTimer() void {
    arm_timer.init();
    gic.enableIrq(30);
}

pub fn initPic() void {
    gic.init();
}

pub fn unmaskIrq(irq: u8) void {
    gic.enableIrq(@as(u32, irq));
}

pub fn enableInterrupts() void {
    asm volatile ("msr daifclr, #0xF");
}

pub fn disableInterrupts() void {
    asm volatile ("msr daifset, #0xF");
}
