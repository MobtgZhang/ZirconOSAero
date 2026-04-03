// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/arch/x86_64/syscall_dispatch_mm.zig
// Purpose: 虚拟内存与节区相关 SSDT 分发（从 `syscall.zig` 拆出以降低单文件体积）；与 `section.zig` / VAD / CoW 闭环见 K1.6、阶段四 Section syscall 里程碑。
//
// This is an independent clean-room implementation.
// Ref: docs/cn/SyscallABI.md, docs/cn/MM_Section_Roadmap.md

const process = @import("../../ps/process.zig");
const probe = @import("../../mm/probe.zig");
const ntdll = @import("../../libs/ntdll.zig");
const syscall_abi = @import("syscall_abi.zig");
const InterruptFrame = @import("../../ke/interrupt.zig").InterruptFrame;

fn ntResult(s: ntdll.NTSTATUS) i64 {
    return syscall_abi.ntStatusAsI64(s);
}

pub fn dispatchNtAllocateVirtualMemory(frame: *InterruptFrame) i64 {
    const p1 = frame.r10;
    const p2 = frame.rdx;
    const p3 = frame.r8;
    const p4 = frame.r9;
    const a5 = syscall_abi.userStackArg(frame, 0) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const a6 = syscall_abi.userStackArg(frame, 1) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtAllocateVirtualMemory(
        p1,
        @ptrFromInt(p2),
        p3,
        @ptrFromInt(p4),
        @truncate(a5),
        @truncate(a6),
    );
    return ntResult(st);
}

pub fn dispatchNtFreeVirtualMemory(frame: *InterruptFrame) i64 {
    const p1 = frame.r10;
    const p2 = frame.rdx;
    const p3 = frame.r8;
    const p4 = frame.r9;
    const st = ntdll.NtFreeVirtualMemory(
        p1,
        @ptrFromInt(p2),
        @ptrFromInt(p3),
        @truncate(p4),
    );
    return ntResult(st);
}

pub fn dispatchNtProtectVirtualMemory(frame: *InterruptFrame) i64 {
    const p1 = frame.r10;
    const p2 = frame.rdx;
    const p3 = frame.r8;
    const p4 = frame.r9;
    const oldp_slot = syscall_abi.userStackArg(frame, 0) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const proc_pr = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_HANDLE);
    const asp_pr = proc_pr.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (p2 == 0 or p3 == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_pr, p2, 8, true)) return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp_pr, p3, 8, true)) return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    var oldp_opt: ?*u32 = null;
    if (oldp_slot != 0) {
        if (!probe.probeUserMemory(asp_pr, oldp_slot, 4, true)) return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
        oldp_opt = @ptrFromInt(oldp_slot);
    }
    const st = ntdll.NtProtectVirtualMemory(
        p1,
        @ptrFromInt(p2),
        @ptrFromInt(p3),
        @truncate(p4),
        oldp_opt,
    );
    return ntResult(st);
}

pub fn dispatchNtCreateSection(frame: *InterruptFrame) i64 {
    const out_handle = frame.r10;
    const max_sz_ptr = frame.r9;
    if (out_handle == 0 or max_sz_ptr == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const proc_s = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const asp_s = proc_s.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_s, out_handle, @sizeOf(ntdll.HANDLE), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp_s, max_sz_ptr, @sizeOf(u64), false))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const page_prot = syscall_abi.userStackArg(frame, 0) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const alloc_attr = syscall_abi.userStackArg(frame, 1) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const file_handle = syscall_abi.userStackArg(frame, 2) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    var local: ntdll.HANDLE = 0;
    const st = ntdll.NtCreateSection(
        &local,
        @truncate(frame.rdx),
        null,
        @ptrFromInt(max_sz_ptr),
        @truncate(page_prot),
        @truncate(alloc_attr),
        @truncate(file_handle),
    );
    if (st != ntdll.STATUS_SUCCESS) return ntResult(st);
    @as(*volatile ntdll.HANDLE, @ptrFromInt(out_handle)).* = local;
    return 0;
}

pub fn dispatchNtMapViewOfSection(frame: *InterruptFrame) i64 {
    const base_user = frame.r8;
    const view_sz_ptr = syscall_abi.userStackArg(frame, 2) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (base_user == 0) return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const proc_m = process.getCurrentProcess() orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    const asp_m = proc_m.address_space orelse return ntResult(ntdll.STATUS_INVALID_PARAMETER);
    if (!probe.probeUserMemory(asp_m, base_user, @sizeOf(u64), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (!probe.probeUserMemory(asp_m, view_sz_ptr, @sizeOf(u64), true))
        return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const sec_off_stack = syscall_abi.userStackArg(frame, 1) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    if (sec_off_stack != 0) {
        if (!probe.probeUserMemory(asp_m, sec_off_stack, @sizeOf(u64), true))
            return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    }
    const commit_sz = syscall_abi.userStackArg(frame, 0) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const inherit_disp = syscall_abi.userStackArg(frame, 3) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const alloc_type = syscall_abi.userStackArg(frame, 4) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const win_prot = syscall_abi.userStackArg(frame, 5) orelse return ntResult(ntdll.STATUS_ACCESS_VIOLATION);
    const st = ntdll.NtMapViewOfSection(
        @truncate(frame.r10),
        frame.rdx,
        @ptrFromInt(base_user),
        frame.r9,
        commit_sz,
        if (sec_off_stack == 0) null else @ptrFromInt(sec_off_stack),
        @ptrFromInt(view_sz_ptr),
        @truncate(inherit_disp),
        @truncate(alloc_type),
        @truncate(win_prot),
    );
    return ntResult(st);
}

pub fn dispatchNtUnmapViewOfSection(frame: *InterruptFrame) i64 {
    const p1 = frame.r10;
    const p2 = frame.rdx;
    const st = ntdll.NtUnmapViewOfSection(p1, p2);
    return ntResult(st);
}
