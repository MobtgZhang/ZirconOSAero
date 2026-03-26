//! 中断分发入口：x86_64 走 IDT；其它架构由各自 trap/空实现承担。

const builtin = @import("builtin");

pub const InterruptFrame = switch (builtin.target.cpu.arch) {
    .x86_64 => @import("interrupt_x86.zig").InterruptFrame,
    else => @import("interrupt_stub.zig").InterruptFrame,
};

pub fn handle(frame: *InterruptFrame) void {
    switch (builtin.target.cpu.arch) {
        .x86_64 => @import("interrupt_x86.zig").handle(@ptrCast(frame)),
        else => @import("interrupt_stub.zig").handle(frame),
    }
}
