const builtin = @import("builtin");
const arch = @import("arch.zig");
const klog = @import("rtl/klog.zig");
const std = @import("std");

pub const panic = std.debug.FullPanic(panicImpl);

fn writeHexU32ToConsole(n: u32) void {
    var buf: [8]u8 = undefined;
    var x = n;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        const d: u4 = @truncate(x & 15);
        const du = @as(u8, d);
        buf[i] = if (d < 10) '0' + du else 'a' + (du - 10);
        x >>= 4;
    }
    arch.consoleWrite(buf[0..]);
}

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    arch.consoleWrite("KERNEL PANIC: ");
    arch.consoleWrite(msg);
    const phase = @import("rtl/panic_context.zig").getPhase();
    if (phase != 0) {
        arch.consoleWrite(" [phase=0x");
        writeHexU32ToConsole(phase);
        arch.consoleWrite("]");
    }
    // 与配置里 `build_type=debug` 无关；避免 Release 内核 panic 时不带 phase。
    arch.consoleWrite(" [zig_opt=");
    arch.consoleWrite(@tagName(builtin.mode));
    arch.consoleWrite("]");
    arch.consoleWrite("\n");
    arch.halt();
}

extern const stack_top: u8;
extern const _kernel_end: u8;

comptime {
    _ = @import("kernel/force_link.zig");
}

/// UEFI/汇编以 64 位寄存器传参；首参截断为 u32 供 Multiboot2 magic 比对（与 LoongArch handoff 习惯一致）。
pub export fn kernel_main(magic_arg: usize, info_addr: usize) callconv(.c) noreturn {
    const magic = @as(u32, @truncate(magic_arg));
    switch (builtin.target.cpu.arch) {
        .x86_64 => @import("kernel/boot_x86_64.zig").start(magic, info_addr),
        else => @import("kernel/boot_generic.zig").start(magic, info_addr),
    }
}
