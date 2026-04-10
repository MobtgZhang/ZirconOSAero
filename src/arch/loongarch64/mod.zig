pub const boot = @import("boot.zig");
pub const paging = @import("paging.zig");
pub const thread_switch = @import("thread_switch.zig");
pub const framebuffer = @import("../../hal/loongarch64/framebuffer.zig");
const uart = @import("../../hal/loongarch64/uart.zig");
const traps = @import("traps.zig");
const liointc = @import("../../hal/loongarch64/liointc.zig");

pub const name: []const u8 = "loongarch64";
pub const PAGE_SIZE: usize = 16384;

extern fn kernel_main(magic_arg: usize, info_addr: usize) callconv(.c) noreturn;

/// `link/loongarch64.ld` 中 `PROVIDE(_kernel_end = .)` 为 **零尺寸** 符号；在部分 Zig 版本上
/// `@intFromPtr(&extern const _kernel_end: u8)` 会得到 0，帧分配器不保留内核映像，identity map 约在 8MiB 处失败。
/// 使用 `la.local` 与 `crt0.S` 中 `stack_top` 一致，由链接器填入正确 PC 相对地址。
pub fn linkerKernelEndExclusive() usize {
    return asm volatile ("la.local %[out], _kernel_end"
        : [out] "=r" (-> usize),
    );
}

/// CSR.TCFG：EN|PERIOD|VAL<<2（见 Linux `LOONGARCH_CSR_TCFG`）
const CSR_TCFG: comptime_int = 0x41;
const CSR_TINTCLR: comptime_int = 0x44;
const TCFG_EN: u64 = 1;
const TCFG_PERIOD: u64 = 2;
/// QEMU virt 约 1GHz 量级；与调度 100Hz 对齐
const TIMER_CPU_HZ: u64 = 1_000_000_000;
const TIMER_TICK_HZ: u64 = 100;

/// CSR.ECFG IM 域：INT_HWI0..7 = 2..9 → 位掩码 0x3FC
const IM_HWI: u64 = 0x3FC;

pub fn consoleWrite(s: []const u8) void {
    uart.write(s);
}

pub fn consoleClear() void {}

pub fn initSerial() void {
    uart.init();
}

pub fn serialWrite(s: []const u8) void {
    uart.write(s);
}

pub fn serialReadByte() ?u8 {
    return uart.readByte();
}

pub fn stallApproxMs(ms: u32) void {
    var i: u64 = 0;
    const loops = @as(u64, ms) * 50000;
    while (i < loops) : (i += 1) {
        asm volatile ("" ::: .{ .memory = true });
    }
}

pub fn halt() noreturn {
    while (true) {
        asm volatile ("idle 0");
    }
}

pub fn standby() noreturn {
    halt();
}

pub fn shutdown() noreturn {
    halt();
}

pub fn reset() noreturn {
    halt();
}

pub fn sendEoi(_: u8) void {}

pub fn initTimer() void {
    asm volatile ("csrwr %[v], %[c]"
        :
        : [v] "r" (@as(u64, 1)),
          [c] "i" (CSR_TINTCLR),
    );
    const ticks = TIMER_CPU_HZ / TIMER_TICK_HZ;
    const tcfg = TCFG_EN | TCFG_PERIOD | (ticks << 2);
    asm volatile ("csrwr %[v], %[c]"
        :
        : [v] "r" (tcfg),
          [c] "i" (CSR_TCFG),
    );
}

pub fn initPic() void {
    liointc.init();
    traps.ecfgEnableInterruptMask(IM_HWI);

    // 配置 DMW（Direct Map Window）用于 MMIO 访问
    // PCIe ECAM 通常在 0xE000_0000 以上，配置 2GiB DMW 窗口
    const ecam_phys: u64 = 0xE000_0000;
    const ecam_size: u2 = 2; // 2GiB 窗口
    const dmw_mat = paging.DMW_MAT_WUC; // 弱非缓存，适合 MMIO
    _ = paging.setupMmioDirectWindow(ecam_phys, ecam_size, dmw_mat);
}

pub fn unmaskIrq(irq: u8) void {
    _ = irq;
    traps.ecfgEnableInterruptMask(@as(u64, 1) << 11); // INT_TI
}

pub fn enableInterrupts() void {
    var crmd: u64 = asm ("csrrd %[result], 0x0"
        : [result] "=r" (-> u64),
    );
    crmd |= 0x4;
    asm volatile ("csrwr %[val], 0x0"
        :
        : [val] "r" (crmd),
    );
}

pub fn initFramebuffer(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    framebuffer.init(addr, width, height, pitch, bpp);
}

pub fn disableInterrupts() void {
    var crmd: u64 = asm ("csrrd %[result], 0x0"
        : [result] "=r" (-> u64),
    );
    crmd &= ~@as(u64, 0x4);
    asm volatile ("csrwr %[val], 0x0"
        :
        : [val] "r" (crmd),
    );
}

/// CRMD.IE（bit 2）为 1 时中断允许。\n/// Ref: LoongArch ABI / CSR CRMD。
pub fn saveAndDisableInterrupts() bool {
    const crmd: u64 = asm ("csrrd %[result], 0x0"
        : [result] "=r" (-> u64),
    );
    disableInterrupts();
    return (crmd & 0x4) != 0;
}

pub fn restoreInterrupts(were_enabled: bool) void {
    if (were_enabled) enableInterrupts();
}

pub fn readInputChar() ?u8 {
    const ev = @import("../../drivers/input/evdev_virtio_bridge.zig");
    if (ev.hasData()) return ev.readChar();
    return uart.readByte();
}

pub fn injectSyntheticChar(c: u8) void {
    @import("../../drivers/input/evdev_virtio_bridge.zig").injectSyntheticChar(c);
}

pub fn consumeTaskMgrHotkey() bool {
    return @import("../../drivers/input/evdev_virtio_bridge.zig").consumeTaskMgrHotkey();
}

pub fn consumeWallpaperCycleHotkey() bool {
    return @import("../../drivers/input/evdev_virtio_bridge.zig").consumeWallpaperCycleHotkey();
}
