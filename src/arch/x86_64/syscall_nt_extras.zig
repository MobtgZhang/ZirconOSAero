// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/arch/x86_64/syscall_nt_extras.zig
// Purpose: 可扩展 syscall 子模块 — I/O 读写、LPC 请求/应答、句柄复制（与 `syscall.zig` 主分发器分离）。
//
// Ref: learn.microsoft.com — `NtReadFile`, `NtWriteFile`, `NtRequestWaitReplyPort`, `NtDuplicateObject` 参数与 `IO_STATUS_BLOCK`。
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K7

const process = @import("../../ps/process.zig");
const probe = @import("../../mm/probe.zig");
const ntdll = @import("../../libs/ntdll.zig");
const ipc = @import("../../lpc/ipc.zig");
const syscall_abi = @import("syscall_abi.zig");
const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;

/// `NtReadFile`：R10=FileHandle, RDX=Event, R8=ApcRoutine, R9=ApcContext；栈：IoStatusBlock, Buffer, Length, ByteOffset, Key。
pub fn dispatchNtReadFile(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    var asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);

    const io_user = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const buf_user = syscall_abi.userStackArg(frame, 1) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const len32 = syscall_abi.userStackArg(frame, 2) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const byte_off = syscall_abi.userStackArg(frame, 3) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    _ = syscall_abi.userStackArg(frame, 4) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION); // Key

    if (io_user == 0 or buf_user == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    const length: u32 = @truncate(len32);
    if (length == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(&asp, io_user, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(&asp, buf_user, length, true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const off_ptr: ?*const u64 = if (byte_off == 0) null else blk: {
        if (!probe.probeUserMemory(&asp, byte_off, @sizeOf(u64), false))
            return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
        break :blk @ptrFromInt(byte_off);
    };

    var ios_local: ntdll.IO_STATUS_BLOCK = undefined;
    const st = ntdll.NtReadFile(
        frame.r10,
        frame.rdx,
        frame.r8,
        frame.r9,
        &ios_local,
        @ptrFromInt(buf_user),
        length,
        off_ptr,
        null,
    );
    @as(*volatile ntdll.IO_STATUS_BLOCK, @ptrFromInt(io_user)).* = ios_local;
    return syscall_abi.ntStatusAsI64(st);
}

/// `NtWriteFile`：寄存器约定同 `NtReadFile`。
pub fn dispatchNtWriteFile(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    var asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);

    const io_user = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const buf_user = syscall_abi.userStackArg(frame, 1) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const len32 = syscall_abi.userStackArg(frame, 2) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const byte_off = syscall_abi.userStackArg(frame, 3) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    _ = syscall_abi.userStackArg(frame, 4) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    if (io_user == 0 or buf_user == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    const length: u32 = @truncate(len32);
    if (length == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(&asp, io_user, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(&asp, buf_user, length, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const off_ptr: ?*const u64 = if (byte_off == 0) null else blk: {
        if (!probe.probeUserMemory(&asp, byte_off, @sizeOf(u64), false))
            return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
        break :blk @ptrFromInt(byte_off);
    };

    var ios_local: ntdll.IO_STATUS_BLOCK = undefined;
    const st = ntdll.NtWriteFile(
        frame.r10,
        frame.rdx,
        frame.r8,
        frame.r9,
        &ios_local,
        @ptrFromInt(buf_user),
        length,
        off_ptr,
        null,
    );
    @as(*volatile ntdll.IO_STATUS_BLOCK, @ptrFromInt(io_user)).* = ios_local;
    return syscall_abi.ntStatusAsI64(st);
}

/// 本内核简化 ABI：R10=PortHandle，RDX=Opcode，R8=可选发送数据（64 字节）或 0，R9=Reply（`ipc.Message`）用户缓冲区。
pub fn dispatchNtRequestWaitReplyPort(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    var asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const reply_va = frame.r9;
    if (reply_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(&asp, reply_va, @sizeOf(ipc.Message), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    const data_va = frame.r8;
    const data_opt: ?*const [ipc.MSG_DATA_SIZE]u8 = if (data_va == 0) null else blk: {
        if (!probe.probeUserMemory(&asp, data_va, ipc.MSG_DATA_SIZE, false))
            return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
        break :blk @ptrFromInt(data_va);
    };

    var reply_k: ipc.Message = undefined;
    const st = ntdll.NtRequestWaitReplyPort(
        @truncate(frame.r10),
        @truncate(frame.rdx),
        data_opt,
        &reply_k,
    );
    if (st == ntdll.STATUS_SUCCESS) {
        @as(*volatile ipc.Message, @ptrFromInt(reply_va)).* = reply_k;
    }
    return syscall_abi.ntStatusAsI64(st);
}

/// `NtDuplicateObject`：R10=SourceProcess，RDX=SourceHandle，R8=TargetProcess，R9=TargetHandle 指针；栈：DesiredAccess, HandleAttributes, Options。
pub fn dispatchNtDuplicateObject(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    var asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const target_h_va = frame.r9;
    if (target_h_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(&asp, target_h_va, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    const want_access = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const attrs = syscall_abi.userStackArg(frame, 1) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const opts = syscall_abi.userStackArg(frame, 2) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtDuplicateObject(
        frame.r10,
        frame.rdx,
        frame.r8,
        &local,
        @truncate(want_access),
        @truncate(attrs),
        @truncate(opts),
    );
    if (st != ntdll.STATUS_SUCCESS) return syscall_abi.ntStatusAsI64(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(target_h_va)).* = local;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_SUCCESS);
}
