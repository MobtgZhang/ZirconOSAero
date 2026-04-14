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

pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %%al, %%dx"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    var value: u8 = 0;
    asm volatile ("inb %%dx, %%al"
        : [value] "={al}" (value),
        : [port] "{dx}" (port),
    );
    return value;
}

pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %%ax, %%dx"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    var value: u16 = 0;
    asm volatile ("inw %%dx, %%ax"
        : [value] "={ax}" (value),
        : [port] "{dx}" (port),
    );
    return value;
}

pub inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %%eax, %%dx"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn inl(port: u16) u32 {
    var value: u32 = 0;
    asm volatile ("inl %%dx, %%eax"
        : [value] "={eax}" (value),
        : [port] "{dx}" (port),
    );
    return value;
}

pub inline fn ioWait() void {
    outb(0x80, 0);
}
