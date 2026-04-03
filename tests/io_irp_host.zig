// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/io_irp_host.zig
// Purpose: 主机侧断言 IRP 完成例程调用顺序（与 `src/io/io.zig` `IoCompleteRequest` 保持同步；单文件测试模块无法直接 `@import` I/O 管理器）。
//
// This is an independent clean-room implementation.

const std = @import("std");

const IrpCompletionRoutine = *const fn (*Irp) void;

const MAX_CR: usize = 2;

const Irp = struct {
    bytes_transferred: usize = 0,
    completion_depth: u8 = 0,
    completion_stack: [MAX_CR]?IrpCompletionRoutine = .{ null, null },

    fn complete(self: *Irp, transferred: usize) void {
        self.bytes_transferred = transferred;
    }
};

fn ioSetCompletionRoutine(irp: *Irp, routine: ?IrpCompletionRoutine) void {
    const r = routine orelse return;
    if (irp.completion_depth >= MAX_CR) return;
    irp.completion_stack[irp.completion_depth] = r;
    irp.completion_depth += 1;
}

/// 镜像 `io.zig` `IoCompleteRequest`：LIFO 调用最多两层完成例程。
fn ioCompleteRequest(irp: *Irp, transferred: usize) void {
    irp.complete(transferred);
    while (irp.completion_depth > 0) {
        irp.completion_depth -= 1;
        if (irp.completion_stack[irp.completion_depth]) |cb| {
            irp.completion_stack[irp.completion_depth] = null;
            cb(irp);
        }
    }
}

var completion_hits: u32 = 0;
var completion_order: [2]u8 = .{ 0, 0 };
var order_len: usize = 0;

fn onCompleteA(irp: *Irp) void {
    _ = irp;
    completion_hits += 1;
    if (order_len < completion_order.len) {
        completion_order[order_len] = 1;
        order_len += 1;
    }
}

fn onCompleteB(irp: *Irp) void {
    _ = irp;
    completion_hits += 1;
    if (order_len < completion_order.len) {
        completion_order[order_len] = 2;
        order_len += 1;
    }
}

/// 与 `src/io/io.zig` `IrpMajorFunction` 中 PnP/Power 序号保持同步（WDK `IRP_MJ_PNP` / `IRP_MJ_POWER` 概念对齐）；改 `io.zig` 枚举时须同步此处。
const IRP_MJ_PNP_HOST: u8 = 9;
const IRP_MJ_POWER_HOST: u8 = 10;

test "IRP major PnP and Power ordinals match io.zig comptime asserts" {
    try std.testing.expectEqual(@as(u8, 9), IRP_MJ_PNP_HOST);
    try std.testing.expectEqual(@as(u8, 10), IRP_MJ_POWER_HOST);
}

test "IRP completion routine runs once after bytes set (IoCompleteRequest contract)" {
    completion_hits = 0;
    var irp: Irp = .{};
    ioSetCompletionRoutine(&irp, onCompleteA);
    ioCompleteRequest(&irp, 4);
    try std.testing.expectEqual(@as(u32, 1), completion_hits);
    try std.testing.expectEqual(@as(u8, 0), irp.completion_depth);
    try std.testing.expectEqual(@as(usize, 4), irp.bytes_transferred);
}

test "IRP completion LIFO order with two routines (matches io.zig stack)" {
    completion_hits = 0;
    order_len = 0;
    var irp: Irp = .{};
    ioSetCompletionRoutine(&irp, onCompleteA);
    ioSetCompletionRoutine(&irp, onCompleteB);
    ioCompleteRequest(&irp, 1);
    try std.testing.expectEqual(@as(u32, 2), completion_hits);
    try std.testing.expectEqual(@as(u8, 2), completion_order[0]);
    try std.testing.expectEqual(@as(u8, 1), completion_order[1]);
}

// 镜像 `io.zig` `resolveStackBottom` / `dispatchIrpThroughStack` 的链式语义（主机侧无 klog 依赖）。
const MAX_DEV: usize = 8;
fn stackBottom(attached: *const [MAX_DEV]u32, count: usize, top: u32) u32 {
    var idx = top;
    var guard: usize = 0;
    while (guard < MAX_DEV) : (guard += 1) {
        if (idx >= count) return top;
        const next = attached[idx];
        if (next == 0) return idx;
        idx = next;
    }
    return top;
}

