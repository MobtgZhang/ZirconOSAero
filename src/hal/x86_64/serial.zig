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

//! COM1 Serial Port Driver (0x3F8)
//! Provides debug output and input for both BIOS and UEFI boot modes

const portio = @import("portio.zig");

const COM1: u16 = 0x3F8;

var initialized: bool = false;

pub fn init() void {
    portio.outb(COM1 + 1, 0x00);
    portio.outb(COM1 + 3, 0x80);
    portio.outb(COM1 + 0, 0x03);
    portio.outb(COM1 + 1, 0x00);
    portio.outb(COM1 + 3, 0x03);
    portio.outb(COM1 + 2, 0xC7);
    portio.outb(COM1 + 4, 0x0B);

    portio.outb(COM1 + 4, 0x1E);
    portio.outb(COM1 + 0, 0xAE);

    if (portio.inb(COM1 + 0) != 0xAE) {
        return;
    }

    portio.outb(COM1 + 4, 0x0F);
    initialized = true;
}

pub fn isReady() bool {
    return initialized;
}

fn isTransmitEmpty() bool {
    return (portio.inb(COM1 + 5) & 0x20) != 0;
}

pub fn hasData() bool {
    if (!initialized) return false;
    return (portio.inb(COM1 + 5) & 0x01) != 0;
}

pub fn readByte() ?u8 {
    if (!initialized) return null;
    if (!hasData()) return null;
    return portio.inb(COM1);
}

pub fn writeByte(b: u8) void {
    if (!initialized) return;
    var timeout: u32 = 100000;
    while (!isTransmitEmpty() and timeout > 0) : (timeout -= 1) {}
    portio.outb(COM1, b);
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

/// 等待 THR/移位寄存器空（LSR bit6 TEMT），便于 Phase3 等关键路径在 `klog` 后立刻观测串口。
pub fn flushTx() void {
    if (!initialized) return;
    var timeout: u32 = 1_000_000;
    while ((portio.inb(COM1 + 5) & 0x40) == 0 and timeout > 0) : (timeout -= 1) {}
}
