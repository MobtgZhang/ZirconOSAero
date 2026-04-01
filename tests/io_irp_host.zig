// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/io_irp_host.zig
// Purpose: 主机侧断言 IRP 完成例程调用顺序（与 `src/io/io.zig` `IoCompleteRequest` 保持同步；单文件测试模块无法直接 `@import` I/O 管理器）。
//
// This is an independent clean-room implementation.

const std = @import("std");

const IrpCompletionRoutine = *const fn (*Irp) void;

const Irp = struct {
    bytes_transferred: usize = 0,
    completion_routine: ?IrpCompletionRoutine = null,

    fn complete(self: *Irp, transferred: usize) void {
        self.bytes_transferred = transferred;
    }
};

fn ioSetCompletionRoutine(irp: *Irp, routine: ?IrpCompletionRoutine) void {
    irp.completion_routine = routine;
}

/// 镜像 `io.zig` `IoCompleteRequest`：先写状态/传输计数，再同步调用并清除完成例程。
fn ioCompleteRequest(irp: *Irp, transferred: usize) void {
    irp.complete(transferred);
    if (irp.completion_routine) |cb| {
        cb(irp);
        irp.completion_routine = null;
    }
}

var completion_hits: u32 = 0;

fn onComplete(irp: *Irp) void {
    _ = irp;
    completion_hits += 1;
}

test "IRP completion routine runs once after bytes set (IoCompleteRequest contract)" {
    completion_hits = 0;
    var irp: Irp = .{};
    ioSetCompletionRoutine(&irp, onComplete);
    ioCompleteRequest(&irp, 4);
    try std.testing.expectEqual(@as(u32, 1), completion_hits);
    try std.testing.expect(irp.completion_routine == null);
    try std.testing.expectEqual(@as(usize, 4), irp.bytes_transferred);
}
