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
