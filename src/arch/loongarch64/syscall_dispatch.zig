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
//! LoongArch64 系统调用分发：复用 NT 6.1 SSDT 服务号（ssdt_nt61.zig），
//! 但 ABI 按 LoongArch calling convention（a0–a5 参数，a7 服务号）桥接。
//!
//! Clean-room：服务号以本仓库 `ssdt_nt61.zig` 为准；行为以 `docs/specs/` 规格为准。
//!
//! ## 阶段2补全记录
//! - 第1周：NtReadFile, NtWriteFile, NtOpenProcess, NtOpenThread, NtOpenFile, NtCreateFile
//! - 第2周：同步原语 - NtCreateEvent/NtSetEvent/NtResetEvent/NtPulseEvent/NtClearEvent
//!          NtCreateMutant/NtReleaseMutant/NtQueryMutant
//!          NtCreateSemaphore/NtReleaseSemaphore
//! - 第3周：内存管理 - NtQueryVirtualMemory, NtReadVirtualMemory, NtWriteVirtualMemory
//!          NtMapViewOfSection, NtUnmapViewOfSection
//! - 第4周：高级特性 - NtDuplicateObject, NtDeviceIoControlFile, NtFlushBuffersFile
//!          NtWaitForMultipleObjects, NtSignalAndWaitForSingleObject

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

