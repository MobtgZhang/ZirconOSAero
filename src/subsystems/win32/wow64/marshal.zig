// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/marshal.zig
// Purpose: WOW64 32 位 stdcall 实参 → 内核 `ntdll` x64 桩的封送（可测子集）；**非**完整 SysWOW64。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/cpp/cpp/stdcall （stdcall 栈序概念）；[docs/cn/PHASE_G_WOW64.md](../../../../docs/cn/PHASE_G_WOW64.md)

const types = @import("types.zig");
const ntdll = @import("../../../libs/ntdll.zig");
const x86 = @import("ssdt_x86_win7_sp1.zig");

/// 用户态 32 位 VA 扩为 64 位；超出 WOW64 用户范围则 `null`（调用方应返回 `STATUS_INVALID_PARAMETER`）。
/// 与 `thunk.convertPtr32to64` 成对使用：此处显式可空便于 probe 失败路径。
pub fn userVaFromWow64Ptr32(ptr32: u32) ?u64 {
    if (ptr32 == 0) return @as(u64, 0);
    if (ptr32 > types.WOW64_MAX_ADDR) return null;
    return @as(u64, ptr32);
}

/// 32 位 ntdll 常用 native 调用在 stdcall 下自右向左压栈，此处 `args[0]` 为 **栈上第一个实参**（最左形参）。
/// 未列出的服务在 stub 命中时仍返回 `STATUS_SUCCESS`（演示兼容），与阶段 G 前行为一致。
pub fn dispatchWow64Stub(wow: *types.Wow64Process, syscall_num: u32, args: []const u32) ntdll.NTSTATUS {
    _ = wow;
    if (syscall_num == x86.NtClose) {
        if (args.len == 0) return ntdll.STATUS_SUCCESS;
        return ntdll.NtClose(@as(u64, args[0]));
    }
    if (syscall_num == x86.NtWaitForSingleObject) {
        if (args.len < 3) return ntdll.STATUS_SUCCESS;
        const h = @as(u64, args[0]);
        const alertable = args[1] != 0;
        const to32 = args[2];
        const timeout_ptr: ?*const i64 = if (to32 == 0) null else tp: {
            const va = userVaFromWow64Ptr32(to32) orelse return ntdll.STATUS_INVALID_PARAMETER;
            break :tp @ptrFromInt(va);
        };
        return ntdll.NtWaitForSingleObject(h, alertable, timeout_ptr);
    }
    if (syscall_num == x86.NtTerminateProcess) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const h = @as(u64, args[0]);
        const exit_st: ntdll.NTSTATUS = @bitCast(args[1]);
        return ntdll.NtTerminateProcess(h, exit_st);
    }
    if (syscall_num == x86.NtDelayExecution) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const alert: u8 = @truncate(args[0]);
        const p32 = args[1];
        if (p32 == 0) return ntdll.STATUS_INVALID_PARAMETER;
        const va = userVaFromWow64Ptr32(p32) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const interval = @as(*const volatile i64, @ptrFromInt(va)).*;
        return ntdll.NtDelayExecution(alert, interval);
    }
    if (syscall_num == x86.NtAllocateVirtualMemory) {
        if (args.len < 6) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        const p_base = args[1];
        const zb = @as(u64, args[2]);
        const p_sz = args[3];
        const vb = userVaFromWow64Ptr32(p_base) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const vs = userVaFromWow64Ptr32(p_sz) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var base_u: u64 = @as(u64, @as(*align(1) const volatile u32, @ptrFromInt(vb)).*);
        var sz_u: u64 = @as(u64, @as(*align(1) const volatile u32, @ptrFromInt(vs)).*);
        const st = ntdll.NtAllocateVirtualMemory(proc_h, &base_u, zb, &sz_u, args[4], args[5]);
        @as(*align(1) volatile u32, @ptrFromInt(vb)).* = @truncate(base_u);
        @as(*align(1) volatile u32, @ptrFromInt(vs)).* = @truncate(sz_u);
        return st;
    }
    if (syscall_num == x86.NtFreeVirtualMemory) {
        if (args.len < 4) return ntdll.STATUS_SUCCESS;
        const vb = userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const vs = userVaFromWow64Ptr32(args[2]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var base_u: u64 = @as(u64, @as(*align(1) const volatile u32, @ptrFromInt(vb)).*);
        var sz_u: u64 = @as(u64, @as(*align(1) const volatile u32, @ptrFromInt(vs)).*);
        const st = ntdll.NtFreeVirtualMemory(@as(u64, args[0]), &base_u, &sz_u, args[3]);
        @as(*align(1) volatile u32, @ptrFromInt(vb)).* = @truncate(base_u);
        @as(*align(1) volatile u32, @ptrFromInt(vs)).* = @truncate(sz_u);
        return st;
    }
    if (syscall_num == x86.NtDuplicateObject) {
        if (args.len < 7) return ntdll.STATUS_SUCCESS;
        const vt = userVaFromWow64Ptr32(args[3]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var new_h: ntdll.HANDLE = undefined;
        const st = ntdll.NtDuplicateObject(
            @as(u64, args[0]),
            @as(u64, args[1]),
            @as(u64, args[2]),
            &new_h,
            args[4],
            args[5],
            args[6],
        );
        @as(*align(1) volatile u32, @ptrFromInt(vt)).* = @truncate(new_h);
        return st;
    }
    if (syscall_num == x86.NtReadFile) {
        if (args.len < 7) return ntdll.STATUS_SUCCESS;
        const ios_va = userVaFromWow64Ptr32(args[4]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const buf_va = userVaFromWow64Ptr32(args[5]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var iob: ntdll.IO_STATUS_BLOCK = .{};
        const st = ntdll.NtReadFile(
            @as(u64, args[0]),
            0,
            0,
            0,
            &iob,
            @ptrFromInt(buf_va),
            args[6],
            null,
            null,
        );
        @as(*align(1) volatile ntdll.IO_STATUS_BLOCK, @ptrFromInt(ios_va)).* = iob;
        return st;
    }
    if (syscall_num == x86.NtProtectVirtualMemory) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const vb = userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const vs = userVaFromWow64Ptr32(args[2]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const vo = userVaFromWow64Ptr32(args[4]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var base_u: u64 = @as(u64, @as(*align(1) const volatile u32, @ptrFromInt(vb)).*);
        var sz_u: u64 = @as(u64, @as(*align(1) const volatile u32, @ptrFromInt(vs)).*);
        var old: u32 = 0;
        const st = ntdll.NtProtectVirtualMemory(@as(u64, args[0]), &base_u, &sz_u, args[3], &old);
        @as(*align(1) volatile u32, @ptrFromInt(vb)).* = @truncate(base_u);
        @as(*align(1) volatile u32, @ptrFromInt(vs)).* = @truncate(sz_u);
        @as(*align(1) volatile u32, @ptrFromInt(vo)).* = old;
        return st;
    }
    if (syscall_num == x86.NtWriteFile) {
        if (args.len < 7) return ntdll.STATUS_SUCCESS;
        const ios_va = userVaFromWow64Ptr32(args[4]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const buf_va = userVaFromWow64Ptr32(args[5]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var iob: ntdll.IO_STATUS_BLOCK = .{};
        const st = ntdll.NtWriteFile(
            @as(u64, args[0]),
            0,
            0,
            0,
            &iob,
            @ptrFromInt(buf_va),
            args[6],
            null,
            null,
        );
        @as(*align(1) volatile ntdll.IO_STATUS_BLOCK, @ptrFromInt(ios_va)).* = iob;
        return st;
    }
    return ntdll.STATUS_SUCCESS;
}
