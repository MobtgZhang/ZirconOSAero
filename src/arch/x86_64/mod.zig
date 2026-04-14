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

pub const boot = @import("boot.zig");
pub const fb = @import("../../drivers/video/core/framebuffer.zig");
pub const paging = @import("paging.zig");
const pic = @import("../../hal/x86_64/pic.zig");
const pit = @import("../../hal/x86_64/pit.zig");
pub const gdt = @import("../../hal/x86_64/gdt.zig");
pub const lapic_tick = @import("../../hal/x86_64/lapic_timer_tick.zig");

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

pub const initSyscallInstructionPath = @import("syscall_msr.zig").initSyscallInstructionPath;

const debug_mode = @import("build_options").debug;

pub fn consoleWrite(s: []const u8) void {
    const framebuffer = @import("../../hal/x86_64/framebuffer.zig");
    const vga = @import("../../hal/x86_64/vga.zig");
    const serial = @import("../../hal/x86_64/serial.zig");
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
    const framebuffer = @import("../../hal/x86_64/framebuffer.zig");
    const vga = @import("../../hal/x86_64/vga.zig");
    if (framebuffer.isReady()) {
        framebuffer.clear();
    } else {
        vga.clear();
    }
}

pub fn initFramebuffer(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    const framebuffer = @import("../../hal/x86_64/framebuffer.zig");
    framebuffer.init(addr, width, height, pitch, bpp);
}

pub fn serialWrite(s: []const u8) void {
    const serial = @import("../../hal/x86_64/serial.zig");
    serial.write(s);
}

pub fn serialReadByte() ?u8 {
    const serial = @import("../../hal/x86_64/serial.zig");
    return serial.readByte();
}

/// 串口 FIFO 排空（见 `serial.flushTx`）；供 PFN 早期清零等路径在日志后强制落盘。
pub fn flushDebugSerialOutput() void {
    const serial = @import("../../hal/x86_64/serial.zig");
    serial.flushTx();
}

pub fn initSerial() void {
    const serial = @import("../../hal/x86_64/serial.zig");
    serial.init();
}

pub fn initGdt(kernel_stack: u64) void {
    gdt.init(kernel_stack);
}

pub fn initKeyboard() void {
    pic.unmaskIrq(1);
}

/// PS/2 鼠标经 **IRQ12**（8042/i8042prt 类路径）投递。QEMU 若同时启用 **virtio-input** 鼠标，默认 **只消费 VirtIO**，
/// 避免双源指针打架：`handleMouseIrq` 在 `virtio_input_pci.isActive()` 且 **未** 设置 `-Dps2_mouse_with_virtio=true` 时直接 return。
/// **无 VirtIO 的真机或旧机器**：不要挂 virtio-input；或显式 `zig build … -Dps2_mouse_with_virtio=true` 在双源并存下仍处理 IRQ12。
/// 观测：`-Dmouse_debug=true` 串口对比 IRQ 路径与 [MVT_NT61.md](../../docs/cn/MVT_NT61.md) / [PointerPolicy_NT61.md](../../docs/cn/PointerPolicy_NT61.md) §4.1。
pub fn initMouse() void {
    pic.unmaskIrq(12);
}

pub fn readInputChar() ?u8 {
    const kbd = @import("../../drivers/input/kbd.zig");
    const serial = @import("../../hal/x86_64/serial.zig");
    if (kbd.hasData()) {
        return kbd.readChar();
    }
    if (serial.hasData()) {
        return serial.readByte();
    }
    return null;
}

pub fn injectSyntheticChar(c: u8) void {
    const kbd = @import("../../drivers/input/kbd.zig");
    kbd.injectSyntheticChar(c);
}

pub fn consumeTaskMgrHotkey() bool {
    const keyboard = @import("../../drivers/input/kbd.zig");
    return keyboard.consumeTaskMgrHotkey();
}

pub fn consumeWallpaperCycleHotkey() bool {
    const keyboard = @import("../../drivers/input/kbd.zig");
    return keyboard.consumeWallpaperCycleHotkey();
}

pub fn consumeFlip3dHotkey() bool {
    const keyboard = @import("../../drivers/input/kbd.zig");
    return keyboard.consumeFlip3dHotkey();
}

pub fn consumeFlip3dDismiss() bool {
    const keyboard = @import("../../drivers/input/kbd.zig");
    return keyboard.consumeFlip3dDismiss();
}

pub fn takeCursorNudge() @import("../../drivers/input/cursor_types.zig").CursorNudge {
    const keyboard = @import("../../drivers/input/kbd.zig");
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
    lapic_tick.initDeferredSingleTickSource();
    // HPET 探测在 `main.zig` 绑定内核页表并 `mapDeviceMmioIdentity` 之后调用（0xFED00000 常超出早期 identity 窗口）。
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

/// 读取 RFLAGS.IF 后 `cli`；返回进入前 IF 是否为 1（中断本已允许）。
/// Ref: Intel SDM — RFLAGS 与 `cli`/`sti`。
pub fn saveAndDisableInterrupts() bool {
    const rflags = asm volatile ("pushfq\n\tpop %[r]"
        : [r] "=r" (-> u64),
    );
    asm volatile ("cli" ::: .{ .memory = true });
    return (rflags & (1 << 9)) != 0;
}

/// 与 `saveAndDisableInterrupts` 配对；仅当先前 IF=1 时 `sti`（ISR 内持锁结束不得误开中断）。
pub fn restoreInterrupts(were_enabled: bool) void {
    if (were_enabled) {
        asm volatile ("sti" ::: .{ .memory = true });
    }
}