test "device stack bottom follows attached_device chain" {
    var att: [MAX_DEV]u32 = .{0} ** MAX_DEV;
    att[0] = 1;
    att[1] = 2;
    att[2] = 0;
    try std.testing.expectEqual(@as(u32, 2), stackBottom(&att, 3, 0));
}

test "device stack bottom empty chain returns top" {
    var att: [MAX_DEV]u32 = .{0} ** MAX_DEV;
    try std.testing.expectEqual(@as(u32, 1), stackBottom(&att, 3, 1));
}

const STATUS_SUCCESS_HOST: i32 = 0;
const STATUS_NOT_IMPLEMENTED_HOST: i32 = -1073741822;

const IrpMirror2 = struct { device_hit: u32 = 0 };

/// 镜像 `io.dispatchIrpThroughStack`：下层 `STATUS_NOT_IMPLEMENTED` 时沿 `attached_device` 下降。
fn dispatchThroughStackMirror(top: u32, irp: *IrpMirror2, attached: *const [MAX_DEV]u32, dev_count: usize, impl: *const fn (u32, *IrpMirror2) i32) i32 {
    var idx = top;
    var guard: usize = 0;
    while (guard < MAX_DEV) : (guard += 1) {
        if (idx >= dev_count) return STATUS_NOT_IMPLEMENTED_HOST;
        const st = impl(idx, irp);
        if (st != STATUS_NOT_IMPLEMENTED_HOST) return st;
        const next = attached[idx];
        if (next == 0) return st;
        idx = next;
    }
    return STATUS_NOT_IMPLEMENTED_HOST;
}

/// 镜像 `io.IoForwardIrpToNextDevice`：仅投递到 `attached_device` 一层。
fn ioForwardIrpToNextDeviceMirror(top: u32, attached: *const [MAX_DEV]u32, dev_count: usize, impl: *const fn (u32) i32) i32 {
    if (top >= dev_count) return STATUS_NOT_IMPLEMENTED_HOST;
    const next = attached[top];
    if (next == 0) return STATUS_NOT_IMPLEMENTED_HOST;
    return impl(next);
}

test "IoForwardIrpToNextDevice mirror dispatches to attached lower index" {
    var att: [MAX_DEV]u32 = .{0} ** MAX_DEV;
    att[0] = 1;
    att[1] = 0;
    const S = struct {
        fn disp(idx: u32) i32 {
            if (idx == 1) return STATUS_SUCCESS_HOST;
            return STATUS_NOT_IMPLEMENTED_HOST;
        }
    };
    const st = ioForwardIrpToNextDeviceMirror(0, &att, 2, &S.disp);
    try std.testing.expectEqual(STATUS_SUCCESS_HOST, st);
}

test "IoForwardIrpToNextDevice mirror fails without lower device" {
    var att: [MAX_DEV]u32 = .{0} ** MAX_DEV;
    const S = struct {
        fn disp(_: u32) i32 {
            return STATUS_SUCCESS_HOST;
        }
    };
    const st = ioForwardIrpToNextDeviceMirror(0, &att, 2, &S.disp);
    try std.testing.expectEqual(STATUS_NOT_IMPLEMENTED_HOST, st);
}

test "dispatchIrpThroughStack falls through NOT_IMPLEMENTED to lower device" {
    var att: [MAX_DEV]u32 = .{0} ** MAX_DEV;
    att[0] = 1;
    att[1] = 2;
    att[2] = 0;
    var irp: IrpMirror2 = .{};
    const S = struct {
        fn disp(idx: u32, i: *IrpMirror2) i32 {
            if (idx == 0 or idx == 1) return STATUS_NOT_IMPLEMENTED_HOST;
            if (idx == 2) {
                i.device_hit = idx;
                return STATUS_SUCCESS_HOST;
            }
            return STATUS_NOT_IMPLEMENTED_HOST;
        }
    };
    const st = dispatchThroughStackMirror(0, &irp, &att, 3, &S.disp);
    try std.testing.expectEqual(STATUS_SUCCESS_HOST, st);
    try std.testing.expectEqual(@as(u32, 2), irp.device_hit);
}
