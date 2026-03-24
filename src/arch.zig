const builtin = @import("builtin");

pub const impl = switch (builtin.target.cpu.arch) {
    .x86_64 => @import("arch/x86_64/mod.zig"),
    .aarch64 => @import("arch/aarch64/mod.zig"),
    .loongarch64 => @import("arch/loongarch64/mod.zig"),
    .riscv64 => @import("arch/riscv64/mod.zig"),
    .mips64el => @import("arch/mips64el/mod.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const PAGE_SIZE: usize = impl.PAGE_SIZE;
pub const PAGE_MASK: usize = PAGE_SIZE - 1;

pub fn consoleWrite(s: []const u8) void {
    impl.consoleWrite(s);
}

pub fn consoleClear() void {
    impl.consoleClear();
}

pub fn halt() noreturn {
    impl.halt();
}

pub fn shutdown() noreturn {
    impl.shutdown();
}

/// 待机：CPU 低功耗空闲（无 ACPI S3 时等价于 halt/wfi；可唤醒路径由后续电源管理接入）。
pub fn standby() noreturn {
    impl.standby();
}

pub fn reset() noreturn {
    impl.reset();
}

pub fn sendEoi(irq: u8) void {
    impl.sendEoi(irq);
}

pub fn initTimer() void {
    impl.initTimer();
}

pub fn initPic() void {
    impl.initPic();
}

pub fn unmaskIrq(irq: u8) void {
    impl.unmaskIrq(irq);
}

pub fn enableInterrupts() void {
    impl.enableInterrupts();
}

pub fn disableInterrupts() void {
    impl.disableInterrupts();
}

pub fn initSerial() void {
    if (@hasDecl(impl, "initSerial")) {
        impl.initSerial();
    }
}

pub fn serialWrite(s: []const u8) void {
    if (@hasDecl(impl, "serialWrite")) {
        impl.serialWrite(s);
    }
}

pub fn serialReadByte() ?u8 {
    if (@hasDecl(impl, "serialReadByte")) {
        return impl.serialReadByte();
    }
    return null;
}

pub fn stallApproxMs(ms: u32) void {
    if (@hasDecl(impl, "stallApproxMs")) {
        impl.stallApproxMs(ms);
    }
}

pub fn initGdt(kernel_stack: u64) void {
    if (@hasDecl(impl, "initGdt")) {
        impl.initGdt(kernel_stack);
    }
}

pub fn initKeyboard() void {
    if (@hasDecl(impl, "initKeyboard")) {
        impl.initKeyboard();
    }
}

pub fn initMouse() void {
    if (@hasDecl(impl, "initMouse")) {
        impl.initMouse();
    }
}

pub fn handleKeyboardIrq() void {
    if (@hasDecl(impl, "handleKeyboardIrq")) {
        impl.handleKeyboardIrq();
    }
}

pub fn handleMouseIrq() void {
    if (@hasDecl(impl, "handleMouseIrq")) {
        impl.handleMouseIrq();
    }
}

pub fn readInputChar() ?u8 {
    if (@hasDecl(impl, "readInputChar")) {
        return impl.readInputChar();
    }
    return null;
}

pub fn consumeTaskMgrHotkey() bool {
    if (@hasDecl(impl, "consumeTaskMgrHotkey")) {
        return impl.consumeTaskMgrHotkey();
    }
    return false;
}

const CursorNudge = @import("drivers/input/cursor_types.zig").CursorNudge;

pub fn takeCursorNudge() CursorNudge {
    if (@hasDecl(impl, "takeCursorNudge")) {
        return impl.takeCursorNudge();
    }
    return CursorNudge{ .dx = 0, .dy = 0 };
}

pub fn initFramebuffer(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    if (@hasDecl(impl, "initFramebuffer")) {
        impl.initFramebuffer(addr, width, height, pitch, bpp);
    }
}

pub fn waitForInterrupt() void {
    switch (@import("builtin").target.cpu.arch) {
        // 若 IF=0 时执行 HLT，除 NMI 外无法被 PIC/Local APIC 唤醒，键鼠与 PIT 均停滞。
        .x86_64 => asm volatile (
            \\sti
            \\hlt
        ),
        .aarch64 => asm volatile ("wfi"),
        .riscv64 => asm volatile ("wfi"),
        .mips64el => asm volatile ("wait"),
        .loongarch64 => asm volatile ("idle 0"),
        else => {},
    }
}
