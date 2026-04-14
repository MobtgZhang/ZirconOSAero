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
// Module: src/config/nt61_core_dll_abi_inventory.zig
// Purpose: `ntdll.dll` / `kernel32.dll` / `user32.dll` 合成 PE 导出顺序锚点（与 [`pe.zig`](../../loader/pe.zig) `initSystemDlls` 一致）；阶段 4 二进制 ABI 清单。
//
// This is an independent clean-room implementation.
// Strategy: [docs/cn/CORE_DLL_PE_EXPORT_STRATEGY.md](../../docs/cn/CORE_DLL_PE_EXPORT_STRATEGY.md)

const std = @import("std");

/// 与 `pe.zig` 中 `initSystemDlls` → `ntdll.dll` `addExport` 顺序一致（ordinal 递增）。
pub const ntdll_exports_nt61: []const []const u8 = &.{
    "NtCreateProcess",           "NtTerminateProcess",      "NtCreateThread",      "NtCreateFile",
    "NtReadFile",                "NtWriteFile",             "NtClose",             "NtCreatePort",
    "NtRequestWaitReplyPort",    "NtAllocateVirtualMemory", "NtFreeVirtualMemory", "NtQuerySystemInformation",
    "NtQueryInformationProcess", "NtSetInformationProcess", "NtOpenFile",          "NtCreateEvent",
    "NtWaitForSingleObject",     "RtlInitUnicodeString",    "RtlCopyMemory",       "RtlZeroMemory",
    "RtlGetVersion",             "RtlVerifyVersionInfo",    "LdrInitializeThunk",  "LdrLoadDll",
    "LdrGetProcedureAddress",    "RtlUserThreadStart",
};

/// 与 `pe.zig` → `kernel32.dll` 导出顺序一致。
pub const kernel32_exports_nt61: []const []const u8 = &.{
    "CreateProcessA",      "CreateProcessW",       "ExitProcess",             "GetCurrentProcessId",
    "GetCurrentProcess",   "CreateFileA",          "CreateFileW",             "ReadFile",
    "WriteFile",           "CloseHandle",          "DeleteFileA",             "FindFirstFileA",
    "FindNextFileA",       "FindClose",            "GetStdHandle",            "WriteConsoleA",
    "ReadConsoleA",        "SetConsoleTitleA",     "GetProcessHeap",          "HeapAlloc",
    "HeapFree",            "VirtualAlloc",         "VirtualFree",             "LoadLibraryA",
    "GetProcAddress",      "FreeLibrary",          "GetModuleHandleA",        "GetModuleFileNameA",
    "GetLastError",        "SetLastError",         "GetTickCount",            "Sleep",
    "GetSystemInfo",       "GetVersionExA",        "GetCurrentDirectoryA",    "SetCurrentDirectoryA",
    "GetSystemDirectoryA", "GetWindowsDirectoryA", "GetEnvironmentVariableA", "SetEnvironmentVariableA",
    "GetFileSize",         "GetFileAttributesA",   "CreateDirectoryA",        "RemoveDirectoryA",
};

/// 与 `pe.zig` → `user32.dll` 导出顺序一致。
pub const user32_exports_nt61: []const []const u8 = &.{
    "CreateWindowExA",
    "DefWindowProcA",
};

comptime {
    std.debug.assert(ntdll_exports_nt61.len == 26);
    std.debug.assert(kernel32_exports_nt61.len == 44);
    std.debug.assert(user32_exports_nt61.len == 2);
}

test "core DLL export inventory matches pe.zig synthetic ordinals span" {
    try std.testing.expectEqualStrings("NtCreateProcess", ntdll_exports_nt61[0]);
    try std.testing.expectEqualStrings("RtlUserThreadStart", ntdll_exports_nt61[25]);
    try std.testing.expectEqualStrings("CreateProcessA", kernel32_exports_nt61[0]);
    try std.testing.expectEqualStrings("RemoveDirectoryA", kernel32_exports_nt61[43]);
    try std.testing.expectEqualStrings("CreateWindowExA", user32_exports_nt61[0]);
}
