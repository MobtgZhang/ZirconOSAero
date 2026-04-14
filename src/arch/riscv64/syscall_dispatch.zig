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

//! RISC-V 64 ecall syscall dispatch.
//! Called from traps.zig when scause == 8 (U-mode ecall).
//! Convention: a7 = syscall number, a0–a5 = arguments, return in a0.
//! Reuses the x86_64 SSDT index table and shared service implementations.
//
// Clean-room: service numbers follow ssdt_nt61.zig constants.

const ssdt = @import("../x86_64/ssdt_nt61.zig");
const ntdll = @import("../../libs/ntdll.zig");
const klog = @import("../../rtl/klog.zig");
const TrapFrame = @import("traps.zig").TrapFrame;

fn ntResult(s: ntdll.NTSTATUS) i64 {
    return @intCast(@as(i32, @bitCast(s)));
}

fn notImplemented(num: u64) i64 {
    klog.debug("riscv64: unhandled ecall num=0x%x", .{num});
    return ntResult(ntdll.STATUS_NOT_IMPLEMENTED);
}

pub fn dispatch(frame: *TrapFrame) i64 {
    const num = frame.x17_a7;
    const p1 = frame.x10_a0;
    const p2 = frame.x11_a1;
    const p3 = frame.x12_a2;
    const p4 = frame.x13_a3;
    const p5 = frame.x14_a4;
    const p6 = frame.x15_a5;

    const result: i64 = switch (num) {
        ssdt.NtYieldExecution => blk: {
            @import("../../ke/scheduler.zig").yield();
            break :blk ntResult(ntdll.STATUS_SUCCESS);
        },
        ssdt.NtTerminateProcess => blk: {
            const process = @import("../../ps/process.zig");
            if (process.getCurrentProcess()) |proc| {
                _ = process.terminateProcess(proc.pid, 0);
            }
            break :blk ntResult(ntdll.STATUS_SUCCESS);
        },
        ssdt.NtClose => ntResult(ntdll.NtClose(@truncate(p1))),
        ssdt.NtWaitForSingleObject => ntResult(ntdll.NtWaitForSingleObject(
            @truncate(p1),
            p2 != 0,
            if (p3 == 0) null else @ptrFromInt(p3),
        )),
        ssdt.NtAllocateVirtualMemory => blk: {
            if (p2 == 0 or p4 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            break :blk ntResult(ntdll.NtAllocateVirtualMemory(
                @truncate(p1),
                @ptrFromInt(p2),
                p3,
                @ptrFromInt(p4),
                @truncate(p5),
                @truncate(p6),
            ));
        },
        ssdt.NtFreeVirtualMemory => blk: {
            if (p2 == 0 or p3 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            break :blk ntResult(ntdll.NtFreeVirtualMemory(
                @truncate(p1),
                @ptrFromInt(p2),
                @ptrFromInt(p3),
                @truncate(p4),
            ));
        },
        ssdt.NtProtectVirtualMemory => blk: {
            if (p2 == 0 or p3 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            break :blk ntResult(ntdll.NtProtectVirtualMemory(
                @truncate(p1),
                @ptrFromInt(p2),
                @ptrFromInt(p3),
                @truncate(p4),
                null,
            ));
        },
        ssdt.NtDelayExecution => blk: {
            if (p2 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const interval = @as(*const volatile i64, @ptrFromInt(p2)).*;
            break :blk ntResult(ntdll.NtDelayExecution(@truncate(p1), interval));
        },
        ssdt.NtCreateThread => ntResult(ntdll.NtCreateThread(@ptrFromInt(p1), @truncate(p2))),
        ssdt.NtTerminateThread => ntResult(ntdll.NtTerminateThread(@truncate(p1), @as(ntdll.NTSTATUS, @bitCast(@as(u32, @truncate(p2)))))),
        ssdt.NtQuerySystemInformation => blk: {
            const info_class: u32 = @truncate(p1);
            const len: u32 = @truncate(p3);
            const buf: [*]u8 = @ptrFromInt(p2);
            const rl: *u32 = @ptrFromInt(p4);
            break :blk ntResult(ntdll.NtQuerySystemInformation(info_class, buf[0..len], rl));
        },
        ssdt.NtCreateSection => ntResult(ntdll.NtCreateSection(
            @ptrFromInt(p1),
            @truncate(p2),
            null,
            @ptrFromInt(p3),
            @truncate(p4),
            @truncate(p5),
            @truncate(p6),
        )),
        ssdt.NtMapViewOfSection => notImplemented(num),
        ssdt.NtUnmapViewOfSection => notImplemented(num),
        ssdt.NtReadVirtualMemory => notImplemented(num),
        ssdt.NtWriteVirtualMemory => notImplemented(num),
        ssdt.NtQueryInformationProcess => notImplemented(num),
        ssdt.NtSetInformationProcess => notImplemented(num),
        ssdt.NtQueryInformationThread => notImplemented(num),
        ssdt.NtSetInformationThread => notImplemented(num),
        ssdt.NtResumeThread => notImplemented(num),
        ssdt.NtSuspendThread => notImplemented(num),
        ssdt.NtAlertThread => notImplemented(num),
        ssdt.NtTestAlert => notImplemented(num),
        ssdt.NtCreateSemaphore => notImplemented(num),
        ssdt.NtOpenSemaphore => notImplemented(num),
        ssdt.NtReleaseSemaphore => notImplemented(num),
        ssdt.NtCreateEvent => notImplemented(num),
        ssdt.NtOpenEvent => notImplemented(num),
        ssdt.NtSetEvent => notImplemented(num),
        ssdt.NtResetEvent => notImplemented(num),
        ssdt.NtPulseEvent => notImplemented(num),
        ssdt.NtClearEvent => notImplemented(num),
        ssdt.NtOpenProcess => notImplemented(num),
        ssdt.NtOpenThread => notImplemented(num),
        ssdt.NtDuplicateObject => notImplemented(num),
        ssdt.NtDisplayString => blk: {
            const arch_mod = @import("../riscv64/mod.zig");
            arch_mod.consoleWrite("[NtDisplayString]\r\n");
            break :blk ntResult(ntdll.STATUS_SUCCESS);
        },
        else => notImplemented(num),
    };

    return result;
}
