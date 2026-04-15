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
// Module: src/subsystems/win32/wow64/x64_semantic_alias.zig
// Purpose: Win7 SP1 **x86 SSDT 服务号** → **x64 SSDT 索引** 的同名 API 对照
//
// This is a placeholder module to fix module import issues.
// Full implementation depends on resolving circular dependencies between modules.

/// Win7 SP1 x86 syscall numbers (placeholders)
const X86_SYSCALLS = struct {
    pub const NtAllocateVirtualMemory: u32 = 0x24;
    pub const NtClose: u32 = 0x31;
    pub const NtCreateEvent: u32 = 0x52;
    pub const NtCreateFile: u32 = 0x55;
    pub const NtCreatePort: u32 = 0x57;
    pub const NtConnectPort: u32 = 0x58;
    pub const NtCreateProcess: u32 = 0x59;
    pub const NtCreateSection: u32 = 0x64;
    pub const NtCreateThread: u32 = 0x65;
    pub const NtDelayExecution: u32 = 0x73;
    pub const NtFreeVirtualMemory: u32 = 0x8B;
    pub const NtMapViewOfSection: u32 = 0xBA;
    pub const NtOpenFile: u32 = 0xC3;
    pub const NtOpenProcess: u32 = 0xC6;
    pub const NtProtectVirtualMemory: u32 = 0xD0;
    pub const NtQueryInformationProcess: u32 = 0xD3;
    pub const NtQuerySystemInformation: u32 = 0xD5;
    pub const NtQueryVirtualMemory: u32 = 0xD6;
    pub const NtReadFile: u32 = 0xD8;
    pub const NtReadVirtualMemory: u32 = 0xD9;
    pub const NtRequestWaitReplyPort: u32 = 0xDF;
    pub const NtTerminateProcess: u32 = 0x101;
    pub const NtTerminateThread: u32 = 0x102;
    pub const NtWaitForSingleObject: u32 = 0x110;
    pub const NtWriteFile: u32 = 0x112;
    pub const NtWriteVirtualMemory: u32 = 0x115;
};

/// x64 SSDT 服务索引 (NT 6.1 约定)
const X64_SSDT_INDEX = struct {
    pub const NtAllocateVirtualMemory: u32 = 0x0018;
    pub const NtClose: u32 = 0x0002;
    pub const NtCreateEvent: u32 = 0x00F4;
    pub const NtCreateFile: u32 = 0x0055;
    pub const NtCreatePort: u32 = 0x00E0;
    pub const NtConnectPort: u32 = 0x00E1;
    pub const NtCreateProcess: u32 = 0x0030;
    pub const NtCreateSection: u32 = 0x0047;
    pub const NtCreateThread: u32 = 0x004C;
    pub const NtDelayExecution: u32 = 0x005E;
    pub const NtFreeVirtualMemory: u32 = 0x001D;
    pub const NtMapViewOfSection: u32 = 0x002A;
    pub const NtOpenFile: u32 = 0x0052;
    pub const NtOpenProcess: u32 = 0x0034;
    pub const NtProtectVirtualMemory: u32 = 0x0045;
    pub const NtQueryInformationProcess: u32 = 0x0046;
    pub const NtQuerySystemInformation: u32 = 0x0050;
    pub const NtQueryVirtualMemory: u32 = 0x0053;
    pub const NtReadFile: u32 = 0x0057;
    pub const NtReadVirtualMemory: u32 = 0x003D;
    pub const NtRequestWaitReplyPort: u32 = 0x0060;
    pub const NtTerminateProcess: u32 = 0x001C;
    pub const NtTerminateThread: u32 = 0x001E;
    pub const NtWaitForSingleObject: u32 = 0x00F5;
    pub const NtWriteFile: u32 = 0x00B8;
    pub const NtWriteVirtualMemory: u32 = 0x003F;
};

/// 若 `syscall_num` 为 Win7 SP1 x86 上某 **ntos** 服务，返回对应 **x64** 索引；否则 `null`。
pub fn x64SsdtIndexForWin7Sp1X86(syscall_num: u32) ?u32 {
    if (syscall_num == X86_SYSCALLS.NtAllocateVirtualMemory) return X64_SSDT_INDEX.NtAllocateVirtualMemory;
    if (syscall_num == X86_SYSCALLS.NtClose) return X64_SSDT_INDEX.NtClose;
    if (syscall_num == X86_SYSCALLS.NtCreateEvent) return X64_SSDT_INDEX.NtCreateEvent;
    if (syscall_num == X86_SYSCALLS.NtCreateFile) return X64_SSDT_INDEX.NtCreateFile;
    if (syscall_num == X86_SYSCALLS.NtCreatePort) return X64_SSDT_INDEX.NtCreatePort;
    if (syscall_num == X86_SYSCALLS.NtConnectPort) return X64_SSDT_INDEX.NtConnectPort;
    if (syscall_num == X86_SYSCALLS.NtCreateProcess) return X64_SSDT_INDEX.NtCreateProcess;
    if (syscall_num == X86_SYSCALLS.NtCreateSection) return X64_SSDT_INDEX.NtCreateSection;
    if (syscall_num == X86_SYSCALLS.NtCreateThread) return X64_SSDT_INDEX.NtCreateThread;
    if (syscall_num == X86_SYSCALLS.NtDelayExecution) return X64_SSDT_INDEX.NtDelayExecution;
    if (syscall_num == X86_SYSCALLS.NtFreeVirtualMemory) return X64_SSDT_INDEX.NtFreeVirtualMemory;
    if (syscall_num == X86_SYSCALLS.NtMapViewOfSection) return X64_SSDT_INDEX.NtMapViewOfSection;
    if (syscall_num == X86_SYSCALLS.NtOpenFile) return X64_SSDT_INDEX.NtOpenFile;
    if (syscall_num == X86_SYSCALLS.NtOpenProcess) return X64_SSDT_INDEX.NtOpenProcess;
    if (syscall_num == X86_SYSCALLS.NtProtectVirtualMemory) return X64_SSDT_INDEX.NtProtectVirtualMemory;
    if (syscall_num == X86_SYSCALLS.NtQueryInformationProcess) return X64_SSDT_INDEX.NtQueryInformationProcess;
    if (syscall_num == X86_SYSCALLS.NtQuerySystemInformation) return X64_SSDT_INDEX.NtQuerySystemInformation;
    if (syscall_num == X86_SYSCALLS.NtQueryVirtualMemory) return X64_SSDT_INDEX.NtQueryVirtualMemory;
    if (syscall_num == X86_SYSCALLS.NtReadFile) return X64_SSDT_INDEX.NtReadFile;
    if (syscall_num == X86_SYSCALLS.NtReadVirtualMemory) return X64_SSDT_INDEX.NtReadVirtualMemory;
    if (syscall_num == X86_SYSCALLS.NtRequestWaitReplyPort) return X64_SSDT_INDEX.NtRequestWaitReplyPort;
    if (syscall_num == X86_SYSCALLS.NtTerminateProcess) return X64_SSDT_INDEX.NtTerminateProcess;
    if (syscall_num == X86_SYSCALLS.NtTerminateThread) return X64_SSDT_INDEX.NtTerminateThread;
    if (syscall_num == X86_SYSCALLS.NtWaitForSingleObject) return X64_SSDT_INDEX.NtWaitForSingleObject;
    if (syscall_num == X86_SYSCALLS.NtWriteFile) return X64_SSDT_INDEX.NtWriteFile;
    if (syscall_num == X86_SYSCALLS.NtWriteVirtualMemory) return X64_SSDT_INDEX.NtWriteVirtualMemory;
    return null;
}
