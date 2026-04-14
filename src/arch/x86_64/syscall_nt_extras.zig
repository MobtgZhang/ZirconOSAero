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
// Module: src/arch/x86_64/syscall_nt_extras.zig
// Purpose: 可扩展 syscall 子模块 — I/O 读写、LPC 请求/应答、句柄复制（与 `syscall.zig` 主分发器分离）。
//
// Ref: learn.microsoft.com — `NtReadFile`, `NtWriteFile`, `NtDeviceIoControlFile`, `NtRequestWaitReplyPort`, `NtDuplicateObject` 参数与 `IO_STATUS_BLOCK`。
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K7

const process = @import("../../ps/process.zig");
const probe = @import("../../mm/probe.zig");
const vm = @import("../../mm/vm.zig");
const ntdll = @import("../../libs/ntdll.zig");
const ipc = @import("../../lpc/ipc.zig");
const syscall_abi = @import("syscall_abi.zig");
const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;

/// `NtReadFile`：R10=FileHandle, RDX=Event, R8=ApcRoutine, R9=ApcContext；栈：IoStatusBlock, Buffer, Length, ByteOffset, Key。
pub fn dispatchNtReadFile(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);

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
    if (!probe.probeUserMemory(asp, io_user, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp, buf_user, length, true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const off_ptr: ?*const u64 = if (byte_off == 0) null else blk: {
        if (!probe.probeUserMemory(asp, byte_off, @sizeOf(u64), false))
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

/// `NtDeviceIoControlFile`：R10..R9 同 `NtReadFile`；栈：IoStatusBlock, IoControlCode, InputBuffer, InputBufferLength, OutputBuffer, OutputBufferLength。
pub fn dispatchNtDeviceIoControlFile(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);

    const io_user = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const ioctl_code = syscall_abi.userStackArg(frame, 1) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const in_buf = syscall_abi.userStackArg(frame, 2) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const in_len32 = syscall_abi.userStackArg(frame, 3) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const out_buf = syscall_abi.userStackArg(frame, 4) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const out_len32 = syscall_abi.userStackArg(frame, 5) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    if (io_user == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp, io_user, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    const in_len: u32 = @truncate(in_len32);
    const out_len: u32 = @truncate(out_len32);
    if (in_len > 0 and in_buf == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (in_len > 0 and !probe.probeUserMemory(asp, in_buf, in_len, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (out_len > 0 and out_buf == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (out_len > 0 and !probe.probeUserMemory(asp, out_buf, out_len, true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    var ios_local: ntdll.IO_STATUS_BLOCK = undefined;
    const st = ntdll.NtDeviceIoControlFile(
        frame.r10,
        frame.rdx,
        frame.r8,
        frame.r9,
        &ios_local,
        @truncate(ioctl_code),
        if (in_buf == 0) null else @ptrFromInt(in_buf),
        in_len,
        if (out_buf == 0) null else @ptrFromInt(out_buf),
        out_len,
    );
    @as(*volatile ntdll.IO_STATUS_BLOCK, @ptrFromInt(io_user)).* = ios_local;
    return syscall_abi.ntStatusAsI64(st);
}

/// `NtWriteFile`：寄存器约定同 `NtReadFile`。
pub fn dispatchNtWriteFile(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);

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
    if (!probe.probeUserMemory(asp, io_user, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp, buf_user, length, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const off_ptr: ?*const u64 = if (byte_off == 0) null else blk: {
        if (!probe.probeUserMemory(asp, byte_off, @sizeOf(u64), false))
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
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const reply_va = frame.r9;
    if (reply_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp, reply_va, @sizeOf(ipc.Message), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    const data_va = frame.r8;
    const data_opt: ?*const [ipc.MSG_DATA_SIZE]u8 = if (data_va == 0) null else blk: {
        if (!probe.probeUserMemory(asp, data_va, ipc.MSG_DATA_SIZE, false))
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
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const target_h_va = frame.r9;
    if (target_h_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp, target_h_va, @sizeOf(ntdll.HANDLE), true))
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

/// `NtOpenFile`：R10=FileHandle*，RDX=DesiredAccess，R8=ObjectAttributes*，R9=IoStatusBlock*；栈：ShareAccess, OpenOptions。
pub fn dispatchNtOpenFile(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const fh = frame.r10;
    const io = frame.r9;
    if (fh == 0 or io == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp, fh, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp, io, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const oa = frame.r8;
    if (oa != 0 and !probe.probeUserMemory(asp, oa, 64, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const share = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const open_opts = syscall_abi.userStackArg(frame, 1) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    var local: ntdll.HANDLE = 0;
    var ios: ntdll.IO_STATUS_BLOCK = undefined;
    const st = ntdll.NtOpenFile(
        &local,
        @truncate(frame.rdx),
        if (oa == 0) null else @ptrFromInt(oa),
        &ios,
        @truncate(share),
        @truncate(open_opts),
    );
    @as(*volatile ntdll.IO_STATUS_BLOCK, @ptrFromInt(io)).* = ios;
    if (st != ntdll.STATUS_SUCCESS) return syscall_abi.ntStatusAsI64(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(fh)).* = local;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_SUCCESS);
}

/// `NtQueryInformationProcess`：第 5 参 `ReturnLength` 在用户栈 +0x28。
pub fn dispatchNtQueryInformationProcess(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const rl_va = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const len: u32 = @truncate(frame.r9);
    const buf = frame.r8;
    if (buf != 0 and len > 0 and !probe.probeUserMemory(asp, buf, len, true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (rl_va != 0 and !probe.probeUserMemory(asp, rl_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtQueryInformationProcess(
        frame.r10,
        @truncate(frame.rdx),
        if (buf == 0) null else @ptrFromInt(buf),
        len,
        if (rl_va == 0) null else @ptrFromInt(rl_va),
    );
    return syscall_abi.ntStatusAsI64(st);
}

pub fn dispatchNtSetInformationProcess(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const len: u32 = @truncate(frame.r9);
    const buf = frame.r8;
    if (buf != 0 and len > 0 and !probe.probeUserMemory(asp, buf, @as(u64, len), false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtSetInformationProcess(
        frame.r10,
        @truncate(frame.rdx),
        if (buf == 0) null else @ptrFromInt(buf),
        len,
    );
    return syscall_abi.ntStatusAsI64(st);
}

pub fn dispatchNtQueryInformationThread(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const rl_va = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const len: u32 = @truncate(frame.r9);
    const buf = frame.r8;
    if (buf != 0 and len > 0 and !probe.probeUserMemory(asp, buf, @as(u64, len), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (rl_va != 0 and !probe.probeUserMemory(asp, rl_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtQueryInformationThread(
        frame.r10,
        @truncate(frame.rdx),
        if (buf == 0) null else @ptrFromInt(buf),
        len,
        if (rl_va == 0) null else @ptrFromInt(rl_va),
    );
    return syscall_abi.ntStatusAsI64(st);
}

pub fn dispatchNtSetInformationThread(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const len: u32 = @truncate(frame.r9);
    const buf = frame.r8;
    if (buf != 0 and len > 0 and !probe.probeUserMemory(asp, buf, @as(u64, len), false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtSetInformationThread(
        frame.r10,
        @truncate(frame.rdx),
        if (buf == 0) null else @ptrFromInt(buf),
        len,
    );
    return syscall_abi.ntStatusAsI64(st);
}

pub fn dispatchNtResumeThread(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const prev_va = frame.rdx;
    if (prev_va != 0 and !probe.probeUserMemory(asp, prev_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtResumeThread(
        frame.r10,
        if (prev_va == 0) null else @ptrFromInt(prev_va),
    );
    return syscall_abi.ntStatusAsI64(st);
}

pub fn dispatchNtSuspendThread(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const prev_va = frame.rdx;
    if (prev_va != 0 and !probe.probeUserMemory(asp, prev_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtSuspendThread(
        frame.r10,
        if (prev_va == 0) null else @ptrFromInt(prev_va),
    );
    return syscall_abi.ntStatusAsI64(st);
}

pub fn dispatchNtAlertThread(frame: *InterruptFrame) i64 {
    return syscall_abi.ntStatusAsI64(ntdll.NtAlertThread(frame.r10));
}

pub fn dispatchNtTestAlert(_: *InterruptFrame) i64 {
    return syscall_abi.ntStatusAsI64(ntdll.NtTestAlert());
}

pub fn dispatchNtCreateProcess(frame: *InterruptFrame) i64 {
    const proc_c = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_c = proc_c.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const ph = frame.r10;
    if (ph == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_c, ph, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    _ = syscall_abi.userStackArg(frame, 0);
    _ = syscall_abi.userStackArg(frame, 1);
    _ = syscall_abi.userStackArg(frame, 2);
    _ = syscall_abi.userStackArg(frame, 3);
    const oa = frame.r8;
    if (oa != 0 and !probe.probeUserMemory(asp_c, oa, 64, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtCreateProcess(
        &local,
        @truncate(frame.rdx),
        if (oa == 0) null else @ptrFromInt(oa),
        frame.r9,
    );
    if (st != ntdll.STATUS_SUCCESS) return syscall_abi.ntStatusAsI64(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(ph)).* = local;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_SUCCESS);
}

pub fn dispatchNtWaitForMultipleObjects(frame: *InterruptFrame) i64 {
    const proc_w = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_w = proc_w.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const count: u32 = @truncate(frame.r10);
    const handles_va = frame.rdx;
    if (count == 0 or count > 64) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    const sz = @as(usize, count) * @sizeOf(ntdll.HANDLE);
    if (!probe.probeUserMemory(asp_w, handles_va, sz, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const timeout_va = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const timeout_ptr: ?*const i64 = if (timeout_va == 0) null else blk: {
        if (!probe.probeUserMemory(asp_w, timeout_va, @sizeOf(i64), false))
            return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
        break :blk @ptrFromInt(timeout_va);
    };
    var handles_copy: [64]ntdll.HANDLE = undefined;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        handles_copy[i] = @as(*const volatile ntdll.HANDLE, @ptrFromInt(handles_va + @as(u64, i) * 8)).*;
    }
    const st = ntdll.NtWaitForMultipleObjects(
        count,
        handles_copy[0..count],
        @truncate(frame.r8),
        frame.r9 != 0,
        timeout_ptr,
    );
    return syscall_abi.ntStatusAsI64(st);
}

pub fn dispatchNtSetInformationObject(frame: *InterruptFrame) i64 {
    const proc_o = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_o = proc_o.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const len: u32 = @truncate(frame.r9);
    const buf = frame.r8;
    if (buf != 0 and len > 0 and !probe.probeUserMemory(asp_o, buf, @as(u64, len), false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtSetInformationObject(
        frame.r10,
        @truncate(frame.rdx),
        if (buf == 0) null else @ptrFromInt(buf),
        len,
    );
    return syscall_abi.ntStatusAsI64(st);
}

pub fn dispatchNtSignalAndWaitForSingleObject(frame: *InterruptFrame) i64 {
    const proc_s = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_s = proc_s.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const timeout_va = frame.r9;
    const timeout_ptr: ?*const i64 = if (timeout_va == 0) null else blk: {
        if (!probe.probeUserMemory(asp_s, timeout_va, @sizeOf(i64), false))
            return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
        break :blk @ptrFromInt(timeout_va);
    };
    const st = ntdll.NtSignalAndWaitForSingleObject(
        frame.r10,
        frame.rdx,
        @truncate(frame.r8),
        timeout_ptr,
    );
    return syscall_abi.ntStatusAsI64(st);
}

pub fn dispatchNtCreateMutant(frame: *InterruptFrame) i64 {
    return dispatchCreateHandleSyscall(frame, ntdll.NtCreateMutant);
}

pub fn dispatchNtOpenMutant(frame: *InterruptFrame) i64 {
    return dispatchOpenHandleSyscall3(frame, ntdll.NtOpenMutant);
}

pub fn dispatchNtReleaseMutant(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const prev_va = frame.rdx;
    if (prev_va != 0 and !probe.probeUserMemory(asp, prev_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtReleaseMutant(
        frame.r10,
        if (prev_va == 0) null else @ptrFromInt(prev_va),
    ));
}

pub fn dispatchNtQueryMutant(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const len: u32 = @truncate(frame.r9);
    const buf = frame.r8;
    const rl_va = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (buf != 0 and len > 0 and !probe.probeUserMemory(asp, buf, @as(u64, len), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (rl_va != 0 and !probe.probeUserMemory(asp, rl_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtQueryMutant(
        frame.r10,
        @truncate(frame.rdx),
        if (buf == 0) null else @ptrFromInt(buf),
        len,
        if (rl_va == 0) null else @ptrFromInt(rl_va),
    ));
}

fn dispatchCreateHandleSyscall(
    frame: *InterruptFrame,
    comptime callee: *const fn (*ntdll.HANDLE, u32, ?*ntdll.OBJECT_ATTRIBUTES, bool) ntdll.NTSTATUS,
) i64 {
    const proc_h = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_h = proc_h.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const out_va = frame.r10;
    if (out_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_h, out_va, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const oa = frame.r8;
    if (oa != 0 and !probe.probeUserMemory(asp_h, oa, 64, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    var local: ntdll.HANDLE = 0;
    const st = callee(
        &local,
        @truncate(frame.rdx),
        if (oa == 0) null else @ptrFromInt(oa),
        frame.r9 != 0,
    );
    if (st != ntdll.STATUS_SUCCESS) return syscall_abi.ntStatusAsI64(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(out_va)).* = local;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_SUCCESS);
}

fn dispatchOpenHandleSyscall3(
    frame: *InterruptFrame,
    comptime callee: *const fn (*ntdll.HANDLE, u32, ?*ntdll.OBJECT_ATTRIBUTES) ntdll.NTSTATUS,
) i64 {
    const proc_h = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_h = proc_h.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const out_va = frame.r10;
    if (out_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_h, out_va, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const oa = frame.r8;
    if (oa == 0 or !probe.probeUserMemory(asp_h, oa, 64, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    var local: ntdll.HANDLE = 0;
    const st = callee(&local, @truncate(frame.rdx), @ptrFromInt(oa));
    if (st != ntdll.STATUS_SUCCESS) return syscall_abi.ntStatusAsI64(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(out_va)).* = local;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_SUCCESS);
}

pub fn dispatchNtCreateSemaphore(frame: *InterruptFrame) i64 {
    const proc_h = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_h = proc_h.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const out_va = frame.r10;
    if (out_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_h, out_va, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const oa = frame.r8;
    if (oa != 0 and !probe.probeUserMemory(asp_h, oa, 64, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const init_count = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const max_count = syscall_abi.userStackArg(frame, 1) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtCreateSemaphore(
        &local,
        @truncate(frame.rdx),
        if (oa == 0) null else @ptrFromInt(oa),
        @as(i32, @bitCast(@as(u32, @truncate(init_count)))),
        @as(i32, @bitCast(@as(u32, @truncate(max_count)))),
    );
    if (st != ntdll.STATUS_SUCCESS) return syscall_abi.ntStatusAsI64(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(out_va)).* = local;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_SUCCESS);
}

pub fn dispatchNtOpenSemaphore(frame: *InterruptFrame) i64 {
    return dispatchOpenHandleSyscall3(frame, ntdll.NtOpenSemaphore);
}

pub fn dispatchNtReleaseSemaphore(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const prev_va = frame.r8;
    if (prev_va != 0 and !probe.probeUserMemory(asp, prev_va, @sizeOf(i32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtReleaseSemaphore(
        frame.r10,
        @as(i32, @bitCast(@as(u32, @truncate(frame.rdx)))),
        if (prev_va == 0) null else @ptrFromInt(prev_va),
    ));
}

pub fn dispatchNtCreateEvent(frame: *InterruptFrame) i64 {
    const proc_h = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_h = proc_h.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const out_va = frame.r10;
    if (out_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_h, out_va, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const oa = frame.r8;
    if (oa != 0 and !probe.probeUserMemory(asp_h, oa, 64, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const initial_va = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const initial = initial_va != 0;
    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtCreateEvent(
        &local,
        @truncate(frame.rdx),
        if (oa == 0) null else @ptrFromInt(oa),
        @truncate(frame.r9),
        initial,
    );
    if (st != ntdll.STATUS_SUCCESS) return syscall_abi.ntStatusAsI64(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(out_va)).* = local;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_SUCCESS);
}

pub fn dispatchNtOpenEvent(frame: *InterruptFrame) i64 {
    return dispatchOpenHandleSyscall3(frame, ntdll.NtOpenEvent);
}

pub fn dispatchNtSetEvent(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const prev_va = frame.rdx;
    if (prev_va != 0 and !probe.probeUserMemory(asp, prev_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtSetEvent(
        frame.r10,
        if (prev_va == 0) null else @ptrFromInt(prev_va),
    ));
}

pub fn dispatchNtResetEvent(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const prev_va = frame.rdx;
    if (prev_va != 0 and !probe.probeUserMemory(asp, prev_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtResetEvent(
        frame.r10,
        if (prev_va == 0) null else @ptrFromInt(prev_va),
    ));
}

pub fn dispatchNtPulseEvent(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const prev_va = frame.rdx;
    if (prev_va != 0 and !probe.probeUserMemory(asp, prev_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtPulseEvent(
        frame.r10,
        if (prev_va == 0) null else @ptrFromInt(prev_va),
    ));
}

pub fn dispatchNtClearEvent(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const prev_va = frame.rdx;
    if (prev_va != 0 and !probe.probeUserMemory(asp, prev_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtClearEvent(
        frame.r10,
        if (prev_va == 0) null else @ptrFromInt(prev_va),
    ));
}

pub fn dispatchNtOpenThread(frame: *InterruptFrame) i64 {
    const proc_h = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_h = proc_h.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const out_va = frame.r10;
    if (out_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_h, out_va, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    const oa = frame.r8;
    if (oa == 0 or !probe.probeUserMemory(asp_h, oa, 64, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    const cid = frame.r9;
    if (cid == 0 or !probe.probeUserMemory(asp_h, cid, 16, false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtOpenThread(&local, @truncate(frame.rdx), @ptrFromInt(oa), @ptrFromInt(cid));
    if (st != ntdll.STATUS_SUCCESS) return syscall_abi.ntStatusAsI64(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(out_va)).* = local;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_SUCCESS);
}

pub fn dispatchNtQueryObject(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const len: u32 = @truncate(frame.r9);
    const buf = frame.r8;
    const rl_va = syscall_abi.userStackArg(frame, 0) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (buf != 0 and len > 0 and !probe.probeUserMemory(asp, buf, @as(u64, len), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (rl_va != 0 and !probe.probeUserMemory(asp, rl_va, @sizeOf(u32), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtQueryObject(
        frame.r10,
        @truncate(frame.rdx),
        if (buf == 0) null else @ptrFromInt(buf),
        len,
        if (rl_va == 0) null else @ptrFromInt(rl_va),
    ));
}

pub fn dispatchNtFlushBuffersFile(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const io_va = frame.rdx;
    if (io_va == 0)
        return syscall_abi.ntStatusAsI64(ntdll.NtFlushBuffersFile(frame.r10, null));
    if (!probe.probeUserMemory(asp, io_va, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtFlushBuffersFile(frame.r10, @ptrFromInt(io_va)));
}

pub fn dispatchNtFsControlFile(frame: *InterruptFrame) i64 {
    _ = frame;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_NOT_IMPLEMENTED);
}

pub fn dispatchNtCancelIoFile(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const io_va = frame.rdx;
    if (io_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp, io_va, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtCancelIoFile(frame.r10, @ptrFromInt(io_va)));
}

pub fn dispatchNtCancelIoFileEx(frame: *InterruptFrame) i64 {
    const proc = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp = proc.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const cancel_req_va = frame.rdx;
    const io_va = frame.r8;
    if (io_va == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp, io_va, @sizeOf(ntdll.IO_STATUS_BLOCK), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (cancel_req_va != 0 and !probe.probeUserMemory(asp, cancel_req_va, @sizeOf(u64), false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    return syscall_abi.ntStatusAsI64(ntdll.NtCancelIoFileEx(
        frame.r10,
        if (cancel_req_va == 0) null else @ptrFromInt(cancel_req_va),
        @ptrFromInt(io_va),
    ));
}

/// 本仓库 **ZOA 子集 ABI**（非完整 Win7 `NtCreateUserProcess` 栈帧）：`R10` 指向用户区该结构。
/// 字段与 [docs/cn/PHASE_F_PROCESS_CREATE.md](../../../docs/cn/PHASE_F_PROCESS_CREATE.md)、[syscall_abi.zig](syscall_abi.zig) 文档一致。
pub const ZirconCreateUserProcessArgs = extern struct {
    image_path_unicode: u64,
    process_handle_out: u64,
    thread_handle_out: u64,
    creation_flags: u32,
    reserved: u32 = 0,
};

fn readUnicodePathToBuf(asp: *vm.AddressSpace, unicode_str_va: u64, out: []u8) ?[]const u8 {
    if (unicode_str_va == 0) return null;
    if (!probe.probeUserUnicodeString(asp, unicode_str_va, false)) return null;
    const us = @as(*const volatile extern struct {
        Length: u16,
        MaximumLength: u16,
        Buffer: u64,
    }, @ptrFromInt(unicode_str_va));
    const byte_len = us.Length;
    if (byte_len < 2) return null;
    const wchar_count = @as(usize, @intCast(byte_len)) / 2;
    if (wchar_count == 0 or wchar_count > out.len) return null;
    if (us.Buffer == 0) return null;
    var j: usize = 0;
    var i: usize = 0;
    while (i < wchar_count) : (i += 1) {
        const ch = @as(*const volatile u16, @ptrFromInt(us.Buffer + i * 2)).*;
        out[j] = if (ch < 128) @truncate(ch) else '?';
        j += 1;
    }
    return out[0..j];
}

/// SSDT **0xAA**：`R10` = `ZirconCreateUserProcessArgs*`（已 probe）。
pub fn dispatchNtCreateUserProcess(frame: *InterruptFrame) i64 {
    const proc_c = process.getCurrentProcess() orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const asp_c = proc_c.address_space orelse return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_HANDLE);
    const args_va = frame.r10;
    if (args_va == 0 or (args_va & 7) != 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_c, args_va, @sizeOf(ZirconCreateUserProcessArgs), false))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    const args = @as(*const volatile ZirconCreateUserProcessArgs, @ptrFromInt(args_va)).*;
    if (args.process_handle_out == 0) return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_c, args.process_handle_out, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);
    if (args.thread_handle_out != 0 and !probe.probeUserMemory(asp_c, args.thread_handle_out, @sizeOf(ntdll.HANDLE), true))
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_ACCESS_VIOLATION);

    var path_buf: [512]u8 = undefined;
    const path = readUnicodePathToBuf(asp_c, args.image_path_unicode, &path_buf) orelse
        return syscall_abi.ntStatusAsI64(ntdll.STATUS_INVALID_PARAMETER);

    const frame_alloc = @import("../../mm/frame.zig").kernelFrameAllocatorPtr();
    var out_proc: ntdll.HANDLE = undefined;
    var out_thr: ntdll.HANDLE = undefined;
    const st = ntdll.NtCreateUserProcessFromPath(
        proc_c,
        frame_alloc,
        path,
        &out_proc,
        if (args.thread_handle_out == 0) null else &out_thr,
    );
    if (st != ntdll.STATUS_SUCCESS) return syscall_abi.ntStatusAsI64(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(args.process_handle_out)).* = out_proc;
    if (args.thread_handle_out != 0) {
        @as(*volatile ntdll.HANDLE, @ptrFromInt(args.thread_handle_out)).* = out_thr;
    }
    _ = args.creation_flags;
    _ = args.reserved;
    return syscall_abi.ntStatusAsI64(ntdll.STATUS_SUCCESS);
}
