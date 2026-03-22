//! 16550 UART driver for MIPS64EL
//! QEMU Malta board: UART at 0x1FD003F8 (KSEG1 uncached: 0xBFD003F8)

const UART_BASE: usize = 0xFFFF_FFFF_BFD0_03F8;

fn reg(offset: usize) *volatile u8 {
    return @ptrFromInt(UART_BASE + offset);
}

const THR = 0x00;
const RBR = 0x00;
const IER = 0x01;
const FCR = 0x02;
const LCR = 0x03;
const MCR = 0x04;
const LSR = 0x05;
const DLL = 0x00;
const DLM = 0x01;

const LSR_THRE: u8 = 0x20;
const LSR_DR: u8 = 0x01;

pub fn init() void {
    reg(IER).* = 0x00;
    reg(LCR).* = 0x80;
    reg(DLL).* = 0x03;
    reg(DLM).* = 0x00;
    reg(LCR).* = 0x03;
    reg(FCR).* = 0xC7;
    reg(MCR).* = 0x0B;
}

fn writeByte(b: u8) void {
    while (reg(LSR).* & LSR_THRE == 0) {}
    reg(THR).* = b;
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

pub fn hasData() bool {
    return (reg(LSR).* & LSR_DR) != 0;
}

pub fn readByte() ?u8 {
    if (!hasData()) return null;
    return reg(RBR).*;
}
