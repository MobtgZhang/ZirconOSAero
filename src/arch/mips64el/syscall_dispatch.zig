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
//! MIPS64EL system call dispatch: reuses NT 6.1 SSDT service numbers (ssdt_nt61.zig),
//! bridged through MIPS N64 ABI ($v0 = syscall number, $a0-$a5 = parameters).
//!
//! Clean-room: service numbers from this repo's ssdt_nt61.zig; behavior from docs/specs/.

const process = @import("../../ps/process.zig");
const probe = @import("../../mm/probe.zig");
const klog = @import("../../rtl/klog.zig");
const ntdll = @import("../../libs/ntdll.zig");
const ssdt = @import("../x86_64/ssdt_nt61.zig");
const user32 = @import("../../subsystems/win32/user32.zig");

fn ntResult(s: ntdll.NTSTATUS) u64 {
    return @bitCast(@as(i64, @intCast(@as(i32, @bitCast(s)))));
}

const STATUS_SUCCESS: u64 = 0;
const STATUS_NOT_IMPLEMENTED: u64 = ntResult(ntdll.STATUS_NOT_IMPLEMENTED);

/// Trap frame offsets matching exceptions.S / mips_defs.h:
/// $v0 = TF_V0 = 16, $a0 = TF_A0 = 32, $a1 = TF_A1 = 40, etc.
const OFF_V0: usize = 16;
const OFF_A0: usize = 32;
const OFF_A1: usize = 40;
const OFF_A2: usize = 48;
const OFF_A3: usize = 56;
const OFF_A4: usize = 64;
const OFF_A5: usize = 72;

fn readFrame(sp: usize, off: usize) u64 {
    return @as(*const volatile u64, @ptrFromInt(sp + off)).*;
}

fn notImplemented(svc: u32) u64 {
    klog.debug("MIPS64EL: unimpl syscall 0x%x", .{svc});
    return STATUS_NOT_IMPLEMENTED;
}

