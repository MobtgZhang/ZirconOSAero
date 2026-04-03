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

/// 保存「中断是否曾允许」后关中断；与 `restoreInterrupts` 配对供 `IrqSpinLock` 使用（ISR 内不得误 `sti`）。
pub fn saveAndDisableInterrupts() bool {
    return impl.saveAndDisableInterrupts();
}

/// 仅当 `saveAndDisableInterrupts` 返回 `true` 时重新开中断。
pub fn restoreInterrupts(were_enabled: bool) void {
    impl.restoreInterrupts(were_enabled);
}

/// 自旋等待时的 CPU 退让提示（x86 `pause`、AArch64 `yield`、LoongArch `dbar 0` 等）。
/// 通用内核路径禁止直接使用 x86 助记符，否则 LoongArch/RISC-V 等交叉编译会失败。
pub fn spinCpuRelax() void {
    switch (builtin.target.cpu.arch) {
        .x86_64 => asm volatile ("pause" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("yield" ::: .{ .memory = true }),
        .loongarch64 => asm volatile ("dbar 0" ::: .{ .memory = true }),
        // LLVM 目标未必启用 Zihintpause；空指令 + memory 栅栏足够作退让占位。
        .riscv64 => asm volatile ("" ::: .{ .memory = true }),
        .mips64el => asm volatile ("" ::: .{ .memory = true }),
        else => @compileError("spinCpuRelax: unsupported architecture"),
    }
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

/// 调试串口 flush（x86_64 COM1 等）；无实现的目标为空操作。
pub fn flushDebugSerialOutput() void {
    if (@hasDecl(impl, "flushDebugSerialOutput")) {
        impl.flushDebugSerialOutput();
    }
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

/// 向 PS/2 或 VirtIO 输入环注入一字节（屏幕键盘、测试；与 `readInputChar` 同源队列）。
pub fn injectSyntheticChar(c: u8) void {
    if (@hasDecl(impl, "injectSyntheticChar")) {
        impl.injectSyntheticChar(c);
    }
}

pub fn consumeTaskMgrHotkey() bool {
    if (@hasDecl(impl, "consumeTaskMgrHotkey")) {
        return impl.consumeTaskMgrHotkey();
    }
    return false;
}

pub fn consumeWallpaperCycleHotkey() bool {
    if (@hasDecl(impl, "consumeWallpaperCycleHotkey")) {
        return impl.consumeWallpaperCycleHotkey();
    }
    return false;
}

pub fn consumeFlip3dHotkey() bool {
    if (@hasDecl(impl, "consumeFlip3dHotkey")) {
        return impl.consumeFlip3dHotkey();
    }
    return false;
}

pub fn consumeFlip3dDismiss() bool {
    if (@hasDecl(impl, "consumeFlip3dDismiss")) {
        return impl.consumeFlip3dDismiss();
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
        // LoongArch：`traps.init` + `enableInterrupts` 后由定时器中断唤醒 idle。
        .loongarch64 => {
            const crmd: u64 = asm volatile ("csrrd %[r], 0x0"
                : [r] "=r" (-> u64),
            );
            if ((crmd & 4) != 0) {
                asm volatile ("idle 0");
            } else {
                var i: u32 = 0;
                while (i < 65536) : (i += 1) {
                    asm volatile ("" ::: .{ .memory = true });
                }
            }
        },
        // AArch64 / RISC-V 等：无完整 trap 或未开中断时避免 WFI 卡死主循环轮询。
        else => {
            var i: u32 = 0;
            while (i < 65536) : (i += 1) {
                asm volatile ("" ::: .{ .memory = true });
            }
        },
    }
}

/// 桌面主循环空闲：
/// - **LoongArch64**：始终短自旋。QEMU/UEFI 下 VirtIO 等设备 IRQ 经 PCH/LIOINTC 唤醒 `idle 0` 不可靠时，会退化为仅定时器 ~100Hz 唤醒，表现为鼠标「动一下卡一下」。
/// - **x86_64**：`-Ddesktop_idle_spin=true`（默认）时用短自旋代替 `sti;hlt`，便于 VirtIO/8042 轮询。
pub fn waitForInterruptDesktop() void {
    const b = @import("builtin");
    if (b.target.cpu.arch == .loongarch64) {
        var i: u32 = 0;
        while (i < 65536) : (i += 1) {
            asm volatile ("" ::: .{ .memory = true });
        }
        return;
    }
    if (@import("build_options").desktop_idle_spin and b.target.cpu.arch == .x86_64) {
        var i: u32 = 0;
        while (i < 65536) : (i += 1) {
            asm volatile ("" ::: .{ .memory = true });
        }
        return;
    }
    waitForInterrupt();
}
