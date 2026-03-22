//! 8254 PIT (Programmable Interval Timer)
//! Channel 0 produces periodic interrupts (default ~100Hz, must match ke/timer + scheduler)

const portio = @import("portio.zig");

const PIT_CH0: u16 = 0x40;
const PIT_CMD: u16 = 0x43;

const CMD_CH0: u8 = 0x00;
const CMD_LOHI: u8 = 0x30;
const CMD_SQUARE: u8 = 0x06;

pub const PIT_FREQ: u32 = 1193182;

var programmed_hz: u32 = 100;

/// Programs channel 0 for `hz` Hz square wave. Caller must keep this in sync with
/// `ke/timer` and `scheduler` tick accounting if the rate is changed at runtime.
pub fn setHz(hz: u32) void {
    if (hz == 0) return;
    const divisor: u16 = @intCast(PIT_FREQ / hz);
    portio.outb(PIT_CMD, CMD_CH0 | CMD_LOHI | CMD_SQUARE);
    portio.outb(PIT_CH0, @as(u8, @truncate(divisor)));
    portio.outb(PIT_CH0, @as(u8, @truncate(divisor >> 8)));
    programmed_hz = hz;
}

pub fn getProgrammedHz() u32 {
    return programmed_hz;
}

pub fn init() void {
    setHz(100);
}
