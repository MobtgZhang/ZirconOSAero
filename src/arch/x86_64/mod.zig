pub const boot = @import("boot.zig");
pub const paging = @import("paging.zig");
const vga = @import("../../hal/x86_64/vga.zig");
pub const framebuffer = @import("../../hal/x86_64/framebuffer.zig");
const pic = @import("../../hal/x86_64/pic.zig");
const pit = @import("../../hal/x86_64/pit.zig");
pub const serial = @import("../../hal/x86_64/serial.zig");
pub const gdt = @import("../../hal/x86_64/gdt.zig");
pub const keyboard = @import("../../hal/x86_64/keyboard.zig");

pub const name: []const u8 = "x86_64";
pub const PAGE_SIZE: usize = 4096;

comptime {
    if (@import("build_options").enable_idt) {
        _ = @import("isr.zig");
        _ = @import("syscall.zig");
    }
}

const debug_mode = @import("build_options").debug;

pub fn consoleWrite(s: []const u8) void {
    if (debug_mode) {
        if (framebuffer.isReady()) {
            framebuffer.write(s);
        } else {
            vga.write(s);
        }
    }
    if (serial.isReady()) {
        serial.write(s);
    }
}

pub fn consoleClear() void {
    if (framebuffer.isReady()) {
        framebuffer.clear();
    } else {
        vga.clear();
    }
}

pub fn initFramebuffer(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    framebuffer.init(addr, width, height, pitch, bpp);
}

pub fn serialWrite(s: []const u8) void {
    serial.write(s);
}

pub fn initSerial() void {
    serial.init();
}

pub fn initGdt(kernel_stack: u64) void {
    gdt.init(kernel_stack);
}

pub fn initKeyboard() void {
    keyboard.init();
    pic.unmaskIrq(1);
}

pub fn initMouse() void {
    const mouse = @import("../../drivers/input/mouse.zig");
    mouse.init();
    pic.unmaskIrq(12);
}

pub fn handleKeyboardIrq() void {
    keyboard.handleIrq();
}

pub fn handleMouseIrq() void {
    const mouse = @import("../../drivers/input/mouse.zig");
    mouse.handleIrq();
}

pub fn readInputChar() ?u8 {
    if (keyboard.hasData()) {
        return keyboard.readChar();
    }
    if (serial.hasData()) {
        return serial.readByte();
    }
    return null;
}

pub fn consumeTaskMgrHotkey() bool {
    return keyboard.consumeTaskMgrHotkey();
}

pub fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn standby() noreturn {
    asm volatile ("sti");
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn shutdown() noreturn {
    asm volatile ("cli");
    // QEMU ACPI shutdown (port 0x604)
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (@as(u16, 0x2000)),
          [port] "{dx}" (@as(u16, 0x604)),
    );
    // Bochs/older QEMU shutdown (port 0xB004)
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (@as(u16, 0x2000)),
          [port] "{dx}" (@as(u16, 0xB004)),
    );
    halt();
}

pub fn reset() noreturn {
    asm volatile ("cli");
    // Pulse reset via 8042 keyboard controller
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (@as(u8, 0xFE)),
          [port] "{dx}" (@as(u16, 0x64)),
    );
    // Fallback: reset via port 0xCF9
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (@as(u8, 0x06)),
          [port] "{dx}" (@as(u16, 0xCF9)),
    );
    halt();
}

pub fn sendEoi(irq: u8) void {
    pic.sendEoi(irq);
}

pub fn initTimer() void {
    pit.init();
}

pub fn initPic() void {
    pic.init();
}

pub fn unmaskIrq(irq: u8) void {
    pic.unmaskIrq(irq);
}

pub fn enableInterrupts() void {
    asm volatile ("sti");
}

pub fn disableInterrupts() void {
    asm volatile ("cli");
}