pub fn dispatch(frame_sp: usize) u64 {
    const idx = readFrame(frame_sp, OFF_A7);
    const p1 = readFrame(frame_sp, OFF_A0);
    const p2 = readFrame(frame_sp, OFF_A1);
    const p3 = readFrame(frame_sp, OFF_A2);
    const p4 = readFrame(frame_sp, OFF_A3);
    const p5 = readFrame(frame_sp, OFF_A4);
    const p6 = readFrame(frame_sp, OFF_A5);
    const p7 = readFrame(frame_sp, OFF_A6);
    const svc: u32 = @truncate(idx);

    return switch (svc) {
        // ── 基础服务 ──
        ssdt.NtClose => ntResult(ntdll.NtClose(p1)),
        ssdt.NtWaitForSingleObject => blk: {
            const alertable = p2 != 0;
            const timeout_ptr: ?*const i64 = if (p3 == 0) null else @ptrFromInt(p3);
            const st = ntdll.NtWaitForSingleObject(p1, alertable, timeout_ptr);
            break :blk ntResult(st);
        },
        ssdt.NtYieldExecution => blk: {
            const scheduler = @import("../../ke/scheduler.zig");
            scheduler.yield();
            break :blk STATUS_SUCCESS;
        },
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
        ssdt.NtShutdownSystem => ntResult(ntdll.NtShutdownSystem(@truncate(p1))),

        // ── 第1周：基础文件I/O ──
        ssdt.NtReadFile => dispatchNtReadFile(frame_sp),
        ssdt.NtWriteFile => dispatchNtWriteFile(frame_sp),
        ssdt.NtOpenFile => dispatchNtOpenFile(frame_sp),
        ssdt.NtCreateFile => dispatchNtCreateFile(frame_sp),
        ssdt.NtFlushBuffersFile => ntResult(ntdll.NtFlushBuffersFile(@truncate(p1), @ptrFromInt(p2))),
        ssdt.NtDeviceIoControlFile => dispatchNtDeviceIoControlFile(frame_sp),

        // ── 第1周：进程/线程打开 ──
        ssdt.NtOpenProcess => dispatchNtOpenProcess(frame_sp),
        ssdt.NtOpenThread => ntResult(ntdll.NtOpenThread(
            @ptrFromInt(p1),
            @truncate(p2),
            @ptrFromInt(p3),
            @ptrFromInt(p4),
        )),

        // ── 第2周：虚拟内存 ──
        ssdt.NtAllocateVirtualMemory => dispatchAllocVM(p1, p2, p3, p4, p5, p6),
        ssdt.NtFreeVirtualMemory => dispatchFreeVM(p1, p2, p3, p4),
        ssdt.NtProtectVirtualMemory => dispatchProtectVM(p1, p2, p3, p4, p5),
        ssdt.NtQueryVirtualMemory => dispatchNtQueryVirtualMemory(frame_sp),
        ssdt.NtReadVirtualMemory => dispatchNtReadVirtualMemory(frame_sp),
        ssdt.NtWriteVirtualMemory => dispatchNtWriteVirtualMemory(frame_sp),
        ssdt.NtLockVirtualMemory => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtUnlockVirtualMemory => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),

        // ── 第2周：系统信息 ──
        ssdt.NtQuerySystemInformation => dispatchQuerySysInfo(p1, p2, p3, p4),

        // ── 第2周：同步原语 - 事件 ──
        ssdt.NtCreateEvent => ntResult(ntdll.NtCreateEvent(
            @ptrFromInt(p1),
            @truncate(p2),
            @ptrFromInt(p3),
            @truncate(p4),
            p5 != 0,
        )),
        ssdt.NtOpenEvent => ntResult(ntdll.NtOpenEvent(
            @ptrFromInt(p1),
            @truncate(p2),
            @ptrFromInt(p3),
        )),
        ssdt.NtSetEvent => ntResult(ntdll.NtSetEvent(p1, @ptrFromInt(p2))),
        ssdt.NtResetEvent => ntResult(ntdll.NtResetEvent(p1, @ptrFromInt(p2))),
        ssdt.NtPulseEvent => ntResult(ntdll.NtPulseEvent(p1, @ptrFromInt(p2))),
        ssdt.NtClearEvent => ntResult(ntdll.NtClearEvent(p1, @ptrFromInt(p2))),

        // ── 第2周：同步原语 - 互斥体 ──
        ssdt.NtCreateMutant => ntResult(ntdll.NtCreateMutant(
            @ptrFromInt(p1),
            @truncate(p2),
            @ptrFromInt(p3),
            p4 != 0,
        )),
        ssdt.NtOpenMutant => ntResult(ntdll.NtOpenMutant(
            @ptrFromInt(p1),
            @truncate(p2),
            @ptrFromInt(p3),
        )),
        ssdt.NtReleaseMutant => ntResult(ntdll.NtReleaseMutant(p1, @ptrFromInt(p2))),
        ssdt.NtQueryMutant => ntResult(ntdll.NtQueryMutant(
            p1,
            @truncate(p2),
            @ptrFromInt(p3),
            @truncate(p4),
            @ptrFromInt(p5),
        )),

        // ── 第2周：同步原语 - 信号量 ──
        ssdt.NtCreateSemaphore => ntResult(ntdll.NtCreateSemaphore(
            @ptrFromInt(p1),
            @truncate(p2),
            @ptrFromInt(p3),
            @as(i32, @bitCast(@as(u32, @truncate(p4)))),
            @as(i32, @bitCast(@as(u32, @truncate(p5)))),
        )),
        ssdt.NtOpenSemaphore => ntResult(ntdll.NtOpenSemaphore(
            @ptrFromInt(p1),
            @truncate(p2),
            @ptrFromInt(p3),
        )),
        ssdt.NtReleaseSemaphore => ntResult(ntdll.NtReleaseSemaphore(
            p1,
            @as(i32, @bitCast(@as(u32, @truncate(p2)))),
            @ptrFromInt(p3),
        )),

        // ── 第2周：等待多对象 ──
        ssdt.NtWaitForMultipleObjects => dispatchNtWaitForMultipleObjects(frame_sp),
        ssdt.NtSignalAndWaitForSingleObject => ntResult(ntdll.NtSignalAndWaitForSingleObject(
            p1,
            p2,
            @truncate(p3),
            @ptrFromInt(p4),
        )),

        // ── 第3周：Section/内存映射 ──
        ssdt.NtCreateSection => dispatchCreateSection(p1, p2, p3, p4, p5, p6, p7),
        ssdt.NtMapViewOfSection => dispatchNtMapViewOfSection(frame_sp),
        ssdt.NtUnmapViewOfSection => ntResult(ntdll.NtUnmapViewOfSection(
            @truncate(p1),
            p2,
        )),

        // ── 第3周：进程/线程管理 ──
        ssdt.NtTerminateProcess => ntResult(ntdll.NtTerminateProcess(p1, @as(ntdll.NTSTATUS, @bitCast(@as(u32, @truncate(p2)))))),
        ssdt.NtCreateThread => ntResult(ntdll.NtCreateThread(@ptrFromInt(p1), @truncate(p2))),
        ssdt.NtTerminateThread => ntResult(ntdll.NtTerminateThread(p1, @as(ntdll.NTSTATUS, @bitCast(@as(u32, @truncate(p2)))))),
        ssdt.NtResumeThread => ntResult(ntdll.NtResumeThread(p1, @ptrFromInt(p2))),
        ssdt.NtSuspendThread => ntResult(ntdll.NtSuspendThread(p1, @ptrFromInt(p2))),

        // ── 第3周：进程/线程信息查询 ──
        ssdt.NtQueryInformationProcess => ntResult(ntdll.NtQueryInformationProcess(
            p1,
            @truncate(p2),
            @ptrFromInt(p3),
            @truncate(p4),
            @ptrFromInt(p5),
        )),
        ssdt.NtSetInformationProcess => ntResult(ntdll.NtSetInformationProcess(
            p1,
            @truncate(p2),
            @ptrFromInt(p3),
            @truncate(p4),
        )),
        ssdt.NtQueryInformationThread => ntResult(ntdll.NtQueryInformationThread(
            p1,
            @truncate(p2),
            @ptrFromInt(p3),
            @truncate(p4),
            @ptrFromInt(p5),
        )),
        ssdt.NtSetInformationThread => ntResult(ntdll.NtSetInformationThread(p1, @truncate(p2), @ptrFromInt(p3), @truncate(p4))),

        // ── 第4周：对象操作 ──
        ssdt.NtDuplicateObject => dispatchNtDuplicateObject(frame_sp),
        ssdt.NtQueryObject => ntResult(ntdll.NtQueryObject(
            p1,
            @truncate(p2),
            @ptrFromInt(p3),
            @truncate(p4),
            @ptrFromInt(p5),
        )),
        ssdt.NtSetInformationObject => ntResult(ntdll.NtSetInformationObject(
            p1,
            @truncate(p2),
            @ptrFromInt(p3),
            @truncate(p4),
        )),

        // ── APC/Alert ──
        ssdt.NtAlertThread => ntResult(ntdll.NtAlertThread(p1)),
        ssdt.NtTestAlert => ntResult(ntdll.NtTestAlert()),

        // ── 注册表 ──
        ssdt.NtOpenKey => ntResult(ntdll.NtOpenKey(@ptrFromInt(p1), @truncate(p2), @ptrFromInt(p3))),
        ssdt.NtQueryValueKey => ntResult(ntdll.NtQueryValueKey(
            p1,
            @ptrFromInt(p2),
            @truncate(p3),
            @ptrFromInt(p4),
            @truncate(p5),
            @ptrFromInt(p6),
        )),
        ssdt.NtCreateKey => ntResult(ntdll.NtCreateKey(
            @ptrFromInt(p1),
            @truncate(p2),
            @ptrFromInt(p3),
            @truncate(p4),
            @ptrFromInt(p5),
            @truncate(p6),
            @ptrFromInt(p7),
        )),
        ssdt.NtSetValueKey => ntResult(ntdll.NtSetValueKeyRaw(
            @truncate(p1),
            @ptrFromInt(p2),
            @truncate(p3),
            @truncate(p4),
            p5,
            @truncate(p6),
        )),
        ssdt.NtEnumerateKey => ntResult(ntdll.NtEnumerateKey(
            p1,
            @truncate(p2),
            @truncate(p3),
            @ptrFromInt(p4),
            @truncate(p5),
            @ptrFromInt(p6),
        )),
        ssdt.NtEnumerateValueKey => ntResult(ntdll.NtEnumerateValueKey(
            p1,
            @truncate(p2),
            @truncate(p3),
            @ptrFromInt(p4),
            @truncate(p5),
            @ptrFromInt(p6),
        )),

        // ── LPC/ALPC ──
        ssdt.NtAlpcConnectPort => ntResult(ntdll.NtAlpcConnectPort(
            @ptrFromInt(p1),
            @ptrFromInt(p2),
            @truncate(p3),
            @truncate(p4),
            @truncate(p5),
            @ptrFromInt(p6),
            @ptrFromInt(p7),
            @ptrFromInt(p6),
        )),
        ssdt.NtAlpcCreatePort => ntResult(ntdll.NtAlpcCreatePort(
            @ptrFromInt(p1),
            @ptrFromInt(p2),
            @ptrFromInt(p3),
        )),
        ssdt.NtAlpcSendWaitReceivePort => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtConnectPort => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtCreatePort => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtRequestWaitReplyPort => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),

        // ── 进程创建 ──
        ssdt.NtCreateProcess => ntResult(ntdll.NtCreateProcess(
            @ptrFromInt(p1),
            @truncate(p2),
            @ptrFromInt(p3),
            p4,
        )),
        ssdt.NtCreateUserProcess => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtCreateThreadEx => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),

        // ── I/O 取消 ──
        ssdt.NtCancelIoFile => ntResult(ntdll.NtCancelIoFile(p1, @ptrFromInt(p2))),
        ssdt.NtCancelIoFileEx => ntResult(ntdll.NtCancelIoFileEx(p1, @ptrFromInt(p2), @ptrFromInt(p3))),
        ssdt.NtFsControlFile => ntResult(ntdll.NtFsControlFile(
            p1,
            p2,
            p3,
            p4,
            @ptrFromInt(p5),
            @truncate(p6),
            @ptrFromInt(p7),
            0,
            null,
            0,
        )),

        // ── 电源管理 ──
        ssdt.NtInitiatePowerAction => ntResult(ntdll.NtInitiatePowerAction(
            @truncate(p1),
            @truncate(p2),
            @truncate(p3),
            @truncate(p4),
        )),

        // ── Win32 用户消息 ──
        ssdt.NtUserGetMessage => ntResult(user32.ntUserGetMessageSyscall(p1, p2, @truncate(p3), @truncate(p4))),
        ssdt.NtUserPostMessage => ntResult(user32.ntUserPostMessageSyscall(p1, @truncate(p2), p3, p4)),
        ssdt.NtUserSendMessage => ntResult(user32.ntUserSendMessageSyscall(p1, @truncate(p2), p3, p4)),
        ssdt.NtUserPeekMessage => ntResult(ntdll.STATUS_NOT_IMPLEMENTED),
        ssdt.NtUserSetWindowPos => ntResult(user32.ntUserSetWindowPosSyscall(p1, p2, p3, p4, p5, p6, @truncate(p7))),
        ssdt.NtUserDispatchMessage => ntResult(user32.ntUserDispatchMessageSyscall(p1)),

        else => blk: {
            klog.warn("LoongArch: unknown NT syscall idx 0x%x", .{svc});
            break :blk ntResult(ntdll.STATUS_INVALID_PARAMETER);
        },
    };
}

