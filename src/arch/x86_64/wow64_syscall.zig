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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/arch/x86_64/wow64_syscall.zig
// Purpose: **int 0x2E**（IDT 向量 0x2E）进入后的 WOW64 分发；8259 已重映射使硬件 IRQ 不占该向量。
//
// Ref: Intel SDM — interrupt/exception vectors; MS Learn WOW64 概念层；本仓库 `wow64/thunk.zig`、`ssdt_x86_win7_sp1.zig`。
// 边界：本文件仅 **入口/帧合法性**；x86→x64 语义与 thunk 在 `subsystems/win32/wow64/`。宿主对照：`tests/host/wow64_x64_semantic_alias_host.zig`。

const process = @import("../../ps/process.zig");
const probe = @import("../../mm/probe.zig");
const ntdll = @import("../../libs/ntdll.zig");
const syscall_abi = @import("syscall_abi.zig");
const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;
const wow64_mod = @import("../../subsystems/win32/wow64.zig");
const types = @import("../../subsystems/win32/wow64/types.zig");
const thunk = @import("../../subsystems/win32/wow64/thunk.zig");

const max_stack_args: usize = 16;

/// 自用户态 **int 0x2E** 帧派发：EAX=x86 服务号，EDX=指向最多 16×u32 实参区的用户指针（与公开 stdcall/NT 用户态约定同阶）。
pub fn dispatchInt2e(frame: *InterruptFrame) void {
    if ((frame.cs & 3) != 3) {
        frame.rax = @as(u64, @bitCast(syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER)));
        return;
    }

    const proc = process.getCurrentProcess() orelse {
        frame.rax = @as(u64, @bitCast(syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE)));
        return;
    };

    const is_wow64_proc = proc.is_wow64 or wow64_mod.findWow64Process(proc.pid) != null;
    if (!is_wow64_proc) {
        frame.rax = @as(u64, @bitCast(syscall_abi.ntStatusAsI64(ntdll.STATUS_NOT_IMPLEMENTED)));
        return;
    }

    var stack_wow: types.Wow64Process = .{};
    const wow_ptr: *types.Wow64Process = blk: {
        if (wow64_mod.findWow64Process(proc.pid)) |wp| break :blk wp;
        stack_wow.pid = proc.pid;
        stack_wow.is_active = true;
        stack_wow.state = .active;
        break :blk &stack_wow;
    };

    const svc: u32 = @truncate(frame.rax);
    const arg_ptr_u32: u32 = @truncate(frame.rdx);

    var args_buf: [max_stack_args]u32 = [_]u32{0} ** max_stack_args;
    var args_slice: []const u32 = &[_]u32{};

    if (arg_ptr_u32 != 0) {
        const asp = proc.address_space orelse {
            frame.rax = @as(u64, @bitCast(syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER)));
            return;
        };
        const ap: u64 = arg_ptr_u32;
        if (ap > types.WOW64_MAX_ADDR) {
            frame.rax = @as(u64, @bitCast(syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER)));
            return;
        }
        const nbytes: u64 = max_stack_args * @sizeOf(u32);
        if (!probe.probeUserMemory(asp, ap, nbytes, false)) {
            frame.rax = @as(u64, @bitCast(syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION)));
            return;
        }
        const p = @as([*]const volatile u32, @ptrFromInt(ap));
        var i: usize = 0;
        while (i < max_stack_args) : (i += 1) {
            args_buf[i] = p[i];
        }
        args_slice = args_buf[0..max_stack_args];
    }

    const st = thunk.translateSyscall32to64WithArgs(wow_ptr, svc, args_slice);
    frame.rax = @as(u64, @bitCast(syscall_abi.ntStatusAsI64(st)));
}
