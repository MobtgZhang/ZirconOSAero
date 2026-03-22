//! PL011 UART driver for AArch64 (QEMU virt machine)

const UART0_BASE: usize = 0x0900_0000;

fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(UART0_BASE + offset);
}

const DR_OFFSET = 0x00;
const FR_OFFSET = 0x18;
const FR_TXFF: u32 = 1 << 5;

pub fn init() void {}

fn writeByte(b: u8) void {
    while (reg(FR_OFFSET).* & FR_TXFF != 0) {}
    reg(DR_OFFSET).* = b;
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}
