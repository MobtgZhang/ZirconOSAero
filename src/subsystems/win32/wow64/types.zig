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
// Module: src/subsystems/win32/wow64/types.zig
// Purpose: WOW64 常量、枚举与 32 位上下文 / PEB/TEB 布局（公开 ABI 名，独立实现）。
//
// This is an independent clean-room implementation.
// Reference: MSDN PE32 / WOW64 概念描述（非结构体逐字段抄录）。

const std = @import("std");

pub const WOW64_VERSION: []const u8 = "ZirconOSAero WOW64 v1.0 (NT 6.1)";

/// 32 位 PEB 典型用户 VA（与公开 WOW64 文档中常见区域同阶；**非**商业系统逐字节保证）。
/// Ref: https://learn.microsoft.com/windows/win32/api/winternl/ns-winternl-peb （概念层）
pub const PEB32_DEFAULT_USER_VA: u32 = 0x7FFDE000;
/// 单线程演示用 TEB32 用户 VA；与 `PEB32_DEFAULT_USER_VA` 分离以便后续多线程扩展。
pub const TEB32_DEFAULT_USER_VA: u32 = 0x7FFDD000;

pub const WOW64_MAX_ADDR: u64 = 0x7FFFFFFF;
pub const WOW64_STACK_SIZE: u32 = 0x100000;
pub const WOW64_HEAP_SIZE: u32 = 0x100000;
pub const WOW64_TLS_SLOTS: usize = 64;

pub const PE32_IMAGE_BASE: u32 = 0x00400000;
pub const WOW64_NTDLL_BASE: u32 = 0x77000000;
pub const WOW64_KERNEL32_BASE: u32 = 0x76000000;
pub const WOW64_USER32_BASE: u32 = 0x75000000;

pub const WOW64_SIZE_OF_80387_REGISTERS: usize = 80;

pub const Wow64State = enum(u8) {
    inactive = 0,
    initializing = 1,
    active = 2,
    suspended = 3,
    error_state = 4,
};

pub const ThunkType = enum(u8) {
    none = 0,
    syscall_32to64 = 1,
    ptr_32to64 = 2,
    ptr_64to32 = 3,
    struct_convert = 4,
    handle_convert = 5,
};

pub const CONTEXT32 = struct {
    context_flags: u32 = 0x10001F,
    dr0: u32 = 0,
    dr1: u32 = 0,
    dr2: u32 = 0,
    dr3: u32 = 0,
    dr6: u32 = 0,
    dr7: u32 = 0,
    float_save: [WOW64_SIZE_OF_80387_REGISTERS]u8 = [_]u8{0} ** WOW64_SIZE_OF_80387_REGISTERS,
    seg_gs: u32 = 0,
    seg_fs: u32 = 0x003B,
    seg_es: u32 = 0x0023,
    seg_ds: u32 = 0x0023,
    edi: u32 = 0,
    esi: u32 = 0,
    ebx: u32 = 0,
    edx: u32 = 0,
    ecx: u32 = 0,
    eax: u32 = 0,
    ebp: u32 = 0,
    eip: u32 = 0,
    seg_cs: u32 = 0x0023,
    eflags: u32 = 0x00000202,
    esp: u32 = 0,
    seg_ss: u32 = 0x002B,
};

/// 32 位 PEB 子集，`extern` 以匹配 x86 上常见 C/Win32 布局（4×`u8` 后 `Mutant`@4、`ImageBaseAddress`@8）。
pub const PEB32 = extern struct {
    inherited_address_space: u8,
    read_image_file_exec_options: u8,
    being_debugged: u8,
    spare_bool: u8,
    mutant: u32,
    image_base_address: u32,
    ldr: u32,
    process_parameters: u32,
    sub_system_data: u32,
    process_heap: u32,
    fast_peb_lock: u32,
    os_major_version: u32,
    os_minor_version: u32,
    os_build_number: u16,
    os_csd_version: u16,
    os_platform_id: u32,
    image_subsystem: u32,
    image_subsystem_major_version: u32,
    image_subsystem_minor_version: u32,
    number_of_processors: u32,
    nt_global_flag: u32,
    session_id: u32,
};

pub const TEB32 = extern struct {
    nt_tib_exception_list: u32,
    nt_tib_stack_base: u32,
    nt_tib_stack_limit: u32,
    nt_tib_sub_system_tib: u32,
    nt_tib_fiber_data: u32,
    nt_tib_arbitrary_user_pointer: u32,
    nt_tib_self: u32,
    environment_pointer: u32,
    process_id: u32,
    thread_id: u32,
    active_rpc_handle: u32,
    thread_local_storage: u32,
    peb: u32,
    last_error_value: u32,
    count_of_owned_critical_sections: u32,
    wow64_reserved: u32,
    locale_id: u32,
    tls_slots: [WOW64_TLS_SLOTS]u32,
};

pub const MAX_WOW64_PROCESSES: usize = 32;

pub const Wow64Process = struct {
    pid: u32 = 0,
    state: Wow64State = .inactive,
    is_active: bool = false,
    context: CONTEXT32 = .{},
    peb32: PEB32 = std.mem.zeroes(PEB32),
    teb32: TEB32 = std.mem.zeroes(TEB32),
    image_name: [64]u8 = [_]u8{0} ** 64,
    image_name_len: usize = 0,
    image_base: u32 = 0,
    entry_point: u32 = 0,
    stack_base: u32 = 0,
    stack_limit: u32 = 0,
    heap_base: u32 = 0,
    parent_pid: u32 = 0,
    exit_code: u32 = 0,
    syscall_count: u64 = 0,
    thunk_count: u64 = 0,
    /// `translateSyscall32to64` 最近一次解析的 **x64 SSDT 索引**（公开 Win7 SP1 同名 API 对照）；无对照时为 `null`。
    last_x64_ssdt_alias: ?u32 = null,

    pub fn getName(self: *const Wow64Process) []const u8 {
        return self.image_name[0..self.image_name_len];
    }
};

pub const MAX_THUNK_ENTRIES: usize = 128;

pub const ThunkEntry = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    native_syscall_id: u32 = 0,
    thunk_type: ThunkType = .none,
    is_active: bool = false,
    call_count: u64 = 0,
    target_module: [32]u8 = [_]u8{0} ** 32,
    target_module_len: usize = 0,
};

test "Wow64Process embeds PEB32 and TEB32" {
    try std.testing.expect(@sizeOf(Wow64Process) > @sizeOf(PEB32) + @sizeOf(TEB32));
}

// Ref: https://learn.microsoft.com/windows/win32/api/winternl/ns-winternl-peb （字段语义）
// Ref: https://learn.microsoft.com/windows/win32/api/winternl/ns-winternl-teb （TEB；x86 上 `Fs:[0x30]` → PEB）
test "PEB32 TEB32 field offsets (public layout subset)" {
    // Ref: https://learn.microsoft.com/windows/win32/api/winternl/ns-winternl-peb
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(PEB32, "image_base_address"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(PEB32, "process_parameters"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(PEB32, "os_major_version"));
    try std.testing.expectEqual(@as(usize, 0x30), @offsetOf(TEB32, "peb"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(TEB32, "process_id"));
}