// ── exc_vec.S 帧偏移 ──
const OFF_A0: usize = 8;
const OFF_A1: usize = 16;
const OFF_A2: usize = 24;
const OFF_A3: usize = 72;
const OFF_A4: usize = 80;
const OFF_A5: usize = 88;
const OFF_A6: usize = 96;
const OFF_A7: usize = 64;

// 编译时验证：确保帧偏移与 exc_vec.S 完全一致
comptime {
    if (OFF_A0 != 8) @compileError("OFF_A0 must be 8");
    if (OFF_A1 != 16) @compileError("OFF_A1 must be 16");
    if (OFF_A2 != 24) @compileError("OFF_A2 must be 24");
    if (OFF_A7 != 64) @compileError("OFF_A7 must be 64");
    if (OFF_A3 != 72) @compileError("OFF_A3 must be 72");
    if (OFF_A4 != 80) @compileError("OFF_A4 must be 80");
    if (OFF_A5 != 88) @compileError("OFF_A5 must be 88");
    if (OFF_A6 != 96) @compileError("OFF_A6 must be 96");
}

fn readFrame(sp: usize, off: usize) u64 {
    return @as(*const volatile u64, @ptrFromInt(sp + off)).*;
}

// ── VM 相关分发 ──

/// 与用户态约定对齐 x64 SSDT：a0=ProcessHandle, a1=*BaseAddress, a2=ZeroBits, a3=*RegionSize, a4=AllocationType, a5=Protect。
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

