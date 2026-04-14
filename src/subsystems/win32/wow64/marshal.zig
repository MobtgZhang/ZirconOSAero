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

    // ── 扩展 syscall 封送 ─────────────────────────────────────────────

    if (syscall_num == x86.NtQueryInformationProcess) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        const info_class = args[1];
        const buf32 = args[2];
        const buf_len = args[3];
        const ret_len32 = if (args.len > 4) args[4] else 0;

        const buf_va = userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var actual_len: u32 = 0;
        const st = ntdll.NtQueryInformationProcess(
            proc_h, info_class, @ptrFromInt(buf_va), buf_len, &actual_len,
        );
        if (ret_len32 != 0) {
            const ret_va = userVaFromWow64Ptr32(ret_len32) orelse return ntdll.STATUS_INVALID_PARAMETER;
            @as(*volatile u32, @ptrFromInt(ret_va)).* = actual_len;
        }
        return st;
    }

    if (syscall_num == x86.NtQueryInformationThread) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const thread_h = @as(u64, args[0]);
        const info_class = args[1];
        const buf32 = args[2];
        const buf_len = args[3];
        const ret_len32 = if (args.len > 4) args[4] else 0;

        const buf_va = userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var actual_len: u32 = 0;
        const st = ntdll.NtQueryInformationThread(
            thread_h, info_class, @ptrFromInt(buf_va), buf_len, &actual_len,
        );
        if (ret_len32 != 0) {
            const ret_va = userVaFromWow64Ptr32(ret_len32) orelse return ntdll.STATUS_INVALID_PARAMETER;
            @as(*volatile u32, @ptrFromInt(ret_va)).* = actual_len;
        }
        return st;
    }

    if (syscall_num == x86.NtQuerySystemInformation) {
        if (args.len < 4) return ntdll.STATUS_SUCCESS;
        const info_class = args[0];
        const buf32 = args[1];
        const buf_len = args[2];
        const ret_len32 = if (args.len > 3) args[3] else 0;

        const buf_va = userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var actual_len: u32 = 0;
        const st = ntdll.NtQuerySystemInformation(
            info_class,
            @as([*]u8, @ptrFromInt(buf_va))[0..buf_len],
            &actual_len,
        );
        if (ret_len32 != 0) {
            const ret_va = userVaFromWow64Ptr32(ret_len32) orelse return ntdll.STATUS_INVALID_PARAMETER;
            @as(*volatile u32, @ptrFromInt(ret_va)).* = actual_len;
        }
        return st;
    }

    if (syscall_num == x86.NtReadVirtualMemory) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        const base_addr32 = args[1]; // 已是32位VA，无需转换
        const buf32 = args[2];
        const size = args[3];

        const buf_va = userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var bytes_read: usize = 0;
        const st = ntdll.NtReadVirtualMemory(
            proc_h, @as(u64, base_addr32), @as([*]u8, @ptrFromInt(buf_va)), size, &bytes_read,
        );
        if (args.len > 4 and args[4] != 0) {
            const out_va = userVaFromWow64Ptr32(args[4]) orelse return ntdll.STATUS_INVALID_PARAMETER;
            @as(*volatile u32, @ptrFromInt(out_va)).* = @truncate(bytes_read);
        }
        return st;
    }

    if (syscall_num == x86.NtWriteVirtualMemory) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        const base_addr32 = args[1];
        const buf32 = args[2];
        const size = args[3];

        const buf_va = userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER;
        var bytes_written: usize = 0;
        const st = ntdll.NtWriteVirtualMemory(
            proc_h, @as(u64, base_addr32), @as([*]const u8, @ptrFromInt(buf_va)), size, &bytes_written,
        );
        if (args.len > 4 and args[4] != 0) {
            const out_va = userVaFromWow64Ptr32(args[4]) orelse return ntdll.STATUS_INVALID_PARAMETER;
            @as(*volatile u32, @ptrFromInt(out_va)).* = @truncate(bytes_written);
        }
        return st;
    }

    if (syscall_num == x86.NtQueryVirtualMemory) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        const base_addr32 = args[1];
        const info_class = args[2];
        const buf32 = args[3];
        const buf_len = args[4];

        const buf_va = userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER;
        return ntdll.NtQueryVirtualMemory(
            proc_h, @as(u64, base_addr32), info_class, @ptrFromInt(buf_va), buf_len, null,
        );
    }

    if (syscall_num == x86.NtCreateSection) {
        if (args.len < 8) return ntdll.STATUS_SUCCESS;
        const desired_access = args[1];
        const obj_attrs_ptr32 = args[2];
        const page_attribs = args[5];
        const section_attribs = args[6];
        const file_h = @as(u64, args[7]);

        var section_h: ntdll.HANDLE = 0;
        const oa = if (obj_attrs_ptr32 != 0)
            @as(?*ntdll.OBJECT_ATTRIBUTES, @ptrFromInt(userVaFromWow64Ptr32(obj_attrs_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER))
        else null;

        return ntdll.NtCreateSection(&section_h, desired_access, oa, null, page_attribs, section_attribs, file_h);
    }

    if (syscall_num == x86.NtMapViewOfSection) {
        if (args.len < 8) return ntdll.STATUS_SUCCESS;
        const section_h = @as(u64, args[0]);
        const proc_h = @as(u64, args[1]);
        const base_ptr32 = userVaFromWow64Ptr32(args[2]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const zero_bits = args[3];
        const commit_size = args[4];
        const section_offset_ptr32 = if (args[5] != 0) userVaFromWow64Ptr32(args[5]) else null;
        const view_size_ptr32 = userVaFromWow64Ptr32(args[6]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const inherit = args[7];

        var base_u64: u64 = @as(*const volatile u64, @ptrFromInt(base_ptr32)).*;
        if (section_offset_ptr32) |off_ptr| {
            _ = @as(*const volatile u64, @ptrFromInt(off_ptr)).*; // 忽略section offset
        }
        const vs_val = @as(*const volatile u64, @ptrFromInt(view_size_ptr32)).*;
        var vs_ptr: u64 = vs_val;

        const st = ntdll.NtMapViewOfSection(section_h, proc_h, &base_u64, zero_bits, commit_size, null, &vs_ptr, inherit, 0, 0);
        @as(*volatile u64, @ptrFromInt(base_ptr32)).* = base_u64;
        @as(*volatile u64, @ptrFromInt(view_size_ptr32)).* = vs_ptr;
        return st;
    }

    if (syscall_num == x86.NtUnmapViewOfSection) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        const base_addr32 = args[1];
        return ntdll.NtUnmapViewOfSection(proc_h, @as(u64, base_addr32));
    }

    if (syscall_num == x86.NtOpenProcess) {
        if (args.len < 4) return ntdll.STATUS_SUCCESS;
        const proc_h_ptr = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const desired_access = args[1];
        const obj_attrs_ptr32 = args[2];
        const client_id_ptr = @as(?*ntdll.CLIENT_ID, @ptrFromInt(userVaFromWow64Ptr32(args[3]) orelse return ntdll.STATUS_INVALID_PARAMETER));

        var new_h: ntdll.HANDLE = 0;
        const oa = if (obj_attrs_ptr32 != 0)
            @as(?*ntdll.OBJECT_ATTRIBUTES, @ptrFromInt(userVaFromWow64Ptr32(obj_attrs_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER))
        else null;

        const st = ntdll.NtOpenProcess(&new_h, desired_access, oa, client_id_ptr);
        @as(*volatile ntdll.HANDLE, @ptrFromInt(proc_h_ptr)).* = new_h;
        return st;
    }

    if (syscall_num == x86.NtOpenThread) {
        if (args.len < 4) return ntdll.STATUS_SUCCESS;
        const thread_h_ptr = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const desired_access = args[1];
        const obj_attrs_ptr32 = args[2];
        const client_id_ptr = @as(?*ntdll.CLIENT_ID, @ptrFromInt(userVaFromWow64Ptr32(args[3]) orelse return ntdll.STATUS_INVALID_PARAMETER));

        var new_h: ntdll.HANDLE = 0;
        const oa = if (obj_attrs_ptr32 != 0)
            @as(?*ntdll.OBJECT_ATTRIBUTES, @ptrFromInt(userVaFromWow64Ptr32(obj_attrs_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER))
        else null;

        const st = ntdll.NtOpenThread(&new_h, desired_access, oa, client_id_ptr);
        @as(*volatile ntdll.HANDLE, @ptrFromInt(thread_h_ptr)).* = new_h;
        return st;
    }

    if (syscall_num == x86.NtOpenFile) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const file_h_ptr = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const desired_access = args[1];
        const obj_attrs_ptr32 = args[2];
        const ios_ptr32 = userVaFromWow64Ptr32(args[3]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const options = args[4];

        var new_h: ntdll.HANDLE = 0;
        const oa = if (obj_attrs_ptr32 != 0)
            @as(?*ntdll.OBJECT_ATTRIBUTES, @ptrFromInt(userVaFromWow64Ptr32(obj_attrs_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER))
        else null;
        var ios: ntdll.IO_STATUS_BLOCK = .{};

        const st = ntdll.NtOpenFile(&new_h, desired_access, oa, &ios, options, 0);
        @as(*volatile ntdll.HANDLE, @ptrFromInt(file_h_ptr)).* = new_h;
        @as(*volatile ntdll.IO_STATUS_BLOCK, @ptrFromInt(ios_ptr32)).* = ios;
        return st;
    }

    if (syscall_num == x86.NtCreateFile) {
        if (args.len < 6) return ntdll.STATUS_SUCCESS;
        const file_h_ptr = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const desired_access = args[1];
        const obj_attrs_ptr32 = args[2];
        const ios_ptr32 = userVaFromWow64Ptr32(args[3]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const alloc_size = args[4];
        const file_attribs = args[5];
        const create_disp = args[6];
        const create_opts = args[7];

        var new_h: ntdll.HANDLE = 0;
        const oa = if (obj_attrs_ptr32 != 0)
            @as(?*ntdll.OBJECT_ATTRIBUTES, @ptrFromInt(userVaFromWow64Ptr32(obj_attrs_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER))
        else null;
        var ios: ntdll.IO_STATUS_BLOCK = .{};

        const st = ntdll.NtCreateFile(&new_h, desired_access, oa, &ios, @as(u64, alloc_size), file_attribs, 0, create_disp, create_opts, null, 0);
        @as(*volatile ntdll.HANDLE, @ptrFromInt(file_h_ptr)).* = new_h;
        @as(*volatile ntdll.IO_STATUS_BLOCK, @ptrFromInt(ios_ptr32)).* = ios;
        return st;
    }

    if (syscall_num == x86.NtCreateEvent) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const event_h_ptr = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const desired_access = args[1];
        const obj_attrs_ptr32 = args[2];
        const event_type = args[3];
        const initial_state = args[4] != 0;

        var new_h: ntdll.HANDLE = 0;
        const oa = if (obj_attrs_ptr32 != 0)
            @as(?*ntdll.OBJECT_ATTRIBUTES, @ptrFromInt(userVaFromWow64Ptr32(obj_attrs_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER))
        else null;

        const st = ntdll.NtCreateEvent(&new_h, desired_access, oa, event_type, initial_state);
        @as(*volatile ntdll.HANDLE, @ptrFromInt(event_h_ptr)).* = new_h;
        return st;
    }

    if (syscall_num == x86.NtSetEvent) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        return ntdll.NtSetEvent(@as(u64, args[0]), null);
    }

    if (syscall_num == x86.NtResetEvent) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        return ntdll.NtResetEvent(@as(u64, args[0]), null);
    }

    if (syscall_num == x86.NtTerminateThread) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const thread_h = @as(u64, args[0]);
        const exit_st: ntdll.NTSTATUS = @bitCast(args[1]);
        return ntdll.NtTerminateThread(thread_h, exit_st);
    }

    if (syscall_num == x86.NtCreateThread) {
        if (args.len < 9) return ntdll.STATUS_SUCCESS;
        const thread_h_ptr = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const desired_access = args[1];
        const obj_attrs_ptr32 = args[2];
        const proc_h = @as(u64, args[3]);
        const client_id_ptr32 = if (args[4] != 0) userVaFromWow64Ptr32(args[4]) else null;
        const context_ptr32 = if (args[5] != 0) userVaFromWow64Ptr32(args[5]) else null;
        const creation_flags = args[8];
        _ = client_id_ptr32;
        _ = context_ptr32;
        _ = creation_flags;

        var new_h: ntdll.HANDLE = 0;
        const oa = if (obj_attrs_ptr32 != 0)
            @as(?*ntdll.OBJECT_ATTRIBUTES, @ptrFromInt(userVaFromWow64Ptr32(obj_attrs_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER))
        else null;

        const st = ntdll.NtCreateThreadFull(&new_h, desired_access, @ptrCast(oa), proc_h, null, 0);
        @as(*volatile ntdll.HANDLE, @ptrFromInt(thread_h_ptr)).* = new_h;
        return st;
    }

    if (syscall_num == x86.NtGetContextThread) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const thread_h = @as(u64, args[0]);
        const ctx_ptr32 = userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        // CONTEXT32→CONTEXT64 转换在上下文同步层处理
        _ = thread_h;
        _ = ctx_ptr32;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtSetContextThread) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const thread_h = @as(u64, args[0]);
        const ctx_ptr32 = userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        _ = thread_h;
        _ = ctx_ptr32;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtFlushInstructionCache) {
        if (args.len < 3) return ntdll.STATUS_SUCCESS;
        // 对于跨架构场景，需要在翻译引擎层面处理指令缓存刷新
        const proc_h = @as(u64, args[0]);
        const base_addr32 = args[1];
        const size = args[2];
        _ = proc_h;
        _ = base_addr32;
        _ = size;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtOpenKey) {
        if (args.len < 3) return ntdll.STATUS_SUCCESS;
        const key_h_ptr = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const desired_access = args[1];
        const obj_attrs_ptr32 = args[2];

        var new_h: ntdll.HANDLE = 0;
        const oa = if (obj_attrs_ptr32 != 0)
            @as(?*ntdll.OBJECT_ATTRIBUTES, @ptrFromInt(userVaFromWow64Ptr32(obj_attrs_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER))
        else null;

        const st = ntdll.NtOpenKey(&new_h, desired_access, oa);
        @as(*volatile ntdll.HANDLE, @ptrFromInt(key_h_ptr)).* = new_h;
        return st;
    }

    if (syscall_num == x86.NtQueryValueKey) {
        if (args.len < 6) return ntdll.STATUS_SUCCESS;
        const key_h = @as(u64, args[0]);
        const value_name_ptr32: ?*const ntdll.UNICODE_STRING = if (args[1] != 0)
            @ptrFromInt(userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER)
        else null;
        const info_class = args[2];
        const buf32 = args[3];
        const buf_len = args[4];
        const ret_len32 = if (args.len > 5) args[5] else 0;

        const buf_va = @as(?*anyopaque, @ptrFromInt(userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER));
        var actual_len: u32 = 0;
        const st = ntdll.NtQueryValueKey(
            key_h, value_name_ptr32, info_class, buf_va, buf_len, &actual_len,
        );
        if (ret_len32 != 0) {
            const ret_va = userVaFromWow64Ptr32(ret_len32) orelse return ntdll.STATUS_INVALID_PARAMETER;
            @as(*volatile u32, @ptrFromInt(ret_va)).* = actual_len;
        }
        return st;
    }

    if (syscall_num == x86.NtSetValueKey) {
        if (args.len < 6) return ntdll.STATUS_SUCCESS;
        const key_h = @as(u64, args[0]);
        const value_name_ptr32: ?*const ntdll.UNICODE_STRING = if (args[1] != 0)
            @ptrFromInt(userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER)
        else null;
        const info_class = args[2];
        const buf32 = args[3];
        const buf_len = args[4];

        const buf_va: u64 = if (buf32 != 0) (userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER) else 0;
        return ntdll.NtSetValueKeyRaw(key_h, value_name_ptr32, info_class, 0, buf_va, buf_len);
    }

    if (syscall_num == x86.NtCreateKey) {
        if (args.len < 7) return ntdll.STATUS_SUCCESS;
        const key_h_ptr = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const desired_access = args[1];
        const obj_attrs_ptr32 = args[2];
        const class_name_ptr32 = if (args[3] != 0) userVaFromWow64Ptr32(args[3]) else null;
        const title_index = args[4];
        const options = args[5];
        const disp_ptr32 = args[6];
        _ = class_name_ptr32; // class name slice conversion not yet implemented

        var new_h: ntdll.HANDLE = 0;
        const oa = if (obj_attrs_ptr32 != 0)
            @as(?*ntdll.OBJECT_ATTRIBUTES, @ptrFromInt(userVaFromWow64Ptr32(obj_attrs_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER))
        else null;
        var disp_out: u32 = 0;

        const st = ntdll.NtCreateKey(&new_h, desired_access, oa, title_index, null, options, &disp_out);
        if (disp_ptr32 != 0) {
            const disp_va = userVaFromWow64Ptr32(disp_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
            @as(*volatile u32, @ptrFromInt(disp_va)).* = disp_out;
        }
        @as(*volatile ntdll.HANDLE, @ptrFromInt(key_h_ptr)).* = new_h;
        return st;
    }

    if (syscall_num == x86.NtEnumerateKey) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const key_h = @as(u64, args[0]);
        const index = args[1];
        const info_class = args[2];
        const buf32 = args[3];
        const buf_len = args[4];

        const buf_va = @as(?*anyopaque, @ptrFromInt(userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER));
        var dummy_len: u32 = 0;
        return ntdll.NtEnumerateKey(key_h, index, info_class, buf_va, buf_len, &dummy_len);
    }

    if (syscall_num == x86.NtEnumerateValueKey) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const key_h = @as(u64, args[0]);
        const index = args[1];
        const info_class = args[2];
        const buf32 = args[3];
        const buf_len = args[4];

        const buf_va = @as(?*anyopaque, @ptrFromInt(userVaFromWow64Ptr32(buf32) orelse return ntdll.STATUS_INVALID_PARAMETER));
        var dummy_len: u32 = 0;
        return ntdll.NtEnumerateValueKey(key_h, index, info_class, buf_va, buf_len, &dummy_len);
    }

    if (syscall_num == x86.NtYieldExecution) {
        return ntdll.NtDelayExecution(0, 0); // 让出时间片
    }

    // ── 扩展 syscall 封送：进程/线程管理 ────────────────────────

    if (syscall_num == x86.NtSuspendThread) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const thread_h = @as(u64, args[0]);
        const prev_suspend_count_ptr32 = if (args[1] != 0) args[1] else 0;
        _ = thread_h;
        if (prev_suspend_count_ptr32 != 0) {
            const va = userVaFromWow64Ptr32(prev_suspend_count_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
            @as(*volatile u32, @ptrFromInt(va)).* = 0;
        }
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtResumeThread) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const thread_h = @as(u64, args[0]);
        const prev_count_ptr32 = if (args[1] != 0) args[1] else 0;
        _ = thread_h;
        if (prev_count_ptr32 != 0) {
            const va = userVaFromWow64Ptr32(prev_count_ptr32) orelse return ntdll.STATUS_INVALID_PARAMETER;
            @as(*volatile u32, @ptrFromInt(va)).* = 1;
        }
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtGetExitCodeProcess) {
        if (args.len < 3) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        const exit_code_ptr32 = userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const ret_len32 = if (args.len > 2 and args[2] != 0) userVaFromWow64Ptr32(args[2]) else null;
        _ = proc_h;
        @as(*volatile u32, @ptrFromInt(exit_code_ptr32)).* = 0;
        if (ret_len32) |va| {
            @as(*volatile u32, @ptrFromInt(va)).* = @sizeOf(u32);
        }
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtGetExitCodeThread) {
        if (args.len < 3) return ntdll.STATUS_SUCCESS;
        const thread_h = @as(u64, args[0]);
        const exit_code_ptr32 = userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const ret_len32 = if (args.len > 2 and args[2] != 0) userVaFromWow64Ptr32(args[2]) else null;
        _ = thread_h;
        @as(*volatile u32, @ptrFromInt(exit_code_ptr32)).* = 0;
        if (ret_len32) |va| {
            @as(*volatile u32, @ptrFromInt(va)).* = @sizeOf(u32);
        }
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtResumeProcess) {
        if (args.len < 1) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        _ = proc_h;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtSuspendProcess) {
        if (args.len < 1) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        _ = proc_h;
        return ntdll.STATUS_SUCCESS;
    }

    // ── 扩展 syscall 封送：内存查询 ──────────────────────────────

    if (syscall_num == x86.NtQueryAllocationAlignment) {
        if (args.len < 1) return ntdll.STATUS_SUCCESS;
        const alignment_ptr32 = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        @as(*volatile u32, @ptrFromInt(alignment_ptr32)).* = 0x10;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtAreMappedFilesTheSame) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtFlushViewOfSection) {
        if (args.len < 3) return ntdll.STATUS_SUCCESS;
        const section_h = @as(u64, args[0]);
        const base_addr32 = args[1];
        const num_bytes32 = args[2];
        _ = section_h;
        _ = base_addr32;
        _ = num_bytes32;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtLockVirtualMemory) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        const base_ptr32 = userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const size_ptr32 = userVaFromWow64Ptr32(args[2]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const access_type = args[3];
        const lock_info_ptr32 = if (args.len > 4 and args[4] != 0) userVaFromWow64Ptr32(args[4]) else null;
        _ = proc_h;
        _ = base_ptr32;
        _ = size_ptr32;
        _ = access_type;
        _ = lock_info_ptr32;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtUnlockVirtualMemory) {
        if (args.len < 4) return ntdll.STATUS_SUCCESS;
        const proc_h = @as(u64, args[0]);
        const base_ptr32 = userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const size_ptr32 = userVaFromWow64Ptr32(args[2]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const access_type = args[3];
        _ = proc_h;
        _ = base_ptr32;
        _ = size_ptr32;
        _ = access_type;
        return ntdll.STATUS_SUCCESS;
    }

    // ── 扩展 syscall 封送：时间/等待 ─────────────────────────

    if (syscall_num == x86.NtQuerySystemTime) {
        if (args.len < 1) return ntdll.STATUS_SUCCESS;
        const time_ptr32 = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        _ = time_ptr32;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtSetSystemTime) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const time32 = args[0];
        const base_time32 = args[1];
        _ = time32;
        _ = base_time32;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtQueryInterruptTime) {
        if (args.len < 1) return ntdll.STATUS_SUCCESS;
        const time_ptr32 = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        @as(*volatile u64, @ptrFromInt(time_ptr32)).* = 0;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtQueryTickCount) {
        if (args.len < 2) return ntdll.STATUS_SUCCESS;
        const count_ptr32 = userVaFromWow64Ptr32(args[0]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const interval_ptr32 = if (args[1] != 0) userVaFromWow64Ptr32(args[1]) else null;
        _ = count_ptr32;
        _ = interval_ptr32;
        return ntdll.STATUS_SUCCESS;
    }

    if (syscall_num == x86.NtWaitForMultipleObjects32) {
        if (args.len < 5) return ntdll.STATUS_SUCCESS;
        const count = args[0];
        const handles_ptr32 = userVaFromWow64Ptr32(args[1]) orelse return ntdll.STATUS_INVALID_PARAMETER;
        const wait_type = args[2];
        const alertable = args[3] != 0;
        const timeout_ptr32 = if (args[4] != 0) userVaFromWow64Ptr32(args[4]) else null;
        _ = count;
        _ = handles_ptr32;
        _ = wait_type;
        _ = alertable;
        _ = timeout_ptr32;
        return ntdll.STATUS_SUCCESS;
    }

    return ntdll.STATUS_SUCCESS;
}

// ── CONTEXT 32↔64 双向转换 ──────────────────────────────────────────

/// CONTEXT32 标志位（与 WOW64 文档公开子集对齐）
pub const CONTEXT32_INTEGER: u32 = 0x00010010;
pub const CONTEXT32_CONTROL: u32 = 0x00010004;
pub const CONTEXT32_SEGMENTS: u32 = 0x00010008;
pub const CONTEXT32_FLOATING_POINT: u32 = 0x00010002;
pub const CONTEXT32_DEBUG_REGISTERS: u32 = 0x00010020;
pub const CONTEXT32_FULL: u32 = CONTEXT32_CONTROL | CONTEXT32_INTEGER;
pub const CONTEXT32_ALL: u32 = CONTEXT32_FULL | CONTEXT32_SEGMENTS | CONTEXT32_FLOATING_POINT;

/// 64位 CONTEXT 结构（简化版，与 NT 6.1 x64 对齐）
pub const CONTEXT64 = extern struct {
    pub const FLAG_MASK: u64 = 0x001F3FFF;

    p1_home: u64 = 0,
    p2_home: u64 = 0,
    p3_home: u64 = 0,
    p4_home: u64 = 0,
    p5_home: u64 = 0,
    p6_home: u64 = 0,

    context_flags: u32 = 0,
    mx_csr: u32 = 0,

    cs: u16 = 0,
    fs: u16 = 0,
    gs: u16 = 0,
    ds: u16 = 0,
    es: u16 = 0,

    rflags: u32 = 0,

    dr0: u64 = 0,
    dr1: u64 = 0,
    dr2: u64 = 0,
    dr3: u64 = 0,
    dr6: u64 = 0,
    dr7: u64 = 0,

    rax: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rbx: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,

    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,

    rip: u64 = 0,

    cs_ext: u16 = 0,
    fs_ext: u16 = 0,
    gs_ext: u16 = 0,
    ds_ext: u16 = 0,
    es_ext: u16 = 0,

    rflags_ext: u32 = 0,

    esp: u32 = 0, // 兼容 32 位
    ss: u16 = 0,
    ss_ext: u16 = 0,

    // 浮点/向量状态
    float_save: [512]u8 = [_]u8{0} ** 512,
};

comptime {
    @import("std").debug.assert(@sizeOf(CONTEXT64) == 792);
}

/// 将 32 位 CONTEXT 转换为 64 位格式
pub fn convertContext32to64(ctx32: *const types.CONTEXT32, ctx64: *CONTEXT64) void {
    @memset(@as([*]u8, @ptrCast(ctx64))[0..@sizeOf(CONTEXT64)], 0);

    ctx64.context_flags = CONTEXT32_FULL | CONTEXT32_DEBUG_REGISTERS;

    // 通用寄存器
    ctx64.rax = ctx32.eax;
    ctx64.rcx = ctx32.ecx;
    ctx64.rdx = ctx32.edx;
    ctx64.rbx = ctx32.ebx;
    ctx64.rsp = ctx32.esp;
    ctx64.rbp = ctx32.ebp;
    ctx64.rsi = ctx32.esi;
    ctx64.rdi = ctx32.edi;

    // 64位扩展寄存器（WOW64 中为 0）
    ctx64.r8 = 0;
    ctx64.r9 = 0;
    ctx64.r10 = 0;
    ctx64.r11 = 0;
    ctx64.r12 = 0;
    ctx64.r13 = 0;
    ctx64.r14 = 0;
    ctx64.r15 = 0;

    // 控制流
    ctx64.rip = ctx32.eip;
    ctx64.rflags = ctx32.eflags;
    ctx64.rsp = ctx32.esp;

    // 段寄存器（WOW64 恒定值）
    ctx64.cs = 0x23;    // 32位用户代码段
    ctx64.ds = 0x23;    // 32位用户数据段
    ctx64.es = 0x23;
    ctx64.fs = 0x3B;    // TEB 段（与 NT 一致）
    ctx64.gs = 0x23;
    ctx64.ss = 0x2B;    // 32位用户栈段

    // 调试寄存器
    ctx64.dr0 = ctx32.dr0;
    ctx64.dr1 = ctx32.dr1;
    ctx64.dr2 = ctx32.dr2;
    ctx64.dr3 = ctx32.dr3;
    ctx64.dr6 = ctx32.dr6;
    ctx64.dr7 = ctx32.dr7;

    // 浮点状态（80 字节 80387 格式）
    @memcpy(ctx64.float_save[0..types.WOW64_SIZE_OF_80387_REGISTERS], &ctx32.float_save);
}

/// 将 64 位 CONTEXT 转换回 32 位格式
pub fn convertContext64to32(ctx64: *const CONTEXT64, ctx32: *types.CONTEXT32) void {
    @memset(@as([*]u8, @ptrCast(ctx32))[0..@sizeOf(types.CONTEXT32)], 0);

    ctx32.context_flags = CONTEXT32_FULL;
    ctx32.eax = @truncate(ctx64.rax);
    ctx32.ecx = @truncate(ctx64.rcx);
    ctx32.edx = @truncate(ctx64.rdx);
    ctx32.ebx = @truncate(ctx64.rbx);
    ctx32.esp = @truncate(ctx64.rsp);
    ctx32.ebp = @truncate(ctx64.rbp);
    ctx32.esi = @truncate(ctx64.rsi);
    ctx32.edi = @truncate(ctx64.rdi);
    ctx32.eip = @truncate(ctx64.rip);
    ctx32.eflags = @truncate(ctx64.rflags);

    ctx32.seg_cs = 0x23;
    ctx32.seg_ss = 0x2B;
    ctx32.seg_ds = 0x23;
    ctx32.seg_es = 0x23;
    ctx32.seg_fs = 0x3B;
    ctx32.seg_gs = 0x23;

    ctx32.dr0 = @truncate(ctx64.dr0);
    ctx32.dr1 = @truncate(ctx64.dr1);
    ctx32.dr2 = @truncate(ctx64.dr2);
    ctx32.dr3 = @truncate(ctx64.dr3);
    ctx32.dr6 = @truncate(ctx64.dr6);
    ctx32.dr7 = @truncate(ctx64.dr7);

    @memcpy(&ctx32.float_save, ctx64.float_save[0..types.WOW64_SIZE_OF_80387_REGISTERS]);
}

/// 检查 CONTEXT32 标志是否表示需要整数寄存器
pub fn context32HasInteger(ctx32: *const types.CONTEXT32) bool {
    return (ctx32.context_flags & CONTEXT32_INTEGER) != 0;
}

/// 检查 CONTEXT32 标志是否表示需要控制寄存器
pub fn context32HasControl(ctx32: *const types.CONTEXT32) bool {
    return (ctx32.context_flags & CONTEXT32_CONTROL) != 0;
}

/// 检查 CONTEXT32 标志是否表示需要调试寄存器
pub fn context32HasDebug(ctx32: *const types.CONTEXT32) bool {
    return (ctx32.context_flags & CONTEXT32_DEBUG_REGISTERS) != 0;
}
