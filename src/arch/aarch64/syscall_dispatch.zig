// SPDX-License-Identifier: MIT OR Apache-2.0
//! AArch64 system call dispatch: reuses NT 6.1 SSDT service numbers (ssdt_nt61.zig),
//! bridged via AArch64 calling convention (x8 = service number, x0–x5 = arguments, return in x0).
//!
//! Clean-room: service numbers per this repository's `ssdt_nt61.zig`; behaviour per `docs/specs/`.

const TrapFrame = @import("traps.zig").TrapFrame;
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

pub fn dispatch(frame: *TrapFrame) u64 {
    const svc: u32 = @truncate(frame.x8);
    const p1 = frame.x0;
    const p2 = frame.x1;
    const p3 = frame.x2;
    const p4 = frame.x3;
    const p5 = frame.x4;
    const p6 = frame.x5;

    return switch (svc) {
        ssdt.NtClose => ntResult(ntdll.NtClose(p1)),
        ssdt.NtWaitForSingleObject => blk: {
            const alertable = p2 != 0;
            const timeout_ptr: ?*const i64 = if (p3 == 0) null else @ptrFromInt(p3);
            const st = ntdll.NtWaitForSingleObject(p1, alertable, timeout_ptr);
            break :blk ntResult(st);
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
        ssdt.NtTerminateProcess => ntResult(ntdll.NtTerminateProcess(p1, @as(ntdll.NTSTATUS, @bitCast(@as(u32, @truncate(p2)))))),
        ssdt.NtCreateThread => ntResult(ntdll.NtCreateThread(@ptrFromInt(p1), @truncate(p2))),
        ssdt.NtTerminateThread => ntResult(ntdll.NtTerminateThread(@truncate(p1), @as(ntdll.NTSTATUS, @bitCast(@as(u32, @truncate(p2)))))),
        ssdt.NtDelayExecution => blk: {
            if (p2 == 0) break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
            const interval = @as(*const volatile i64, @ptrFromInt(p2)).*;
            const st = ntdll.NtDelayExecution(@truncate(p1), interval);
            break :blk ntResult(st);
        },
        ssdt.NtDisplayString => blk: {
            const arch_mod = @import("../../arch.zig");
            arch_mod.consoleWrite("[NtDisplayString]\r\n");
            break :blk STATUS_SUCCESS;
        },
        ssdt.NtCreateSection => dispatchCreateSection(p1, p2, p3, p4, p5, p6),
        ssdt.NtReadFile => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtWriteFile => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtUserGetMessage => ntResult(user32.ntUserGetMessageSyscall(p1, p2, @truncate(p3), @truncate(p4))),
        ssdt.NtUserPostMessage => ntResult(user32.ntUserPostMessageSyscall(p1, @truncate(p2), p3, p4)),
        ssdt.NtUserSendMessage => ntResult(user32.ntUserSendMessageSyscall(p1, @truncate(p2), p3, p4)),
        ssdt.NtShutdownSystem => ntResult(ntdll.NtShutdownSystem(@truncate(p1))),

        ssdt.NtQueryInformationProcess,
        ssdt.NtSetInformationProcess,
        ssdt.NtQueryInformationThread,
        ssdt.NtSetInformationThread,
        ssdt.NtResumeThread,
        ssdt.NtSuspendThread,
        ssdt.NtAlertThread,
        ssdt.NtTestAlert,
        ssdt.NtCreateSemaphore,
        ssdt.NtOpenSemaphore,
        ssdt.NtReleaseSemaphore,
        ssdt.NtCreateEvent,
        ssdt.NtOpenEvent,
        ssdt.NtSetEvent,
        ssdt.NtResetEvent,
        ssdt.NtPulseEvent,
        ssdt.NtClearEvent,
        ssdt.NtOpenThread,
        ssdt.NtQueryObject,
        ssdt.NtOpenFile,
        ssdt.NtCreateMutant,
        ssdt.NtOpenMutant,
        ssdt.NtReleaseMutant,
        ssdt.NtQueryMutant,
        ssdt.NtCreateProcess,
        ssdt.NtCreateUserProcess,
        ssdt.NtCreateThreadEx,
        ssdt.NtAlpcConnectPort,
        ssdt.NtAlpcCreatePort,
        ssdt.NtAlpcSendWaitReceivePort,
        ssdt.NtMapViewOfSection,
        ssdt.NtUnmapViewOfSection,
        ssdt.NtQueryVirtualMemory,
        ssdt.NtOpenProcess,
        ssdt.NtDuplicateObject,
        ssdt.NtReadVirtualMemory,
        ssdt.NtWriteVirtualMemory,
        ssdt.NtOpenKey,
        ssdt.NtQueryValueKey,
        ssdt.NtCreateKey,
        ssdt.NtSetValueKey,
        ssdt.NtEnumerateKey,
        ssdt.NtEnumerateValueKey,
        ssdt.NtCreateFile,
        ssdt.NtDeviceIoControlFile,
        ssdt.NtLockVirtualMemory,
        ssdt.NtUnlockVirtualMemory,
        ssdt.NtFsControlFile,
        ssdt.NtFlushBuffersFile,
        ssdt.NtCancelIoFile,
        ssdt.NtCancelIoFileEx,
        ssdt.NtConnectPort,
        ssdt.NtCreatePort,
        ssdt.NtRequestWaitReplyPort,
        ssdt.NtWaitForMultipleObjects,
        ssdt.NtSetInformationObject,
        ssdt.NtSignalAndWaitForSingleObject,
        ssdt.NtInitiatePowerAction,
        ssdt.NtUserPeekMessage,
        ssdt.NtUserSetWindowPos,
        ssdt.NtUserDispatchMessage,
        => STATUS_NOT_IMPLEMENTED,

        else => blk: {
            klog.warn("AArch64: unknown NT syscall idx 0x%x", .{svc});
            break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
        },
    };
}

fn dispatchAllocVM(
    process_handle: u64,
    base_ptr_va: u64,
    zero_bits: u64,
    size_ptr_va: u64,
    allocation_type: u64,
    protect: u64,
) u64 {
    if (base_ptr_va == 0 or size_ptr_va == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const st = ntdll.NtAllocateVirtualMemory(
        process_handle,
        @ptrFromInt(base_ptr_va),
        zero_bits,
        @ptrFromInt(size_ptr_va),
        @truncate(allocation_type),
        @truncate(protect),
    );
    return ntResult(st);
}

fn dispatchFreeVM(process_handle: u64, base_ptr_va: u64, size_ptr_va: u64, free_type: u64) u64 {
    if (base_ptr_va == 0 or size_ptr_va == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const st = ntdll.NtFreeVirtualMemory(
        process_handle,
        @ptrFromInt(base_ptr_va),
        @ptrFromInt(size_ptr_va),
        @truncate(free_type),
    );
    return ntResult(st);
}

fn dispatchProtectVM(
    process_handle: u64,
    base_ptr_va: u64,
    size_ptr_va: u64,
    new_protect: u64,
    old_protect_va: u64,
) u64 {
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
    const st = ntdll.NtProtectVirtualMemory(
        process_handle,
        @ptrFromInt(base_ptr_va),
        @ptrFromInt(size_ptr_va),
        @truncate(new_protect),
        oldp_opt,
    );
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

fn dispatchCreateSection(
    section_handle_user: u64,
    desired_access: u64,
    object_attributes_va: u64,
    maximum_size_ptr: u64,
    page_protect: u64,
    allocation_attributes: u64,
) u64 {
    _ = object_attributes_va;
    if (section_handle_user == 0 or maximum_size_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const proc_s = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const asp_s = proc_s.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_s, section_handle_user, @sizeOf(ntdll.HANDLE), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp_s, maximum_size_ptr, @sizeOf(u64), false))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtCreateSection(
        &local,
        @truncate(desired_access),
        null,
        @ptrFromInt(maximum_size_ptr),
        @truncate(page_protect),
        @truncate(allocation_attributes),
        @as(ntdll.NTSTATUS, @bitCast(@as(u32, 0))), // file_handle=0 for anonymous section
    );
    if (st == ntdll.STATUS_SUCCESS) {
        @as(*volatile ntdll.HANDLE, @ptrFromInt(section_handle_user)).* = local;
    }
    return ntResult(st);
}