pub fn dispatch(frame_sp: usize) u64 {
    const idx = readFrame(frame_sp, OFF_V0);
    const p1 = readFrame(frame_sp, OFF_A0);
    const p2 = readFrame(frame_sp, OFF_A1);
    const p3 = readFrame(frame_sp, OFF_A2);
    const p4 = readFrame(frame_sp, OFF_A3);
    const p5 = readFrame(frame_sp, OFF_A4);
    const p6 = readFrame(frame_sp, OFF_A5);
    const svc: u32 = @truncate(idx);

    return switch (svc) {
        ssdt.NtClose => ntResult(ntdll.NtClose(@truncate(p1))),
        ssdt.NtWaitForSingleObject => blk: {
            const alertable = p2 != 0;
            const timeout_ptr: ?*const i64 = if (p3 == 0) null else @ptrFromInt(p3);
            break :blk ntResult(ntdll.NtWaitForSingleObject(@truncate(p1), alertable, timeout_ptr));
        },
        ssdt.NtAllocateVirtualMemory => dispatchAllocVM(p1, p2, p3, p4, p5, p6),
        ssdt.NtFreeVirtualMemory => dispatchFreeVM(p1, p2, p3, p4),
        ssdt.NtProtectVirtualMemory => dispatchProtectVM(p1, p2, p3, p4, p5),
        ssdt.NtQuerySystemInformation => dispatchQuerySysInfo(p1, p2, p3, p4),
        ssdt.NtYieldExecution => blk: {
            const scheduler = @import("../../ke/scheduler.zig");
            scheduler.yield();
            break :blk STATUS_SUCCESS;
        },
        ssdt.NtTerminateProcess => ntResult(ntdll.NtTerminateProcess(@truncate(p1), @as(ntdll.NTSTATUS, @bitCast(@as(u32, @truncate(p2)))))),
        ssdt.NtCreateThread => ntResult(ntdll.NtCreateThread(@ptrFromInt(p1), @truncate(p2))),
        ssdt.NtTerminateThread => ntResult(ntdll.NtTerminateThread(@truncate(p1), @as(ntdll.NTSTATUS, @bitCast(@as(u32, @truncate(p2)))))),
        ssdt.NtDelayExecution => blk: {
            if (p2 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const interval = @as(*const volatile i64, @ptrFromInt(p2)).*;
            break :blk ntResult(ntdll.NtDelayExecution(@truncate(p1), interval));
        },
        ssdt.NtDisplayString => blk: {
            const arch_mod = @import("../../arch.zig");
            arch_mod.consoleWrite("[NtDisplayString]\r\n");
            break :blk STATUS_SUCCESS;
        },
        ssdt.NtUserGetMessage => ntResult(user32.ntUserGetMessageSyscall(p1, p2, @truncate(p3), @truncate(p4))),
        ssdt.NtUserPostMessage => ntResult(user32.ntUserPostMessageSyscall(p1, @truncate(p2), p3, p4)),
        ssdt.NtUserSendMessage => ntResult(user32.ntUserSendMessageSyscall(p1, @truncate(p2), p3, p4)),
        ssdt.NtShutdownSystem => ntResult(ntdll.NtShutdownSystem(@truncate(p1))),

        ssdt.NtQueryInformationProcess => notImplemented(svc),
        ssdt.NtSetInformationProcess => notImplemented(svc),
        ssdt.NtQueryInformationThread => notImplemented(svc),
        ssdt.NtSetInformationThread => notImplemented(svc),
        ssdt.NtResumeThread => notImplemented(svc),
        ssdt.NtSuspendThread => notImplemented(svc),
        ssdt.NtAlertThread => notImplemented(svc),
        ssdt.NtTestAlert => notImplemented(svc),
        ssdt.NtCreateSemaphore => notImplemented(svc),
        ssdt.NtOpenSemaphore => notImplemented(svc),
        ssdt.NtReleaseSemaphore => notImplemented(svc),
        ssdt.NtCreateEvent => notImplemented(svc),
        ssdt.NtOpenEvent => notImplemented(svc),
        ssdt.NtSetEvent => notImplemented(svc),
        ssdt.NtResetEvent => notImplemented(svc),
        ssdt.NtPulseEvent => notImplemented(svc),
        ssdt.NtClearEvent => notImplemented(svc),
        ssdt.NtOpenThread => notImplemented(svc),
        ssdt.NtDuplicateObject => notImplemented(svc),
        ssdt.NtOpenProcess => notImplemented(svc),
        ssdt.NtMapViewOfSection => notImplemented(svc),
        ssdt.NtUnmapViewOfSection => notImplemented(svc),
        ssdt.NtQueryVirtualMemory => notImplemented(svc),
        ssdt.NtReadVirtualMemory => notImplemented(svc),
        ssdt.NtWriteVirtualMemory => notImplemented(svc),
        ssdt.NtOpenKey => notImplemented(svc),
        ssdt.NtQueryValueKey => notImplemented(svc),
        ssdt.NtCreateKey => notImplemented(svc),
        ssdt.NtSetValueKey => notImplemented(svc),
        ssdt.NtEnumerateKey => notImplemented(svc),
        ssdt.NtEnumerateValueKey => notImplemented(svc),
        ssdt.NtCreateFile => notImplemented(svc),
        ssdt.NtReadFile => notImplemented(svc),
        ssdt.NtWriteFile => notImplemented(svc),
        ssdt.NtDeviceIoControlFile => notImplemented(svc),
        ssdt.NtFsControlFile => notImplemented(svc),
        ssdt.NtFlushBuffersFile => notImplemented(svc),
        ssdt.NtCancelIoFile => notImplemented(svc),
        ssdt.NtCancelIoFileEx => notImplemented(svc),
        ssdt.NtConnectPort => notImplemented(svc),
        ssdt.NtCreatePort => notImplemented(svc),
        ssdt.NtRequestWaitReplyPort => notImplemented(svc),
        ssdt.NtCreateSection => notImplemented(svc),
        ssdt.NtCreateMutant => notImplemented(svc),
        ssdt.NtOpenMutant => notImplemented(svc),
        ssdt.NtReleaseMutant => notImplemented(svc),
        ssdt.NtQueryMutant => notImplemented(svc),
        ssdt.NtCreateProcess => notImplemented(svc),
        ssdt.NtCreateUserProcess => notImplemented(svc),
        ssdt.NtCreateThreadEx => notImplemented(svc),
        ssdt.NtAlpcConnectPort => notImplemented(svc),
        ssdt.NtAlpcCreatePort => notImplemented(svc),
        ssdt.NtAlpcSendWaitReceivePort => notImplemented(svc),
        ssdt.NtWaitForMultipleObjects => notImplemented(svc),
        ssdt.NtSignalAndWaitForSingleObject => notImplemented(svc),
        ssdt.NtSetInformationObject => notImplemented(svc),
        ssdt.NtInitiatePowerAction => notImplemented(svc),
        ssdt.NtQueryObject => notImplemented(svc),

        else => blk: {
            klog.warn("MIPS64EL: unknown NT syscall idx 0x%x", .{svc});
            break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
        },
    };
}

fn dispatchAllocVM(process_handle: u64, base_ptr_va: u64, zero_bits: u64, size_ptr_va: u64, allocation_type: u64, protect: u64) u64 {
    if (base_ptr_va == 0 or size_ptr_va == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const st = ntdll.NtAllocateVirtualMemory(process_handle, @ptrFromInt(base_ptr_va), zero_bits, @ptrFromInt(size_ptr_va), @truncate(allocation_type), @truncate(protect));
    return ntResult(st);
}

fn dispatchFreeVM(process_handle: u64, base_ptr_va: u64, size_ptr_va: u64, free_type: u64) u64 {
    if (base_ptr_va == 0 or size_ptr_va == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const st = ntdll.NtFreeVirtualMemory(process_handle, @ptrFromInt(base_ptr_va), @ptrFromInt(size_ptr_va), @truncate(free_type));
    return ntResult(st);
}

fn dispatchProtectVM(process_handle: u64, base_ptr_va: u64, size_ptr_va: u64, new_protect: u64, old_protect_va: u64) u64 {
    const proc_pr = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp_pr = proc_pr.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (base_ptr_va == 0 or size_ptr_va == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_pr, base_ptr_va, @sizeOf(u64), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp_pr, size_ptr_va, @sizeOf(u64), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    var oldp_opt: ?*u32 = null;
    if (old_protect_va != 0) {
        if (!probe.probeUserMemory(asp_pr, old_protect_va, @sizeOf(u32), true))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
        oldp_opt = @ptrFromInt(old_protect_va);
    }
    const st = ntdll.NtProtectVirtualMemory(process_handle, @ptrFromInt(base_ptr_va), @ptrFromInt(size_ptr_va), @truncate(new_protect), oldp_opt);
    return ntResult(st);
}

fn dispatchQuerySysInfo(info_class: u64, buffer: u64, length: u64, return_len_va: u64) u64 {
    if (return_len_va == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const len32: u32 = @truncate(length);
    const rl: *u32 = @ptrFromInt(return_len_va);
    const buf: [*]u8 = @ptrFromInt(buffer);
    const st = ntdll.NtQuerySystemInformation(@truncate(info_class), buf[0..len32], rl);
    return ntResult(st);
}
