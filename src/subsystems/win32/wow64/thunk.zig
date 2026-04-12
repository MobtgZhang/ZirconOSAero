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
const marshal = @import("marshal.zig");
const win32k = @import("win32k_thunk.zig");

pub var total_syscall_translations: u64 = 0;
pub var total_ptr_conversions: u64 = 0;

pub const userVaFromWow64Ptr32 = marshal.userVaFromWow64Ptr32;

pub fn translateSyscall32to64(wow_proc: *types .Wow64Process, syscall_num: u32) ntdll.NTSTATUS {
    return translateSyscall32to64WithArgs(wow_proc, syscall_num, &[_]u32{});
}

/// 带 stdcall 实参（u32 槽，按形参从左到右对应 `args[0]..`）的 32→64 翻译；供 `marshal` 与演示路径使用。
pub fn translateSyscall32to64WithArgs(wow_proc: *types .Wow64Process, syscall_num: u32, args: []const u32) ntdll.NTSTATUS {
    wow_proc.syscall_count += 1;
    total_syscall_translations += 1;

    // 检查是否为 Win32k 服务，如果是则分派到 win32k thunk
    if (win32k.isWin32kServiceIndex(syscall_num)) {
        wow_proc.last_x64_ssdt_alias = null;
        return win32k.dispatchWin32kSyscall(wow_proc, syscall_num, args);
    }

    wow_proc.last_x64_ssdt_alias = x64_alias.x64SsdtIndexForWin7Sp1X86(syscall_num);

    if (!x86.wow64SyscallStubReturnsSuccess(syscall_num)) {
        return ntdll.STATUS_NOT_IMPLEMENTED;
    }
    return marshal.dispatchWow64Stub(wow_proc, syscall_num, args);
}

pub fn convertPtr32to64(ptr32: u32) u64 {
    total_ptr_conversions += 1;
    if (ptr32 == 0) return 0;
    if (ptr32 > types.WOW64_MAX_ADDR) return 0;
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