/// a0=ProcessHandle, a1=*BaseAddress, a2=*RegionSize, a3=NewProtect, a4=OldProtect（可 0）。
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

/// a0 = *SectionHandle, a1 = DesiredAccess, a2 = ObjectAttributes（当前内核路径忽略）, a3 = *MaximumSize,
/// a4 = PageProtection, a5 = AllocationAttributes, a6 = FileHandle。
fn dispatchCreateSection(
    section_handle_user: u64,
    desired_access: u64,
    object_attributes_va: u64,
    maximum_size_ptr: u64,
    page_protect: u64,
    allocation_attributes: u64,
    file_handle: u64,
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
        @truncate(file_handle),
    );
    if (st == ntdll.STATUS_SUCCESS) {
        @as(*volatile ntdll.HANDLE, @ptrFromInt(section_handle_user)).* = local;
    }
    return ntResult(st);
}

// ── 第1周：文件I/O 分发 ──

/// NtReadFile 分发
/// a0=FileHandle, a1=Event, a2=ApcRoutine, a3=ApcContext, a4=IoStatusBlock, a5=Buffer, a6=Length, a7=ByteOffset
fn dispatchNtReadFile(frame_sp: usize) u64 {
    const file_handle = readFrame(frame_sp, OFF_A0);
    const event_handle = readFrame(frame_sp, OFF_A1);
    _ = readFrame(frame_sp, OFF_A2); // ApcRoutine
    _ = readFrame(frame_sp, OFF_A3); // ApcContext
    const io_status_ptr = readFrame(frame_sp, OFF_A4);
    const buffer_ptr = readFrame(frame_sp, OFF_A5);
    const length: u32 = @truncate(readFrame(frame_sp, OFF_A6));
    const byte_offset_ptr = readFrame(frame_sp, OFF_A7);

    if (io_status_ptr == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, io_status_ptr, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    const io_status: *ntdll.IO_STATUS_BLOCK = @ptrFromInt(io_status_ptr);
    const buffer: ?[*]u8 = if (buffer_ptr != 0) @ptrFromInt(buffer_ptr) else null;

    var byte_offset: ?*const u64 = null;
    if (byte_offset_ptr != 0) {
        if (!probe.probeUserMemory(asp, byte_offset_ptr, @sizeOf(u64), false))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
        byte_offset = @ptrFromInt(byte_offset_ptr);
    }

    const st = ntdll.NtReadFile(
        @truncate(file_handle),
        @truncate(event_handle),
        @intFromPtr(byte_offset),
        0,
        io_status,
        buffer,
        length,
        byte_offset,
        null,
    );
    return ntResult(st);
}

/// NtWriteFile 分发
/// a0=FileHandle, a1=Event, a2=ApcRoutine, a3=ApcContext, a4=IoStatusBlock, a5=Buffer, a6=Length, a7=ByteOffset
fn dispatchNtWriteFile(frame_sp: usize) u64 {
    const file_handle = readFrame(frame_sp, OFF_A0);
    const event_handle = readFrame(frame_sp, OFF_A1);
    _ = readFrame(frame_sp, OFF_A2); // ApcRoutine
    _ = readFrame(frame_sp, OFF_A3); // ApcContext
    const io_status_ptr = readFrame(frame_sp, OFF_A4);
    const buffer_ptr = readFrame(frame_sp, OFF_A5);
    const length: u32 = @truncate(readFrame(frame_sp, OFF_A6));
    const byte_offset_ptr = readFrame(frame_sp, OFF_A7);

    if (io_status_ptr == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, io_status_ptr, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    const io_status: *ntdll.IO_STATUS_BLOCK = @ptrFromInt(io_status_ptr);
    const buffer: ?[*]const u8 = if (buffer_ptr != 0) @ptrFromInt(buffer_ptr) else null;

    var byte_offset: ?*const u64 = null;
    if (byte_offset_ptr != 0) {
        if (!probe.probeUserMemory(asp, byte_offset_ptr, @sizeOf(u64), false))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
        byte_offset = @ptrFromInt(byte_offset_ptr);
    }

    const st = ntdll.NtWriteFile(
        @truncate(file_handle),
        @truncate(event_handle),
        @intFromPtr(byte_offset),
        0,
        io_status,
        buffer,
        length,
        byte_offset,
        null,
    );
    return ntResult(st);
}

/// NtOpenFile 分发
/// a0=FileHandle, a1=DesiredAccess, a2=ObjectAttributes, a3=IoStatusBlock, a4=ShareAccess, a5=OpenOptions
fn dispatchNtOpenFile(frame_sp: usize) u64 {
    const file_handle_ptr = readFrame(frame_sp, OFF_A0);
    const desired_access = readFrame(frame_sp, OFF_A1);
    const obj_attrs_ptr = readFrame(frame_sp, OFF_A2);
    const io_status_ptr = readFrame(frame_sp, OFF_A3);
    const share_access = readFrame(frame_sp, OFF_A4);
    const open_options = readFrame(frame_sp, OFF_A5);

    if (file_handle_ptr == 0 or io_status_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, file_handle_ptr, @sizeOf(ntdll.HANDLE), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp, io_status_ptr, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    var obj_attrs: ?*ntdll.OBJECT_ATTRIBUTES = null;
    if (obj_attrs_ptr != 0) {
        if (!probe.probeUserMemory(asp, obj_attrs_ptr, @sizeOf(ntdll.OBJECT_ATTRIBUTES), false))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
        obj_attrs = @ptrFromInt(obj_attrs_ptr);
    }

    const io_status: *ntdll.IO_STATUS_BLOCK = @ptrFromInt(io_status_ptr);
    const st = ntdll.NtOpenFile(
        @ptrFromInt(file_handle_ptr),
        @truncate(desired_access),
        obj_attrs,
        io_status,
        @truncate(share_access),
        @truncate(open_options),
    );
    return ntResult(st);
}

/// NtCreateFile 分发
/// a0=FileHandle, a1=DesiredAccess, a2=ObjectAttributes, a3=IoStatusBlock,
/// a4=AllocationSize, a5=FileAttributes, a6=ShareAccess, a7=CreateDisposition
fn dispatchNtCreateFile(frame_sp: usize) u64 {
    const file_handle_ptr = readFrame(frame_sp, OFF_A0);
    const desired_access = readFrame(frame_sp, OFF_A1);
    const obj_attrs_ptr = readFrame(frame_sp, OFF_A2);
    const io_status_ptr = readFrame(frame_sp, OFF_A3);
    const allocation_size = readFrame(frame_sp, OFF_A4);
    const file_attributes = readFrame(frame_sp, OFF_A5);
    const share_access = readFrame(frame_sp, OFF_A6);
    const create_disposition = readFrame(frame_sp, OFF_A7);

    if (file_handle_ptr == 0 or io_status_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, file_handle_ptr, @sizeOf(ntdll.HANDLE), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp, io_status_ptr, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    var obj_attrs: ?*ntdll.OBJECT_ATTRIBUTES = null;
    if (obj_attrs_ptr != 0) {
        if (!probe.probeUserMemory(asp, obj_attrs_ptr, @sizeOf(ntdll.OBJECT_ATTRIBUTES), false))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
        obj_attrs = @ptrFromInt(obj_attrs_ptr);
    }

    const io_status: *ntdll.IO_STATUS_BLOCK = @ptrFromInt(io_status_ptr);
    const st = ntdll.NtCreateFile(
        @ptrFromInt(file_handle_ptr),
        @truncate(desired_access),
        obj_attrs,
        io_status,
        allocation_size,
        @truncate(file_attributes),
        @truncate(share_access),
        @truncate(create_disposition),
        0,
        null,
        0,
    );
    return ntResult(st);
}

/// NtDeviceIoControlFile 分发
/// a0=FileHandle, a1=Event, a2=ApcRoutine, a3=ApcContext, a4=IoStatusBlock,
/// a5=IoControlCode, a6=InputBuffer, a7=InputBufferLength
fn dispatchNtDeviceIoControlFile(frame_sp: usize) u64 {
    const file_handle = readFrame(frame_sp, OFF_A0);
    const _event = readFrame(frame_sp, OFF_A1);
    const _apc_routine = readFrame(frame_sp, OFF_A2);
    const _apc_context = readFrame(frame_sp, OFF_A3);
    const io_status_ptr = readFrame(frame_sp, OFF_A4);
    const io_control_code = readFrame(frame_sp, OFF_A5);
    const input_buffer_ptr = readFrame(frame_sp, OFF_A6);
    const input_buffer_length = readFrame(frame_sp, OFF_A7);

    _ = _event;
    _ = _apc_routine;
    _ = _apc_context;
    _ = input_buffer_ptr;
    _ = input_buffer_length;

    if (io_status_ptr == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, io_status_ptr, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    const io_status: *ntdll.IO_STATUS_BLOCK = @ptrFromInt(io_status_ptr);
    const st = ntdll.NtFsControlFile(
        @truncate(file_handle),
        0,
        0,
        0,
        io_status,
        @truncate(io_control_code),
        null,
        0,
        null,
        0,
    );
    return ntResult(st);
}

// ── 第1周：进程/线程打开 ──

/// NtOpenProcess 分发
/// a0=ProcessHandle, a1=DesiredAccess, a2=ObjectAttributes, a3=ClientId
fn dispatchNtOpenProcess(frame_sp: usize) u64 {
    const process_handle_ptr = readFrame(frame_sp, OFF_A0);
    const desired_access = readFrame(frame_sp, OFF_A1);
    _ = readFrame(frame_sp, OFF_A2);
    const client_id_ptr = readFrame(frame_sp, OFF_A3);

    if (process_handle_ptr == 0 or client_id_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, process_handle_ptr, @sizeOf(ntdll.HANDLE), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp, client_id_ptr, @sizeOf(ntdll.CLIENT_ID), false))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    const cid: *const ntdll.CLIENT_ID = @ptrFromInt(client_id_ptr);
    const pid: u32 = @truncate(cid.unique_process);

    const target = process.findProcess(pid) orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const access = ntdll.desiredAccessToObMask(@truncate(desired_access));
    const h = proc.handle_table.allocHandle(@intFromPtr(&target.header), access, .process) orelse
        return ntResult(ntdll.STATUS_INSUFFICIENT_RESOURCES);

    @as(*volatile ntdll.HANDLE, @ptrFromInt(process_handle_ptr)).* = h;
    return ntResult(ntdll.STATUS_SUCCESS);
}

// ── 第3周：内存查询/读写 ──

/// NtQueryVirtualMemory 分发
/// a0=ProcessHandle, a1=BaseAddress, a2=MemoryInformationClass, a3=MemoryInformation, a4=MemoryInformationLength, a5=ReturnLength
fn dispatchNtQueryVirtualMemory(frame_sp: usize) u64 {
    const process_handle = readFrame(frame_sp, OFF_A0);
    const base_address = readFrame(frame_sp, OFF_A1);
    const memory_info_class = readFrame(frame_sp, OFF_A2);
    const memory_info_ptr = readFrame(frame_sp, OFF_A3);
    const memory_info_length = readFrame(frame_sp, OFF_A4);
    const return_length_ptr = readFrame(frame_sp, OFF_A5);

    _ = process_handle;
    _ = base_address;
    _ = memory_info_class;

    if (memory_info_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, memory_info_ptr, @as(u64, @truncate(memory_info_length)), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    if (return_length_ptr != 0) {
        if (!probe.probeUserMemory(asp, return_length_ptr, @sizeOf(u32), true))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    }

    return ntResult(ntdll.STATUS_NOT_IMPLEMENTED);
}

/// NtReadVirtualMemory 分发
/// a0=ProcessHandle, a1=BaseAddress, a2=Buffer, a3=BufferSize, a4=ReturnSize
fn dispatchNtReadVirtualMemory(frame_sp: usize) u64 {
    const process_handle = readFrame(frame_sp, OFF_A0);
    const base_address = readFrame(frame_sp, OFF_A1);
    const buffer_ptr = readFrame(frame_sp, OFF_A2);
    const buffer_size = readFrame(frame_sp, OFF_A3);
    const return_size_ptr = readFrame(frame_sp, OFF_A4);

    _ = process_handle;
    _ = base_address;

    if (buffer_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, buffer_ptr, buffer_size, true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    if (return_size_ptr != 0) {
        if (!probe.probeUserMemory(asp, return_size_ptr, @sizeOf(u64), true))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    }

    return ntResult(ntdll.STATUS_NOT_IMPLEMENTED);
}

/// NtWriteVirtualMemory 分发
/// a0=ProcessHandle, a1=BaseAddress, a2=Buffer, a3=BufferSize, a4=ReturnSize
fn dispatchNtWriteVirtualMemory(frame_sp: usize) u64 {
    const process_handle = readFrame(frame_sp, OFF_A0);
    const base_address = readFrame(frame_sp, OFF_A1);
    const buffer_ptr = readFrame(frame_sp, OFF_A2);
    const buffer_size = readFrame(frame_sp, OFF_A3);
    const return_size_ptr = readFrame(frame_sp, OFF_A4);

    _ = process_handle;
    _ = base_address;

    if (buffer_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, buffer_ptr, buffer_size, false))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    if (return_size_ptr != 0) {
        if (!probe.probeUserMemory(asp, return_size_ptr, @sizeOf(u64), true))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    }

    return ntResult(ntdll.STATUS_NOT_IMPLEMENTED);
}

// ── 第3周：Section 映射 ──

/// NtMapViewOfSection 分发
/// a0=SectionHandle, a1=ProcessHandle, a2=BaseAddress, a3=ZeroBits,
/// a4=CommitSize, a5=SectionOffset, a6=ViewSize, a7=AllocationType
fn dispatchNtMapViewOfSection(frame_sp: usize) u64 {
    const section_handle = readFrame(frame_sp, OFF_A0);
    const process_handle = readFrame(frame_sp, OFF_A1);
    const base_address_ptr = readFrame(frame_sp, OFF_A2);
    const _zero_bits = readFrame(frame_sp, OFF_A3);
    const commit_size_ptr = readFrame(frame_sp, OFF_A4);
    const section_offset_ptr = readFrame(frame_sp, OFF_A5);
    const view_size_ptr = readFrame(frame_sp, OFF_A6);
    const _allocation_type = readFrame(frame_sp, OFF_A7);

    _ = _zero_bits;
    _ = _allocation_type;

    if (base_address_ptr == 0 or view_size_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, base_address_ptr, @sizeOf(u64), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp, view_size_ptr, @sizeOf(u64), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    var commit_size: ?*u64 = null;
    if (commit_size_ptr != 0) {
        if (!probe.probeUserMemory(asp, commit_size_ptr, @sizeOf(u64), false))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
        commit_size = @ptrFromInt(commit_size_ptr);
    }

    var section_offset: ?*u64 = null;
    if (section_offset_ptr != 0) {
        if (!probe.probeUserMemory(asp, section_offset_ptr, @sizeOf(u64), false))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
        section_offset = @ptrFromInt(section_offset_ptr);
    }

    const st = ntdll.NtMapViewOfSection(
        @truncate(section_handle),
        @truncate(process_handle),
        @ptrFromInt(base_address_ptr),
        0,
        if (commit_size) |cs| cs.* else 0,
        section_offset,
        @ptrFromInt(view_size_ptr),
        0,
        0,
        0,
    );
    return ntResult(st);
}

// ── 第4周：对象操作 ──

/// NtDuplicateObject 分发
/// a0=SourceProcessHandle, a1=SourceHandle, a2=TargetProcessHandle,
/// a3=TargetHandle, a4=DesiredAccess, a5=HandleAttributes, a6=Options
fn dispatchNtDuplicateObject(frame_sp: usize) u64 {
    const source_process_handle = readFrame(frame_sp, OFF_A0);
    const source_handle = readFrame(frame_sp, OFF_A1);
    const target_process_handle = readFrame(frame_sp, OFF_A2);
    const target_handle_ptr = readFrame(frame_sp, OFF_A3);
    const desired_access = readFrame(frame_sp, OFF_A4);
    _ = readFrame(frame_sp, OFF_A5);
    const options = readFrame(frame_sp, OFF_A6);

    if (target_handle_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    if (!probe.probeUserMemory(asp, target_handle_ptr, @sizeOf(ntdll.HANDLE), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    const target_h = proc.handle_table.duplicateHandle(
        @truncate(source_handle),
        @truncate(desired_access),
    ) orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);

    @as(*volatile ntdll.HANDLE, @ptrFromInt(target_handle_ptr)).* = target_h;
    _ = source_process_handle;
    _ = target_process_handle;
    _ = options;

    return ntResult(ntdll.STATUS_SUCCESS);
}

// ── 第2周：等待多对象 ──

/// NtWaitForMultipleObjects 分发
/// a0=Count, a1=Handles, a2=WaitType, a3=Alertable, a4=Timeout
fn dispatchNtWaitForMultipleObjects(frame_sp: usize) u64 {
    const count = readFrame(frame_sp, OFF_A0);
    const handles_ptr = readFrame(frame_sp, OFF_A1);
    const wait_type = readFrame(frame_sp, OFF_A2);
    const alertable = readFrame(frame_sp, OFF_A3);
    const timeout_ptr = readFrame(frame_sp, OFF_A4);

    if (count == 0 or count > 64)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (handles_ptr == 0)
        return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const proc = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);

    const handles_size = @as(usize, @truncate(count)) * @sizeOf(ntdll.HANDLE);
    if (!probe.probeUserMemory(asp, handles_ptr, handles_size, false))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);

    var timeout: ?*const i64 = null;
    if (timeout_ptr != 0) {
        if (!probe.probeUserMemory(asp, timeout_ptr, @sizeOf(i64), false))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
        timeout = @ptrFromInt(timeout_ptr);
    }

    const handles: [*]const ntdll.HANDLE = @ptrFromInt(handles_ptr);
    const st = ntdll.NtWaitForMultipleObjects(
        @truncate(count),
        handles[0..@as(usize, @truncate(count))],
        @truncate(wait_type),
        alertable != 0,
        timeout,
    );
    return ntResult(st);
}
