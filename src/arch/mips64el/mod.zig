pub const boot = @import("boot.zig");
pub const paging = @import("paging.zig");
pub const framebuffer = @import("../../hal/mips64el/framebuffer.zig");
pub const thread_switch = @import("thread_switch.zig");
const traps = @import("traps.zig");
const uart = @import("../../hal/mips64el/uart.zig");

pub const name: []const u8 = "mips64el";
pub const PAGE_SIZE: usize = 4096;

pub fn initFramebuffer(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    framebuffer.init(@intCast(addr), width, height, pitch, bpp);
}

extern fn kernel_main(magic_arg: usize, info_addr: usize) callconv(.c) noreturn;

extern const _kernel_end: u8;

pub fn linkerKernelEndExclusive() usize {
    return @intFromPtr(&_kernel_end);
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

pub fn readInputChar() ?u8 {
    return uart.readByte();
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

/// CP0 Count/Compare timer: ~100Hz tick at assumed 100MHz count rate.
pub fn initTimer() void {
    const freq: u32 = 100_000_000;
    const interval: u32 = freq / 100;
    var count: u32 = asm ("mfc0 %[result], $9"
        : [result] "=r" (-> u32),
    );
    count +%= interval;
    asm volatile ("mtc0 %[val], $11"
        :
        : [val] "r" (count),
    );
}

/// Acknowledge timer interrupt by writing next Compare value.
pub fn ackTimerInterrupt() void {
    const freq: u32 = 100_000_000;
    const interval: u32 = freq / 100;
    var count: u32 = asm ("mfc0 %[result], $9"
        : [result] "=r" (-> u32),
    );
    count +%= interval;
    asm volatile ("mtc0 %[val], $11"
        :
        : [val] "r" (count),
    );
}

/// Enable CP0 Status interrupt mask bits and IE.
pub fn initPic() void {
    traps.init();
    var status: u32 = asm ("mfc0 %[result], $12"
        : [result] "=r" (-> u32),
    );
    // Enable IM7 (timer) + IM0-1 (software) + IE
    status |= (1 << 15) | (1 << 8) | (1 << 9) | 0x1;
    // Set Cause.IV = 1 for separate interrupt vector
    var cause: u32 = asm ("mfc0 %[result], $13"
        : [result] "=r" (-> u32),
    );
    cause |= (1 << 23);
    asm volatile ("mtc0 %[val], $13"
        :
        : [val] "r" (cause),
    );
    asm volatile ("mtc0 %[val], $12"
        :
        : [val] "r" (status),
    );
    asm volatile ("ehb");
}

pub fn unmaskIrq(irq: u8) void {
    if (irq >= 8) return;
    var status: u32 = asm ("mfc0 %[result], $12"
        : [result] "=r" (-> u32),
    );
    status |= @as(u32, 1) << (@as(u5, @intCast(irq)) + 8);
    asm volatile ("mtc0 %[val], $12"
        :
        : [val] "r" (status),
    );
    asm volatile ("ehb");
}

pub fn enableInterrupts() void {
    var status: u32 = asm ("mfc0 %[result], $12"
        : [result] "=r" (-> u32),
    );
    status |= 0x1;
    asm volatile ("mtc0 %[val], $12"
        :
        : [val] "r" (status),
    );
    asm volatile ("ehb");
}

pub fn disableInterrupts() void {
    var status: u32 = asm ("mfc0 %[result], $12"
        : [result] "=r" (-> u32),
    );
    status &= ~@as(u32, 0x1);
    asm volatile ("mtc0 %[val], $12"
        :
        : [val] "r" (status),
    );
    asm volatile ("ehb");
}

pub fn saveAndDisableInterrupts() bool {
    const status: u32 = asm ("mfc0 %[result], $12"
        : [result] "=r" (-> u32),
    );
    disableInterrupts();
    return (status & 0x1) != 0;
}

pub fn restoreInterrupts(were_enabled: bool) void {
    if (were_enabled) enableInterrupts();
}

pub fn waitForInterrupt() void {
    enableInterrupts();
    asm volatile ("wait");
}
