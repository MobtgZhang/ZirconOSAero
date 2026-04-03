// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/thunk.zig
// Purpose: 32→64 系统调用号映射与指针/句柄扩宽；服务号子集与 `ssdt_x86_win7_sp1.zig`（公开 Win7 SP1 x86 表）对齐。
//
// This is an independent clean-room implementation.
// Ref: https://github.com/j00ru/windows-syscalls (x86 vs x64 namespace); [docs/cn/NT61_CONTRACT_MATRIX.md](../../../../docs/cn/NT61_CONTRACT_MATRIX.md) §9.1、[PHASE_G_WOW64.md](../../../../docs/cn/PHASE_G_WOW64.md)

const types = @import("types.zig");
const ntdll = @import("../../../libs/ntdll.zig");
const x86 = @import("ssdt_x86_win7_sp1.zig");
const x64_alias = @import("x64_semantic_alias.zig");

pub var total_syscall_translations: u64 = 0;
pub var total_ptr_conversions: u64 = 0;

pub fn translateSyscall32to64(wow_proc: *types.Wow64Process, syscall_num: u32) ntdll.NTSTATUS {
    wow_proc.syscall_count += 1;
    total_syscall_translations += 1;

    wow_proc.last_x64_ssdt_alias = x64_alias.x64SsdtIndexForWin7Sp1X86(syscall_num);

    // 阶段 4：`NtConnectPort` / `NtRequestWaitReplyPort` 与 csrss、DWM 监听 LPC 同族；索引见 `ssdt_x86_win7_sp1.zig`。
    // G2：在返回演示成功前写入 `last_x64_ssdt_alias`，供主机测与后续接 x64 分发器使用（仍非完整 SysWOW64 封送）。
    if (x86.wow64SyscallStubReturnsSuccess(syscall_num)) {
        return ntdll.STATUS_SUCCESS;
    }
    return ntdll.STATUS_NOT_IMPLEMENTED;
}

pub fn convertPtr32to64(ptr32: u32) u64 {
    total_ptr_conversions += 1;
    if (ptr32 == 0) return 0;
    return @as(u64, ptr32);
}

pub fn convertPtr64to32(ptr64: u64) u32 {
    total_ptr_conversions += 1;
    if (ptr64 > types.WOW64_MAX_ADDR) return 0;
    return @intCast(ptr64 & 0xFFFFFFFF);
}

pub fn convertHandle32to64(handle32: u32) u64 {
    return @as(u64, handle32);
}

pub fn convertHandle64to32(handle64: u64) u32 {
    return @intCast(handle64 & 0xFFFFFFFF);
}
