pub const boot = @import("boot.zig");
pub const paging = @import("paging.zig");
pub const framebuffer = @import("../../hal/loongarch64/framebuffer.zig");
const uart = @import("../../hal/loongarch64/uart.zig");

pub const name: []const u8 = "loongarch64";
pub const PAGE_SIZE: usize = 16384;

// 入口 _start 在 crt0.S：设置 $sp 后调用 kernel_main（见 docs/cn/Boot.md）
extern fn kernel_main(magic: u32, info_addr: usize) callconv(.c) noreturn;

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

pub fn serialReadByte() ?u8 {
    return uart.readByte();
}

/// 约等于 ms 毫秒的忙等待（用于启动菜单倒计时，无定时器时）
pub fn stallApproxMs(ms: u32) void {
    var i: u64 = 0;
    const loops = @as(u64, ms) * 50000;
    while (i < loops) : (i += 1) {
        asm volatile ("" ::: .{ .memory = true });
    }
}

pub fn halt() noreturn {
    while (true) {
        asm volatile ("idle 0");
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
    const freq: u64 = 100_000_000;
    const interval = freq / 100;
    asm volatile ("csrwr %[val], 0x41"
        :
        : [val] "r" (interval | 0x3)
    );
}

pub fn initPic() void {}

pub fn unmaskIrq(_: u8) void {}

pub fn enableInterrupts() void {
    var crmd: u64 = asm ("csrrd %[result], 0x0"
        : [result] "=r" (-> u64)
    );
    crmd |= 0x4;
    asm volatile ("csrwr %[val], 0x0"
        :
        : [val] "r" (crmd)
    );
}

pub fn initFramebuffer(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    framebuffer.init(addr, width, height, pitch, bpp);
}

pub fn disableInterrupts() void {
    var crmd: u64 = asm ("csrrd %[result], 0x0"
        : [result] "=r" (-> u64)
    );
    crmd &= ~@as(u64, 0x4);
    asm volatile ("csrwr %[val], 0x0"
        :
        : [val] "r" (crmd)
    );
}
