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
