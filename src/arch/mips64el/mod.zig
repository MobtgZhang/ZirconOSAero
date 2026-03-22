pub const boot = @import("boot.zig");
pub const paging = @import("paging.zig");
const uart = @import("../../hal/mips64el/uart.zig");

pub const name: []const u8 = "mips64el";
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
        asm volatile ("wait");
    }
}

pub fn standby() noreturn {
    halt();
}

pub fn shutdown() noreturn {
    halt();
}

pub fn reset() noreturn {
    halt();
}

pub fn sendEoi(_: u8) void {}

pub fn initTimer() void {
    const freq: u32 = 100_000_000;
    const interval: u32 = freq / 100;
    var count: u32 = asm ("mfc0 %[result], $9"
        : [result] "=r" (-> u32)
    );
    count +%= interval;
    asm volatile ("mtc0 %[val], $11"
        :
        : [val] "r" (count)
    );
}

pub fn initPic() void {
    var status: u32 = asm ("mfc0 %[result], $12"
        : [result] "=r" (-> u32)
    );
    status |= 0x8001;
    asm volatile ("mtc0 %[val], $12"
        :
        : [val] "r" (status)
    );
}

pub fn unmaskIrq(_: u8) void {}

pub fn enableInterrupts() void {
    var status: u32 = asm ("mfc0 %[result], $12"
        : [result] "=r" (-> u32)
    );
    status |= 0x1;
    asm volatile ("mtc0 %[val], $12"
        :
        : [val] "r" (status)
    );
}

pub fn disableInterrupts() void {
    var status: u32 = asm ("mfc0 %[result], $12"
        : [result] "=r" (-> u32)
    );
    status &= ~@as(u32, 0x1);
    asm volatile ("mtc0 %[val], $12"
        :
        : [val] "r" (status)
    );
}
