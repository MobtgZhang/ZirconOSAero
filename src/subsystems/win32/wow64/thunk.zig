// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/thunk.zig
// Purpose: 32→64 系统调用号演示映射与指针/句柄扩宽（与 `ssdt_nt61.zig` 真实表不对齐，见 SyscallABI.md）。
//
// This is an independent clean-room implementation.

const types = @import("types.zig");
const ntdll = @import("../../../libs/ntdll.zig");

pub var total_syscall_translations: u64 = 0;
pub var total_ptr_conversions: u64 = 0;

pub fn translateSyscall32to64(wow_proc: *types.Wow64Process, syscall_num: u32) ntdll.NTSTATUS {
    wow_proc.syscall_count += 1;
    total_syscall_translations += 1;

    return switch (syscall_num) {
        0x0001 => ntdll.STATUS_SUCCESS,
        0x0002 => ntdll.STATUS_SUCCESS,
        0x0003 => ntdll.STATUS_SUCCESS,
        0x0004 => ntdll.STATUS_SUCCESS,
        0x0006 => ntdll.STATUS_SUCCESS,
        0x0007 => ntdll.STATUS_SUCCESS,
        0x0008 => ntdll.STATUS_SUCCESS,
        0x0009 => ntdll.STATUS_SUCCESS,
        0x000C => ntdll.STATUS_SUCCESS,
        0x0011 => ntdll.STATUS_SUCCESS,
        0x0012 => ntdll.STATUS_SUCCESS,
        0x0018 => ntdll.STATUS_SUCCESS,
        0x001A => ntdll.STATUS_SUCCESS,
        0x001F => ntdll.STATUS_SUCCESS,
        0x0025 => ntdll.STATUS_SUCCESS,
        0x0036 => ntdll.STATUS_SUCCESS,
        else => ntdll.STATUS_NOT_IMPLEMENTED,
    };
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
