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
        _ = @import("syscall_msr.zig");
        _ = @import("ssdt_nt61.zig");
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

/// PS/2 鼠标经 **IRQ12**（8042/i8042prt 类路径）投递。QEMU 若同时启用 **virtio-input** 鼠标，默认 **只消费 VirtIO**，
/// 避免双源指针打架：`handleMouseIrq` 在 `virtio_input_pci.isActive()` 且 **未** 设置 `-Dps2_mouse_with_virtio=true` 时直接 return。
/// **无 VirtIO 的真机或旧机器**：不要挂 virtio-input；或显式 `zig build … -Dps2_mouse_with_virtio=true` 在双源并存下仍处理 IRQ12。
/// 观测：`-Dmouse_debug=true` 串口对比 IRQ 路径与 [MVT_NT61.md](../../docs/cn/MVT_NT61.md) / [PointerPolicy_NT61.md](../../docs/cn/PointerPolicy_NT61.md) §4.1。
pub fn initMouse() void {
    const mouse = @import("../../drivers/input/mouse.zig");
    mouse.initHardware();
    pic.unmaskIrq(12);
}

pub fn handleKeyboardIrq() void {
    keyboard.handleIrq();
}

pub fn handleMouseIrq() void {
    const virtio_input_pci = @import("../../drivers/input/virtio_input_pci.zig");
    const bopts = @import("build_options");
    // 策略说明见 `initMouse` 注释；与 [NT61_CONTRACT_MATRIX.md](../../docs/cn/NT61_CONTRACT_MATRIX.md) §4.1「PS/2 与 VirtIO 双源」一致。
    if (virtio_input_pci.isActive() and !bopts.ps2_mouse_with_virtio) return;
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

pub fn injectSyntheticChar(c: u8) void {
    keyboard.injectSyntheticChar(c);
}

pub fn consumeTaskMgrHotkey() bool {
    return keyboard.consumeTaskMgrHotkey();
}

pub fn consumeWallpaperCycleHotkey() bool {
    return keyboard.consumeWallpaperCycleHotkey();
}

pub fn consumeFlip3dHotkey() bool {
    return keyboard.consumeFlip3dHotkey();
}

pub fn takeCursorNudge() @import("../../drivers/input/cursor_types.zig").CursorNudge {
    return keyboard.takeCursorNudge();
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
    const hpet = @import("../../hal/x86_64/hpet.zig");
    _ = hpet.initOptional();
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
