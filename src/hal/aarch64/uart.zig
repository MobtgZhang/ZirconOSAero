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

//! PL011 UART driver for AArch64 (QEMU virt machine)

const UART0_BASE: usize = 0x0900_0000;

fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(UART0_BASE + offset);
}

const DR_OFFSET = 0x00;
const FR_OFFSET = 0x18;
const FR_TXFF: u32 = 1 << 5;
const FR_RXFE: u32 = 1 << 4;

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

pub fn readByte() ?u8 {
    if (reg(FR_OFFSET).* & FR_RXFE != 0) return null;
    return @truncate(reg(DR_OFFSET).*);
}
