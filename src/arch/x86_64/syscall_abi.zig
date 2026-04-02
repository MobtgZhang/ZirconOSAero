// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/arch/x86_64/syscall_abi.zig
// Purpose: 共享的 NT x64 syscall 用户栈读参（与 `syscall.zig` / `syscall_nt_extras.zig` 复用）。
//
// Ref: https://learn.microsoft.com/cpp/build/x64-calling-convention （寄存器与栈帧布局概念）
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K7

const process = @import("../../ps/process.zig");
const probe = @import("../../mm/probe.zig");
const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;

/// 自用户栈读取第 N 个 syscall 扩展参数（N=0 → 第 5 个实参），偏移相对 SYSCALL 时的用户 RSP。
pub fn userStackArg(frame: *InterruptFrame, nth_stack_arg: u8) ?u64 {
    const proc = process.getCurrentProcess() orelse return null;
    const asp = proc.address_space orelse return null;
    const off: u64 = 0x28 + @as(u64, nth_stack_arg) * 8;
    if (frame.rsp > 0xFFFF_FFFF_FFFF_F000) return null;
    const va = frame.rsp +% off;
    if (va < frame.rsp) return null;
    const aligned = va & ~@as(u64, 7);
    if (!probe.probeUserMemory(asp, aligned, 8, false)) return null;
    // SAFETY: `probeUserMemory` 已确认用户栈页可读；地址来自用户 RSP + 固定 Win64 syscall 栈偏移。
    return @as(*const volatile u64, @ptrFromInt(va)).*;
}

pub fn ntStatusAsI64(status: i32) i64 {
    return @intCast(status);
}
