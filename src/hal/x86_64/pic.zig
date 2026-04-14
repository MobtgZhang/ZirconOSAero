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

//! 8259 PIC (Programmable Interrupt Controller)
//! IRQ 0–7 → 向量 **0x30–0x37**，IRQ 8–15 → **0x38–0x3F**（见 `init` 中 ICW2），与 `interrupt_x86` / `lapic_timer_tick` 一致。

const portio = @import("portio.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const ICW1_INIT: u8 = 0x10;
const ICW1_ICW4: u8 = 0x01;
const ICW4_8086: u8 = 0x01;

const EOI: u8 = 0x20;

pub fn init() void {
    portio.outb(PIC1_CMD, ICW1_INIT | ICW1_ICW4);
    portio.outb(PIC2_CMD, ICW1_INIT | ICW1_ICW4);

    // 主片向量基 0x30、从片 0x38（与 Windows 常见布局一致），释放 0x20–0x2F 供 **int 0x2E**（向量 0x2E）等软件中断专用，避免与 IRQ14 冲突。
    portio.outb(PIC1_DATA, 0x30);
    portio.outb(PIC2_DATA, 0x38);

    portio.outb(PIC1_DATA, 0x04);
    portio.outb(PIC2_DATA, 0x02);

    portio.outb(PIC1_DATA, ICW4_8086);
    portio.outb(PIC2_DATA, ICW4_8086);

    portio.outb(PIC1_DATA, 0xFF);
    portio.outb(PIC2_DATA, 0xFF);
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        portio.outb(PIC2_CMD, EOI);
    }
    portio.outb(PIC1_CMD, EOI);
}

pub fn unmaskIrq(irq: u8) void {
    if (irq < 8) {
        const mask = portio.inb(PIC1_DATA);
        portio.outb(PIC1_DATA, mask & ~(@as(u8, 1) << @as(u3, @intCast(irq))));
    } else {
        // IRQ 8–15 经从片接入；主片 IRQ2 为级联线，必须解开从片 IRQ 才能到达 CPU。
        const mask1 = portio.inb(PIC1_DATA);
        portio.outb(PIC1_DATA, mask1 & ~(@as(u8, 1) << @as(u3, @intCast(2))));
        const mask2 = portio.inb(PIC2_DATA);
        portio.outb(PIC2_DATA, mask2 & ~(@as(u8, 1) << @as(u3, @intCast(irq - 8))));
    }
}

pub fn maskIrq(irq: u8) void {
    if (irq < 8) {
        const mask = portio.inb(PIC1_DATA);
        portio.outb(PIC1_DATA, mask | (@as(u8, 1) << @as(u3, @intCast(irq))));
    } else {
        const mask = portio.inb(PIC2_DATA);
        portio.outb(PIC2_DATA, mask | (@as(u8, 1) << @as(u3, @intCast(irq - 8))));
    }
}
