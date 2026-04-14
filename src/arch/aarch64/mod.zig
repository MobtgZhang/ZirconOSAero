// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

pub const boot = @import("boot.zig");
pub const paging = @import("paging.zig");
pub const thread_switch = @import("thread_switch.zig");
pub const traps = @import("traps.zig");
pub const fb = @import("../../hal/aarch64/framebuffer.zig");
pub const framebuffer = fb;
const uart = @import("../../hal/aarch64/uart.zig");
const gic = @import("../../hal/aarch64/gic.zig");
const arm_timer = @import("../../hal/aarch64/timer.zig");

pub const name: []const u8 = "aarch64";
pub const PAGE_SIZE: usize = 4096;

extern const _kernel_end: u8;

pub fn linkerKernelEndExclusive() usize {
    return @intFromPtr(&_kernel_end);
}

pub fn serialReadByte() ?u8 {
    return uart.readByte();
}

pub fn initFramebuffer(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    framebuffer.init(addr, width, height, pitch, bpp);
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

/// `mrs daif` 后 `daifset`；DAIF.I（bit 7）为 0 表示 IRQ 未屏蔽即此前允许中断。
/// Ref: ARM DDI 0487 — DAIF。
pub fn saveAndDisableInterrupts() bool {
    const daif: u64 = asm volatile ("mrs %[r], daif"
        : [r] "=r" (-> u64),
    );
    asm volatile ("msr daifset, #0xF" ::: .{ .memory = true });
    return (daif & (1 << 7)) == 0;
}

pub fn restoreInterrupts(were_enabled: bool) void {
    if (were_enabled) {
        asm volatile ("msr daifclr, #0xF" ::: .{ .memory = true });
    }
}
